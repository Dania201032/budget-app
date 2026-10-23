import 'package:budget_app/capture/capture_service.dart';
import 'package:budget_app/data/database.dart';
import 'package:budget_app/data/models.dart';
import 'package:budget_app/data/repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

CapturedPayment _p(String source, int minor, DateTime t, {String? merchant, String dir = 'expense'}) =>
    CapturedPayment.fromJson({
      'source': source,
      'app': 'alipay',
      'direction': dir,
      'amountMinor': minor,
      'currency': 'CNY',
      'merchant': merchant,
      'method': source == 'screen' ? 'Balance' : null,
      'ts': t.millisecondsSinceEpoch,
      'raw': '',
    });

void main() {
  sqfliteFfiInit();
  late Database db;
  late Repository repo;
  late CaptureImporter importer;
  final t0 = DateTime(2026, 10, 12, 20, 4, 18);

  setUp(() async {
    db = await openAppDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    repo = Repository(db);
    importer = CaptureImporter(repo);
  });

  // Closing destroys the in-memory database, so every test starts from a fresh seed.
  tearDown(() => db.close());

  Future<List<Txn>> all() => repo.txnsBetween(DateTime(2026), DateTime(2027));

  test('screen + notification of the same payment become one transaction', () async {
    // Real capture: success screen at 20:04:18, notification "你有一笔50.00元的支出" at 20:04:16.
    final created = await importer.importAll([
      _p('notification', 5000, t0.subtract(const Duration(seconds: 2))),
      _p('screen', 5000, t0, merchant: '全家便利店'),
    ]);
    expect(created, 1);
    final txns = await all();
    expect(txns, hasLength(1));
    expect(txns.single.merchant, '全家便利店');
    expect(txns.single.source, 'alipay:notification+screen');
    expect(txns.single.needsReview, isTrue);
    expect(txns.single.time, t0);
  });

  test('two real payments of the same amount stay separate', () async {
    await importer.importAll([
      _p('notification', 700, t0),
      _p('notification', 700, t0.add(const Duration(minutes: 1))),
    ]);
    expect(await all(), hasLength(2));
  });

  test('learned merchant category is applied automatically', () async {
    final food = (await repo.categories()).firstWhere((c) => c.name == 'Еда');
    await repo.rememberMerchant('全家便利店', food.id);
    await importer.importAll([_p('screen', 5000, t0, merchant: '全家便利店')]);
    final t = (await all()).single;
    expect(t.categoryId, food.id);
    expect(t.needsReview, isFalse);
  });

  test('merge picks up the category once the merchant becomes known', () async {
    final food = (await repo.categories()).firstWhere((c) => c.name == 'Еда');
    await repo.rememberMerchant('全家', food.id);
    await importer.importAll([_p('notification', 1250, t0)]);
    await importer.importAll([_p('screen', 1250, t0.add(const Duration(seconds: 1)), merchant: '全家')]);
    final t = (await all()).single;
    expect(t.categoryId, food.id);
    expect(t.needsReview, isFalse);
  });

  test('success card shown again minutes later is not a new payment', () async {
    // Real case: Alipay payment-code card "Payment Successful ￥19.00 申梦上荷" seen at 11:59:42 and again at 12:07:06.
    final first = DateTime(2026, 10, 13, 11, 59, 42);
    await importer.importAll([_p('screen', 1900, first, merchant: '申梦上荷（吉浦路店）')]);
    await importer.importAll([_p('screen', 1900, first.add(const Duration(minutes: 7, seconds: 24)), merchant: '申梦上荷（吉浦路店）')]);
    expect(await all(), hasLength(1));
    // A different merchant with the same amount is a different payment.
    await importer.importAll([_p('screen', 1900, first.add(const Duration(minutes: 8)), merchant: '全家')]);
    expect(await all(), hasLength(2));
  });

  CapturedPayment bill(String merchant, int minor, DateTime t, String category) => CapturedPayment.fromJson({
        'source': 'bill',
        'app': 'alipay',
        'direction': 'expense',
        'amountMinor': minor,
        'currency': 'CNY',
        'merchant': merchant,
        'method': null,
        'ts': t.millisecondsSinceEpoch,
        'raw': '$merchant，-${minor / 100}元，，$category，，',
        'category': category,
      });

  test('Alipay Bills: confirms known payments, adds missed auto-debits with Alipay category', () async {
    // Known: the 19 ¥ success screen at 11:59:42. Missed: Hellobike auto-debit at 13:05.
    await importer.importAll([_p('screen', 1900, DateTime(2026, 10, 13, 11, 59, 42), merchant: '申梦上荷（吉浦路店）')]);
    await importer.importAll([_p('notification', 2600, DateTime(2026, 10, 13, 8, 31, 10))]);
    final created = await importer.importAll([
      bill('申梦上荷（吉浦路店）', 1900, DateTime(2026, 10, 13, 11, 59), 'Food'),
      bill('KIRILL', 2600, DateTime(2026, 10, 13, 8, 31), 'Transfers'),
      bill('哈啰出行车费', 250, DateTime(2026, 10, 13, 13, 5), 'Transport'),
    ]);
    expect(created, 1);
    final txns = await all();
    expect(txns, hasLength(3));
    final transport = (await repo.categories()).firstWhere((c) => c.name == 'Транспорт');
    final bike = txns.firstWhere((t) => t.amountMinor == 250);
    expect(bike.categoryId, transport.id);
    expect(bike.needsReview, isFalse);
    expect(bike.source, 'alipay:bill');
    // The transfer notification got its recipient from the Bills row.
    expect(txns.firstWhere((t) => t.amountMinor == 2600).merchant, 'KIRILL');

    // Opening Bills again changes nothing.
    expect(await importer.importAll([bill('哈啰出行车费', 250, DateTime(2026, 10, 13, 13, 5), 'Transport')]), 0);
    expect(await all(), hasLength(3));
  });

  test('Alipay Bills: days covered by the Excel import are skipped', () async {
    await repo.insertTxn(Txn(
        time: DateTime(2026, 10, 12, 12), amountMinor: 4600, currency: 'CNY', kind: TxnKind.expense, source: 'excel'));
    // Real case: the income sheet had "Сдача крови" dated Oct 13 — it must not hide Oct 13 bills.
    await repo.insertTxn(Txn(
        time: DateTime(2026, 10, 13, 12), amountMinor: 20000, currency: 'CNY', kind: TxnKind.income, source: 'excel'));
    final created = await importer.importAll([
      bill('赤峰路地铁站（沪）-条码支付', 300, DateTime(2026, 10, 12, 13, 21), 'Daily'),
      bill('哈啰出行车费', 250, DateTime(2026, 10, 13, 13, 5), 'Transport'),
    ]);
    expect(created, 1);
  });

  test('WeChat transfer: pending without amount, then answered', () async {
    CapturedPayment prompt(String source, int minor) => CapturedPayment.fromJson({
          'source': source, 'app': 'wechat', 'direction': 'income', 'amountMinor': minor, 'currency': 'CNY',
          'merchant': 'Alex', 'method': null, 'ts': t0.millisecondsSinceEpoch, 'raw': 'WeChat transfer', 'promptId': 42,
        });
    await importer.importAll([prompt('prompt', 0)]);
    var t = (await all()).single;
    expect(t.amountMinor, 0);
    expect(t.needsReview, isTrue);
    expect(t.merchant, 'Alex');

    await importer.importAll([prompt('prompt_answer', 100)]);
    t = (await all()).single;
    expect(t.amountMinor, 100);
    expect(t.kind, TxnKind.income);

    // "Не записывать" removes the pending one.
    await importer.importAll([
      CapturedPayment.fromJson({
        'source': 'prompt', 'app': 'wechat', 'direction': 'expense', 'amountMinor': 0, 'currency': 'CNY',
        'merchant': 'Alex', 'method': null, 'ts': t0.millisecondsSinceEpoch, 'raw': '', 'promptId': 43,
      }),
    ]);
    await importer.importAll([
      CapturedPayment.fromJson({
        'source': 'prompt_answer', 'app': 'wechat', 'direction': 'expense', 'amountMinor': 0, 'currency': 'CNY',
        'merchant': 'Alex', 'method': null, 'ts': t0.millisecondsSinceEpoch, 'raw': '', 'promptId': 43,
      }),
    ]);
    expect(await all(), hasLength(1));
  });

  test('WeChat transfer: prompt and answer in one batch give one transaction', () async {
    // Real bug (v0.4.1): same timestamp, unstable sort put the answer first -> a stuck 0 ¥ duplicate.
    Map<String, Object?> j(String source, int minor) => {
          'source': source, 'app': 'wechat', 'direction': 'income', 'amountMinor': minor, 'currency': 'CNY',
          'merchant': 'Alex', 'method': null, 'ts': t0.millisecondsSinceEpoch, 'raw': 'WeChat transfer', 'promptId': 7,
        };
    for (var i = 0; i < 20; i++) {
      final batch = [
        for (var k = 0; k < i; k++) _p('notification', 100 + k, t0.subtract(Duration(minutes: 10 + k))),
        CapturedPayment.fromJson(j('prompt', 0)),
        CapturedPayment.fromJson(j('prompt_answer', 100)),
      ];
      await importer.importAll(batch);
      final transfers = (await all()).where((t) => t.merchant == 'Alex').toList();
      expect(transfers, hasLength(1), reason: 'batch $i');
      expect(transfers.single.amountMinor, 100);
      await db.delete('transactions');
    }
  });

  test('leftover 0 ¥ placeholders of answered transfers are cleaned up', () async {
    Txn t(int minor) => Txn(
        time: t0, amountMinor: minor, currency: 'CNY', kind: TxnKind.income, merchant: 'Alex',
        source: 'wechat:prompt', needsReview: true, raw: 'prompt:9');
    await repo.insertTxn(t(100));
    await repo.insertTxn(t(0));
    await repo.insertTxn(Txn(
        time: t0, amountMinor: 0, currency: 'CNY', kind: TxnKind.income, source: 'wechat:prompt', raw: 'prompt:10'));
    expect(await repo.removeAnsweredPrompts(), 1);
    expect(await all(), hasLength(2), reason: 'an unanswered placeholder stays');
  });

  test('merchant rule learned on income does not apply to expenses', () async {
    // Real case: "Alex -> Переводы (income)" was applied to an outgoing transfer to Alex.
    final cats = await repo.categories();
    final incomeTransfers = cats.firstWhere((c) => c.name == 'Переводы' && c.kind == TxnKind.income);
    final expenseTransfers = cats.firstWhere((c) => c.name == 'Переводы' && c.kind == TxnKind.expense);
    await repo.rememberMerchant('Alex', incomeTransfers.id);
    expect(await repo.categoryForMerchant('Alex', TxnKind.income), incomeTransfers.id);
    expect(await repo.categoryForMerchant('Alex', TxnKind.expense), isNull);
    await repo.rememberMerchant('Alex', expenseTransfers.id);
    expect(await repo.categoryForMerchant('Alex', TxnKind.expense), expenseTransfers.id);
    expect(await repo.categoryForMerchant('Alex', TxnKind.income), incomeTransfers.id);
  });

  test('income notification is imported as income', () async {
    await importer.importAll([_p('notification', 10000, t0, dir: 'income')]);
    expect((await all()).single.kind, TxnKind.income);
  });

  test('budget falls back to the latest earlier month, then to the default', () async {
    expect(await repo.budgetFor(DateTime(2026, 10)), (300000, 'CNY'));
    await repo.setBudget(DateTime(2026, 9), 250000, 'CNY');
    expect(await repo.budgetFor(DateTime(2026, 10)), (250000, 'CNY'));
    expect(await repo.budgetFor(DateTime(2026, 8)), (300000, 'CNY'));
  });

  group('bank history', () {
    final today = DateTime.now();
    final day = DateTime(today.year, today.month, today.day).subtract(const Duration(days: 1));
    final noon = day.add(const Duration(hours: 12));

    CapturedPayment row(int n, int minor, {String dir = 'expense', String? merchant, String? category, DateTime? at}) =>
        CapturedPayment.fromJson({
          'source': 'bill',
          'app': 'vtb',
          'direction': dir,
          'amountMinor': minor,
          'currency': 'RUB',
          'merchant': merchant,
          'method': 'ВТБ',
          'ts': (at ?? noon).millisecondsSinceEpoch,
          'raw': 'bank_history|$n|vtb|${day.millisecondsSinceEpoch}|$dir|$minor',
          'category': category,
        });

    CapturedPayment push(int minor, DateTime at, {String dir = 'expense'}) => CapturedPayment.fromJson({
          'source': 'bank',
          'app': 'vtb',
          'direction': dir,
          'amountMinor': minor,
          'currency': 'RUB',
          'merchant': null,
          'method': 'ВТБ',
          'ts': at.millisecondsSinceEpoch,
          'raw': 'push',
        });

    Future<List<Txn>> vtb() async => (await repo.txnsBetween(day.subtract(const Duration(days: 90)), today.add(const Duration(days: 1))))
        .where((t) => t.source.startsWith('vtb:'))
        .toList();

    test('a missed income is added once, re-reading adds nothing, and a VTB account appears', () async {
      final r = row(0, 1500000, dir: 'income', merchant: 'Иван И.', category: 'Переводы');
      expect(await importer.importAll([r]), 1);
      expect(await importer.importAll([row(0, 1500000, dir: 'income', merchant: 'Иван И.')]), 0);
      final txns = await vtb();
      expect(txns, hasLength(1));
      expect(txns.single.kind, TxnKind.income);
      expect(txns.single.currency, 'RUB');
      final cats = await repo.categories();
      expect(cats.firstWhere((c) => c.id == txns.single.categoryId).key, 'transfers_in');
      final accounts = await repo.accounts();
      expect(accounts.firstWhere((a) => a.id == txns.single.accountId).name, 'ВТБ');
    });

    test('two equal rows the same day are two operations', () async {
      await importer.importAll([row(0, 45050, merchant: 'Магнит'), row(1, 45050, merchant: 'Магнит')]);
      await importer.importAll([row(0, 45050, merchant: 'Магнит'), row(1, 45050, merchant: 'Магнит')]);
      expect(await vtb(), hasLength(2));
    });

    test('a row confirms the notification seen earlier instead of adding a twin', () async {
      await importer.importAll([push(45050, day.add(const Duration(hours: 9, minutes: 5)))]);
      expect(await importer.importAll([row(0, 45050, merchant: 'Магнит', category: 'Супермаркеты')]), 0);
      final txns = await vtb();
      expect(txns, hasLength(1));
      expect(txns.single.merchant, 'Магнит');
      expect(txns.single.source, 'vtb:bank+bill');
    });

    test('a notification after the row merges into it and gives it its time', () async {
      await importer.importAll([row(0, 32000, merchant: 'Яндекс Такси')]);
      final at = day.add(const Duration(hours: 18, minutes: 40));
      await importer.importAll([push(32000, at)]);
      final txns = await vtb();
      expect(txns, hasLength(1));
      expect(txns.single.time, at);
    });

    test('a deleted operation does not come back', () async {
      await importer.importAll([row(0, 9900, merchant: 'Пятёрочка')]);
      final t = (await vtb()).single;
      await repo.deleteTxn(t.id!);
      await repo.dismiss(t);
      await importer.importAll([row(0, 9900, merchant: 'Пятёрочка')]);
      expect(await vtb(), isEmpty);
    });

    test('old history is not imported', () async {
      final old = DateTime(today.year, today.month, today.day).subtract(const Duration(days: bankHistoryDays + 5));
      expect(await importer.importAll([row(0, 100000, at: old.add(const Duration(hours: 12)))]), 0);
    });
  });

  test('bank operations go to the account the user created with the bank name; duplicates merge', () async {
    final own = await repo.addAccount('ВТБ', 'RUB', 'bank');
    await repo.setAccountBalance(own, 8697100, DateTime.now().subtract(const Duration(days: 1)));
    // An automatic "Сбер" from an earlier version next to the user's "Сбербанк".
    final userSber = await repo.addAccount('Сбербанк', 'RUB', 'bank');
    final autoSber = await repo.addAccount('Сбер', 'RUB', 'sber');
    await repo.insertTxn(Txn(
        time: DateTime.now(), amountMinor: 100, currency: 'RUB', kind: TxnKind.expense, accountId: autoSber, source: 'sber:bank'));

    final today = DateTime.now();
    await importer.importAll([
      CapturedPayment.fromJson({
        'source': 'bill', 'app': 'vtb', 'direction': 'income', 'amountMinor': 1500000, 'currency': 'RUB',
        'merchant': 'Входящий перевод', 'method': 'ВТБ', 'ts': today.millisecondsSinceEpoch,
        'raw': 'bank_history|0|vtb|0|income|1500000',
      }),
    ]);
    final accounts = await repo.accounts();
    expect(accounts.where((a) => a.name == 'ВТБ'), hasLength(1));
    expect((await repo.accountBalances())[own], 8697100 + 1500000);

    expect(await repo.mergeDuplicateBankAccounts(), 1);
    final after = await repo.accounts();
    expect(after.map((a) => a.id), isNot(contains(autoSber)));
    expect(after.firstWhere((a) => a.id == userSber).type, 'sber');
    final moved = (await repo.txnsBetween(DateTime(2026), DateTime(2027))).where((t) => t.source == 'sber:bank');
    expect(moved.single.accountId, userSber);
  });

  group('WeChat duplicates', () {
    CapturedPayment wx(String source, int minor, DateTime t, {String? merchant, String raw = ''}) =>
        CapturedPayment.fromJson({
          'source': source, 'app': 'wechat', 'direction': 'expense', 'amountMinor': minor, 'currency': 'CNY',
          'merchant': merchant, 'method': null, 'ts': t.millisecondsSinceEpoch, 'raw': raw,
        });
    Future<List<Txn>> wechat() async => (await all()).where((t) => t.source.startsWith('wechat:')).toList();

    test('success page read before and after its merchant appears is one payment', () async {
      await importer.importAll([wx('screen', 1500, t0)]);
      await importer.importAll([wx('screen', 1500, t0.add(const Duration(seconds: 20)), merchant: '全家')]);
      expect(await wechat(), hasLength(1));
    });

    test('a re-posted "Weixin Pay" notification is not a second payment', () async {
      const text = 'Weixin Pay | ¥15.00 paid';
      await importer.importAll([wx('screen', 1500, t0, merchant: '全家'), wx('notification', 1500, t0, raw: text)]);
      await importer.importAll([wx('notification', 1500, t0.add(const Duration(seconds: 40)), raw: text)]);
      final txns = await wechat();
      expect(txns, hasLength(1));
      expect(txns.single.merchant, '全家');
    });

    test('two real payments of the same amount minutes apart stay two', () async {
      await importer.importAll([wx('notification', 1500, t0, raw: 'Weixin Pay | ¥15.00 paid')]);
      await importer.importAll([wx('notification', 1500, t0.add(const Duration(minutes: 15)), raw: 'Weixin Pay | ¥15.00 paid')]);
      expect(await wechat(), hasLength(2));
    });
  });

  group('transfers between my own accounts', () {
    CapturedPayment bank(String app, String dir, int minor, DateTime at, {String? merchant, String raw = '', String source = 'bank'}) =>
        CapturedPayment.fromJson({
          'source': source, 'app': app, 'direction': dir, 'amountMinor': minor, 'currency': 'RUB',
          'merchant': merchant, 'method': app == 'vtb' ? 'ВТБ' : 'Сбер', 'ts': at.millisecondsSinceEpoch, 'raw': raw,
        });
    Future<List<Txn>> rub() async => (await all()).where((t) => t.currency == 'RUB').toList();

    test('VTB → Sber: both sides paired, not spending or income, balances still move', () async {
      final vtb = await repo.addAccount('ВТБ', 'RUB', 'bank');
      await repo.setAccountBalance(vtb, 10000000, t0.subtract(const Duration(days: 1)));
      final sber = await repo.addAccount('Сбер', 'RUB', 'bank');
      await repo.setAccountBalance(sber, 500000, t0.subtract(const Duration(days: 1)));
      await importer.importAll([bank('vtb', 'expense', 1500000, t0, merchant: 'Иван С.')]);
      await importer.importAll([bank('sber', 'income', 1500000, t0.add(const Duration(minutes: 1)), merchant: 'Иван С.')]);

      final txns = await rub();
      expect(txns, hasLength(2));
      expect(txns.every((t) => t.ownTransfer && t.excluded && !t.needsReview), isTrue);
      final out = txns.firstWhere((t) => t.kind == TxnKind.expense);
      final inc = txns.firstWhere((t) => t.kind == TxnKind.income);
      expect(out.pairId, inc.id);
      expect(inc.pairId, out.id);
      final balances = await repo.accountBalances();
      expect(balances[vtb], 10000000 - 1500000);
      expect(balances[sber], 500000 + 1500000);
      expect(await repo.selfNames(), {'Иван С'});
    });

    test('bank history rows (no time) pair within the same day', () async {
      await importer.importAll([
        bank('vtb', 'expense', 300000, t0, source: 'bill', raw: 'bank_history|0|vtb|0|expense|300000'),
        bank('sber', 'income', 300000, t0.subtract(const Duration(hours: 5)), source: 'bill', raw: 'bank_history|0|sber|0|income|300000'),
      ]);
      expect((await rub()).every((t) => t.ownTransfer), isTrue);
    });

    test('my learned name or the bank saying so marks a one-sided transfer', () async {
      await repo.addSelfName('Иван С.');
      await importer.importAll([
        bank('vtb', 'expense', 700000, t0, merchant: 'Иван С'),
        bank('sber', 'expense', 50000, t0.add(const Duration(hours: 2)), raw: 'СберБанк | Перевод между своими счетами 500 ₽'),
      ]);
      final txns = await rub();
      expect(txns.every((t) => t.ownTransfer && t.pairId == null), isTrue);
    });

    test('no pairing across different amounts, the same account, or a payment app', () async {
      await importer.importAll([
        bank('vtb', 'expense', 100000, t0),
        bank('sber', 'income', 100001, t0.add(const Duration(minutes: 1))),
        bank('vtb', 'income', 100000, t0.add(const Duration(minutes: 2))),
      ]);
      expect((await rub()).any((t) => t.ownTransfer), isFalse);
      expect(await repo.addSelfName('Сбербанк').then((_) => repo.selfNames()), isEmpty, reason: 'banks are not my name');
    });

    test('"not a transfer to myself" makes both sides count again', () async {
      await importer.importAll([
        bank('vtb', 'expense', 200000, t0),
        bank('sber', 'income', 200000, t0.add(const Duration(minutes: 3))),
      ]);
      await repo.unlinkOwnTransfer((await rub()).first);
      expect((await rub()).every((t) => !t.ownTransfer && !t.excluded && t.pairId == null), isTrue);
    });
  });

  group('paying for a friend', () {
    setUp(() => repo.convert = (amount, from, to, at) => switch ((from, to)) {
          ('CNY', 'RUB') => amount * 12,
          ('RUB', 'CNY') => amount ~/ 12,
          _ => from == to ? amount : null,
        });

    Future<int> paidForFriend(int minor, {String? friend}) async {
      final id = await repo.insertTxn(Txn(time: t0, amountMinor: minor, currency: 'CNY', kind: TxnKind.expense, merchant: 'Подписка'));
      await repo.updateTxn((await repo.txnById(id))!.copyWith(shareMinor: () => 0));
      await repo.setDebts(id, [(friend, minor)], 'CNY');
      return id;
    }

    CapturedPayment rubIn(int minor, {String? from}) => CapturedPayment.fromJson({
          'source': 'bank', 'app': 'sber', 'direction': 'income', 'amountMinor': minor, 'currency': 'RUB',
          'merchant': from, 'method': 'Сбер', 'ts': t0.add(const Duration(hours: 3)).millisecondsSinceEpoch, 'raw': '',
        });

    test('100 ¥ paid for a friend, 1 150 ₽ back: the debt closes, the rubles are not income', () async {
      await paidForFriend(10000);
      await importer.importAll([rubIn(115000)]);
      expect(await repo.openDebts(), isEmpty);
      expect((await all()).firstWhere((t) => t.currency == 'RUB').excluded, isTrue);
    });

    test('a ruble income far from the debt stays income', () async {
      await paidForFriend(10000);
      await importer.importAll([rubIn(200000)]);
      expect(await repo.openDebts(), hasLength(1));
      expect((await all()).firstWhere((t) => t.currency == 'RUB').excluded, isFalse);
    });

    test('a named friend paying half in rubles settles half', () async {
      await paidForFriend(10000, friend: 'Иван И');
      await importer.importAll([rubIn(60000, from: 'Иван И')]);
      final open = await repo.openDebts();
      expect(open.single.openMinor, 5000);
    });

    test('by hand: "this is a debt paid back"', () async {
      await paidForFriend(10000);
      await importer.importAll([rubIn(300000)]);
      final income = (await all()).firstWhere((t) => t.currency == 'RUB');
      await repo.settleDebtByHand((await repo.openDebts()).single, income);
      expect(await repo.openDebts(), isEmpty);
      expect((await repo.txnById(income.id!))!.excluded, isTrue);
    });
  });

  test('transfers recorded before the update are paired once', () async {
    final vtb = await repo.addAccount('ВТБ', 'RUB', 'vtb');
    final sber = await repo.addAccount('Сбер', 'RUB', 'sber');
    final at = DateTime.now().subtract(const Duration(days: 3));
    await repo.insertTxn(Txn(time: at, amountMinor: 1500000, currency: 'RUB', kind: TxnKind.expense, accountId: vtb, source: 'vtb:bank'));
    await repo.insertTxn(Txn(
        time: at.add(const Duration(minutes: 2)), amountMinor: 1500000, currency: 'RUB', kind: TxnKind.income, accountId: sber, source: 'sber:bank'));
    expect(await importer.pairEarlierTransfers(), 1);
    final txns = await repo.txnsBetween(at.subtract(const Duration(days: 1)), DateTime.now());
    expect(txns.every((t) => t.ownTransfer && t.excluded), isTrue);
  });

  test('names as banks write them', () {
    expect(Repository.normalizeName('ИВАН ПЕТРОВИЧ С..'), 'Иван Петрович С');
    expect(Repository.senderIn('Перевод по СБП от ИВАН ПЕТРОВИЧ С. | + 12 345 ₽'), 'Иван Петрович С');
    expect(Repository.senderIn('Покупка 450 ₽ Магнит'), isNull);
  });

  group('notification buttons', () {
    CapturedPayment ev(String source, {int? parts, String? merchant}) => CapturedPayment.fromJson({
          'source': source, 'app': 'wechat', 'direction': 'expense', 'amountMinor': 5600, 'currency': 'CNY',
          'merchant': merchant, 'method': null, 'ts': t0.millisecondsSinceEpoch, 'raw': source, 'promptId': parts,
        });

    test('"For a friend": nothing is mine, the friend owes all of it', () async {
      await importer.importAll([ev('notification')]);
      await importer.importAll([ev('split', parts: 0)]);
      final t = (await all()).single;
      expect(t.shareMinor, 0);
      expect((await repo.openDebts()).single.openMinor, 5600);
    });

    test('"Where?" names the payee and applies the category learned for it', () async {
      final health = (await repo.categories()).firstWhere((c) => c.key == 'health');
      await repo.rememberMerchant('Аптека', health.id);
      await importer.importAll([ev('notification')]);
      await importer.importAll([ev('payee', merchant: 'Аптека')]);
      final t = (await all()).single;
      expect(t.merchant, 'Аптека');
      expect(t.categoryId, health.id);
      expect(t.needsReview, isFalse);
    });
  });

  group('Google Wallet and the bank', () {
    CapturedPayment eu(String app, String source, int minor, DateTime at, {String? merchant, String? raw}) =>
        CapturedPayment.fromJson({
          'source': source,
          'app': app,
          'direction': 'expense',
          'amountMinor': minor,
          'currency': 'EUR',
          'merchant': merchant,
          'method': app == walletApp ? null : 'DKB',
          'ts': at.millisecondsSinceEpoch,
          'raw': raw ?? '',
        });

    test('Wallet first, then the bank push: one payment on the bank account', () async {
      await importer.importAll([eu(walletApp, 'wallet', 1234, t0, merchant: 'REWE')]);
      final alone = (await all()).single;
      expect(alone.accountId, isNull, reason: 'a Wallet card may be of any bank');
      expect(alone.source, 'gwallet:wallet');

      await importer.importAll([eu('dkb', 'bank', 1234, t0.add(const Duration(seconds: 40)), merchant: 'REWE Markt')]);
      final t = (await all()).single;
      expect(t.source, 'dkb:bank+wallet');
      expect(t.merchant, 'REWE');
      expect(t.time, t0);
      final account = (await repo.accounts()).firstWhere((a) => a.id == t.accountId);
      expect(account.type, 'dkb');
      expect(account.currency, 'EUR');
    });

    test('bank push first, then Wallet: still one payment', () async {
      await importer.importAll([
        eu('dkb', 'bank', 1234, t0, merchant: 'REWE Markt'),
        eu(walletApp, 'wallet', 1234, t0.add(const Duration(seconds: 5)), merchant: 'REWE'),
      ]);
      final t = (await all()).single;
      expect(t.source, 'dkb:bank+wallet');
      expect(t.merchant, 'REWE Markt');
      expect(t.accountId, isNotNull);
    });

    test('a Wallet payment is matched by the bank history row of that day', () async {
      final now = DateTime.now();
      final day = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 1));
      await importer.importAll([eu(walletApp, 'wallet', 780, day.add(const Duration(hours: 9)), merchant: 'Albert Heijn')]);
      await importer.importAll([
        eu('dkb', 'bill', 780, day.add(const Duration(hours: 12)),
            raw: 'bank_history|0|dkb|${day.millisecondsSinceEpoch}|expense|780'),
      ]);
      final txns = await repo.txnsBetween(day, day.add(const Duration(days: 1)));
      expect(txns, hasLength(1));
      expect(txns.single.source, 'dkb:bill+wallet');
      expect(txns.single.merchant, 'Albert Heijn');
    });

    test('different payments stay apart', () async {
      await importer.importAll([
        eu(walletApp, 'wallet', 1234, t0, merchant: 'REWE'),
        eu('dkb', 'bank', 999, t0.add(const Duration(seconds: 30)), merchant: 'Lidl'),
        eu('dkb', 'bank', 1234, t0.add(const Duration(hours: 2)), merchant: 'REWE'),
      ]);
      expect(await all(), hasLength(3));
    });
  });

  test('bank names are matched as whole words when short', () {
    expect(bankKeyForName('ING Girokonto'), 'ing');
    expect(bankKeyForName('Savings'), isNull);
    expect(bankKeyForName('Sparkasse Köln'), 'sparkasse');
    expect(bankKeyForName('Сбербанк'), 'sber');
  });

  test('old captured names and notes are cleaned up', () async {
    final a = await repo.insertTxn(Txn(
        time: t0, amountMinor: 1000000, currency: 'RUB', kind: TxnKind.income, merchant: 'Счёт карты VISA •• 4521',
        source: 'sber:bank', raw: 'Перевод по СБП от ИВАН ПЕТРОВИЧ С. | + 10 000 ₽ — Счёт карты VISA •• 4521'));
    final b = await repo.insertTxn(Txn(
        time: t0, amountMinor: 250, currency: 'CNY', kind: TxnKind.expense, merchant: '哈啰出行车费',
        note: 'Auto debit successful', source: 'alipay:bill'));
    await repo.cleanUpCapturedNames();
    expect((await repo.txnById(a))!.merchant, 'Иван Петрович С');
    expect((await repo.txnById(b))!.note, isNull);
    expect((await repo.txnById(b))!.merchant, '哈啰出行车费');
  });
}
