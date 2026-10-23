import 'dart:io';

import 'package:budget_app/capture/capture_service.dart';
import 'package:budget_app/data/database.dart';
import 'package:budget_app/data/models.dart';
import 'package:budget_app/data/repository.dart';
import 'package:budget_app/io/backup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Database db;
  late Repository repo;
  final t0 = DateTime(2026, 10, 14, 19, 30);

  setUp(() async {
    db = await openAppDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    repo = Repository(db);
  });
  tearDown(() => db.close());

  Future<Txn> insert(Txn t) async => (await repo.txnById(await repo.insertTxn(t)))!;

  group('bill splitting', () {
    test('÷3 keeps my share in stats and creates unnamed debts', () async {
      final dinner = await insert(Txn(time: t0, amountMinor: 30001, currency: 'CNY', kind: TxnKind.expense, source: 'alipay:screen'));
      await splitEqually(repo, dinner, 3);
      final t = (await repo.txnById(dinner.id!))!;
      expect(t.shareMinor, 10001); // the odd fen stays with me
      expect(t.effectiveMinor, 10001);
      final debts = await repo.debtsForTxn(t.id!);
      expect(debts.map((d) => d.amountMinor), [10000, 10000]);
      expect(debts.every((d) => d.person == null), isTrue);
    });

    test('a named friend paying back closes the debt and is not income', () async {
      final dinner = await insert(Txn(time: t0, amountMinor: 12000, currency: 'CNY', kind: TxnKind.expense));
      await repo.setDebts(dinner.id!, [('Alex', 6000)], 'CNY');
      final back = await insert(Txn(
          time: t0.add(const Duration(hours: 2)), amountMinor: 6000, currency: 'CNY', kind: TxnKind.income,
          merchant: 'Alex', source: 'wechat:prompt'));
      expect(await repo.settleDebtsWith(back), isTrue);
      expect((await repo.txnById(back.id!))!.excluded, isTrue);
      expect(await repo.openDebts(), isEmpty);
    });

    test('unnamed debt is matched by exact amount only', () async {
      final dinner = await insert(Txn(time: t0, amountMinor: 9000, currency: 'CNY', kind: TxnKind.expense));
      await splitEqually(repo, dinner, 3);
      final other = await insert(Txn(time: t0, amountMinor: 2500, currency: 'CNY', kind: TxnKind.income, merchant: 'Kirill'));
      expect(await repo.settleDebtsWith(other), isFalse);
      final exact = await insert(Txn(time: t0, amountMinor: 3000, currency: 'CNY', kind: TxnKind.income, merchant: 'Kirill'));
      expect(await repo.settleDebtsWith(exact), isTrue);
      expect(await repo.openDebts(), hasLength(1));
    });

    test('payback larger than the debt is a normal income', () async {
      final dinner = await insert(Txn(time: t0, amountMinor: 4000, currency: 'CNY', kind: TxnKind.expense));
      await repo.setDebts(dinner.id!, [('Alex', 2000)], 'CNY');
      final salary = await insert(Txn(time: t0, amountMinor: 50000, currency: 'CNY', kind: TxnKind.income, merchant: 'Alex'));
      expect(await repo.settleDebtsWith(salary), isFalse);
      expect(await repo.openDebts(), hasLength(1));
    });

    test('importer: "÷2" from the notification and an incoming WeChat answer settle automatically', () async {
      final importer = CaptureImporter(repo);
      CapturedPayment cp(Map<String, Object?> j) => CapturedPayment.fromJson({
            'app': 'alipay', 'direction': 'expense', 'currency': 'CNY', 'merchant': null, 'method': null,
            'ts': t0.millisecondsSinceEpoch, 'raw': '', ...j,
          });
      await importer.importAll([cp({'source': 'screen', 'amountMinor': 8000, 'merchant': '海底捞'})]);
      await importer.importAll([cp({'source': 'split', 'amountMinor': 8000, 'promptId': 2})]);
      final dinner = (await repo.allTxns()).single;
      expect(dinner.shareMinor, 4000);

      await importer.importAll([
        cp({
          'source': 'prompt_answer', 'app': 'wechat', 'direction': 'income', 'amountMinor': 4000,
          'merchant': 'Alex', 'promptId': 5, 'ts': t0.add(const Duration(hours: 1)).millisecondsSinceEpoch,
        }),
      ]);
      final payback = (await repo.allTxns()).firstWhere((t) => t.kind == TxnKind.income);
      expect(payback.excluded, isTrue);
      expect(await repo.openDebts(), isEmpty);
    });
  });

  group('bank notifications', () {
    test('first notification of a bank creates its account; push + SMS of one payment merge', () async {
      final importer = CaptureImporter(repo);
      CapturedPayment bank(String source) => CapturedPayment.fromJson({
            'source': source, 'app': 'sber', 'direction': 'expense', 'amountMinor': 45000, 'currency': 'RUB',
            'merchant': 'Магнит', 'method': 'Сбер', 'ts': t0.millisecondsSinceEpoch, 'raw': '',
          });
      await importer.importAll([bank('bank')]);
      await importer.importAll([bank('sms')]);
      final txns = await repo.allTxns();
      expect(txns, hasLength(1));
      expect(txns.single.currency, 'RUB');
      final sber = (await repo.accounts()).where((a) => a.type == 'sber').single;
      expect(sber.name, 'Сбер');
      expect(sber.currency, 'RUB');
      expect(txns.single.accountId, sber.id);
    });
  });

  group('goals and balances', () {
    test('monthly need and the months it reserves', () {
      final g = Goal(
        id: 1, name: 'Trip', targetMinor: 800000, savedMinor: 200000, currency: 'CNY',
        deadline: DateTime(2026, 12, 20), createdAt: DateTime(2026, 10, 14),
      );
      final now = DateTime(2026, 10, 14);
      expect(g.monthsLeft(now), 3);
      expect(g.monthlyNeed(now), 200000);
      expect(g.reservesIn(DateTime(2026, 10)), isTrue);
      expect(g.reservesIn(DateTime(2027, 1)), isFalse);
      expect(g.reservesIn(DateTime(2026, 9)), isFalse);
      final noDeadline = Goal(id: 2, name: 'x', targetMinor: 100, savedMinor: 0, currency: 'CNY', createdAt: now);
      expect(noDeadline.monthlyNeed(now), 0);
    });

    test('goal transfer moves the account balance but is not an expense', () async {
      final a = (await repo.accounts()).first;
      await repo.setAccountBalance(a.id, 100000, t0);
      await insert(Txn(
          time: t0.add(const Duration(minutes: 5)), amountMinor: 30000, currency: 'CNY', kind: TxnKind.expense,
          excluded: true, accountId: a.id, merchant: 'Trip', source: 'goal'));
      expect((await repo.accountBalances())[a.id], 70000);
      final txns = await repo.allTxns();
      final p = await repo.txnsBetween(t0, t0.add(const Duration(days: 1)));
      expect(p.single.excluded, isTrue);
      expect(txns.single.isCaptured, isTrue, reason: 'source "goal" is not manual');
    });

    test('goal remembers its account', () async {
      final a = (await repo.accounts()).first;
      final id = await repo.addGoal(name: 'Trip', targetMinor: 1000, savedMinor: 0, currency: 'CNY', reserve: false, accountId: a.id);
      expect((await repo.goals()).firstWhere((g) => g.id == id).accountId, a.id);
    });

    test('account balance = reconciled amount + later transactions', () async {
      final a = (await repo.accounts()).first;
      await insert(Txn(time: t0.subtract(const Duration(days: 1)), amountMinor: 9999, currency: 'CNY', kind: TxnKind.expense, accountId: a.id));
      await repo.setAccountBalance(a.id, 100000, t0);
      await insert(Txn(time: t0.add(const Duration(hours: 1)), amountMinor: 2500, currency: 'CNY', kind: TxnKind.expense, accountId: a.id));
      await insert(Txn(time: t0.add(const Duration(hours: 2)), amountMinor: 10000, currency: 'CNY', kind: TxnKind.income, accountId: a.id));
      expect((await repo.accountBalances())[a.id], 107500);
    });
  });

  group('country preset', () {
    test('fresh install in Kazakhstan gets KZT and Kaspi/Halyk/cash', () async {
      await repo.applyCountryPreset('KZ', fresh: true, cashName: 'Қолма-қол');
      expect(await repo.setting('base_currency'), 'KZT');
      final accounts = await repo.accounts();
      expect(accounts.map((a) => a.type), ['kaspi', 'halyk', 'cash']);
      expect(accounts.every((a) => a.currency == 'KZT'), isTrue);
      expect(accounts.last.key, 'cash');
    });

    test('existing data is left alone', () async {
      final before = await repo.accounts();
      await repo.applyCountryPreset('RU', fresh: false, cashName: 'Наличные');
      expect(await repo.setting('country'), 'RU');
      expect((await repo.accounts()).map((a) => a.id), before.map((a) => a.id));
      expect(await repo.setting('base_currency'), 'CNY');
    });

    test('built-in categories have translation keys', () async {
      final keys = (await repo.categories()).map((c) => c.key).toSet();
      expect(keys, containsAll(['food', 'transport', 'transfers_out', 'transfers_in', 'other_income']));
    });
  });

  group('backup', () {
    test('serialize -> restore round-trips all data and keeps local backup settings', () async {
      final backup = BackupService(repo);
      await insert(Txn(time: t0, amountMinor: 1234, currency: 'CNY', kind: TxnKind.expense, merchant: '全家'));
      await repo.addGoal(name: 'Trip', targetMinor: 1000, savedMinor: 10, currency: 'CNY', reserve: true);
      await repo.setSetting('backup_uri', 'content://old-phone');
      final payload = await backup.serialize();

      // "New phone": different data, its own backup folder.
      final db2 = await openAppDatabase(factory: databaseFactoryFfi, path: '${Directory.systemTemp.path}/restore_${DateTime.now().microsecondsSinceEpoch}.db');
      final repo2 = Repository(db2);
      await repo2.setSetting('backup_uri', 'content://new-phone');
      await repo2.insertTxn(Txn(time: t0, amountMinor: 1, currency: 'CNY', kind: TxnKind.expense));
      await BackupService(repo2).restore(payload);

      final txns = await repo2.allTxns();
      expect(txns.single.merchant, '全家');
      expect((await repo2.goals()).single.name, 'Trip');
      expect(await repo2.setting('backup_uri'), 'content://new-phone');
      await db2.close();
    });
  });
}
