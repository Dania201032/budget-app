import 'dart:io';

import 'package:budget_app/data/database.dart';
import 'package:budget_app/data/models.dart';
import 'package:budget_app/data/repository.dart';
import 'package:budget_app/household/household.dart';
import 'package:budget_app/sync/sync_crypto.dart';
import 'package:budget_app/sync/sync_engine.dart';
import 'package:budget_app/sync/sync_folder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The shared budget on three devices: my phone, my computer and my partner's phone, one folder.
void main() {
  sqfliteFfiInit();
  late Directory tmp;
  late IoSyncFolder folder;
  late SyncCipher group;
  late SyncCipher myKey;
  final t0 = DateTime(2026, 10, 20, 12);

  Future<Repository> open(String name) async =>
      Repository(await openAppDatabase(factory: databaseFactoryFfi, path: '${tmp.path}/$name.db'));

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('budget_household_');
    folder = IoSyncFolder('${tmp.path}/drive');
    group = await SyncCipher.fromPassword('family', SyncCipher.newSalt(), rounds: 1000);
    myKey = await SyncCipher.fromPassword('mine', SyncCipher.newSalt(), rounds: 1000);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Txn expense(int minor, int account, {String? merchant}) =>
      Txn(time: t0, amountMinor: minor, currency: 'CNY', kind: TxnKind.expense, accountId: account, merchant: merchant);

  Future<List<Txn>> all(Repository r) => r.txnsBetween(DateTime(2026), DateTime(2027));

  test('hidden accounts reach only their owner\'s devices; hiding and showing again', () async {
    final phone = await open('phone');
    // Me, on my phone: the budget, both of us, a common and a hidden account.
    await phone.setHousehold(const HouseholdConfig(hiddenAccounts: true, personalLimits: true));
    final me = await phone.addPerson('Dan');
    final partner = await phone.addPerson('Ann');
    phone.me = me;
    final common = await phone.addAccount('Home card', 'CNY', 'bank');
    final secret = await phone.addAccount('My savings', 'CNY', 'bank', owner: me);
    await phone.setAccountHidden(secret, true);
    await phone.insertTxn(expense(1000, common, merchant: 'Groceries'));
    await phone.insertTxn(expense(5000, secret, merchant: 'Gift for Ann'));
    await phone.setPersonalBudget(me, 100000, 'CNY');
    final phoneSync = SyncEngine(phone.db, folder, group, 'aaaa0001', person: me, personCipher: myKey);
    await phoneSync.enable();
    expect((await all(phone)).map((t) => t.author).toSet(), {me});

    // My partner's phone joins fresh.
    final theirs = await open('partner');
    final theirSync = SyncEngine(theirs.db, folder, group, 'bbbb0002', person: partner);
    await theirSync.enable();
    theirs.me = partner;
    expect((await all(theirs)).map((t) => t.merchant), ['Groceries']);
    expect((await theirs.accounts()).map((a) => a.name), isNot(contains('My savings')));
    expect((await theirs.people()).map((p) => p.name).toSet(), {'Dan', 'Ann'});
    expect(await theirs.personalBudget(me), (100000, 'CNY'));
    expect((await theirs.household())!.personalLimits, isTrue);
    // Every operation knows who recorded it.
    expect((await all(theirs)).single.author, me);

    // My computer joins as me, with my personal password's key: it sees everything.
    final pc = await open('pc');
    final pcSync = SyncEngine(pc.db, folder, group, 'cccc0003', person: me, personCipher: myKey);
    await pcSync.enable();
    expect((await all(pc)).map((t) => t.merchant).toSet(), {'Groceries', 'Gift for Ann'});
    expect((await pc.accounts()).firstWhere((a) => a.name == 'My savings').hidden, isTrue);

    // Shown again: the partner gets the account and its operations.
    await phone.setAccountHidden(secret, false);
    await phoneSync.run();
    await theirSync.run();
    expect((await all(theirs)).map((t) => t.merchant).toSet(), {'Groceries', 'Gift for Ann'});

    // Hidden again: gone from the partner's phone, still on my computer.
    await phone.setAccountHidden(secret, true);
    await phoneSync.run();
    await theirSync.run();
    await pcSync.run();
    expect((await all(theirs)).map((t) => t.merchant), ['Groceries']);
    expect((await theirs.accounts()).map((a) => a.name), isNot(contains('My savings')));
    expect((await all(pc)).map((t) => t.merchant).toSet(), {'Groceries', 'Gift for Ann'});

    // What I add to the hidden account later reaches my computer only.
    await phone.insertTxn(expense(700, secret, merchant: 'Secret 2'));
    await phoneSync.run();
    await theirSync.run();
    await pcSync.run();
    expect((await all(pc)).map((t) => t.merchant), contains('Secret 2'));
    expect((await all(theirs)).map((t) => t.merchant), isNot(contains('Secret 2')));

    // The partner's own record comes to me with their name on it.
    final theirAccount = (await theirs.accounts()).firstWhere((a) => a.name == 'Home card').id;
    await theirs.insertTxn(expense(300, theirAccount, merchant: 'Coffee'));
    await theirSync.run();
    await phoneSync.run();
    expect((await all(phone)).firstWhere((t) => t.merchant == 'Coffee').author, partner);

    for (final r in [phone, theirs, pc]) {
      await r.db.close();
    }
  });

  test('a person with records of their own joins: theirs stay theirs, categories merge, the budget\'s settings stay', () async {
    final phone = await open('phone');
    await phone.setHousehold(const HouseholdConfig());
    final me = await phone.addPerson('Dan');
    phone.me = me;
    await phone.setSetting('base_currency', 'CNY');
    await phone.addCategory('Coffee', TxnKind.expense, 'coffee', 0xFF000000);
    final cash = (await phone.accounts()).firstWhere((a) => a.key == 'cash').id;
    await phone.insertTxn(expense(1000, cash, merchant: 'Lunch'));
    await SyncEngine(phone.db, folder, group, 'aaaa0001', person: me).enable();

    // The partner already kept their own budget, in roubles, with a "Coffee" category too.
    final theirs = await open('partner');
    await theirs.setSetting('base_currency', 'RUB');
    final coffee = await theirs.addCategory('Coffee', TxnKind.expense, 'coffee', 0xFF111111);
    final theirCash = (await theirs.accounts()).firstWhere((a) => a.key == 'cash').id;
    await theirs.insertTxn(expense(300, theirCash, merchant: 'Latte').copyWith(categoryId: () => coffee));
    final (people, setup) = await SyncEngine.peek(folder, group);
    expect(people.values, ['Dan']);
    expect(setup, isNotNull);

    late String partner;
    final sync = SyncEngine(theirs.db, folder, group, 'bbbb0002');
    await sync.enable(
      beforeTake: () async {
        partner = await theirs.addPerson('Ann');
        await theirs.claimAsMine(partner, 'Ann');
      },
      beforeSend: () async => theirs.mergeSameNamedCategories(),
    );
    theirs.me = partner;

    // Both have both operations; two cash wallets, not one; one "Coffee".
    await SyncEngine(phone.db, folder, group, 'aaaa0001', person: me).run();
    for (final r in [phone, theirs]) {
      expect((await all(r)).map((t) => t.merchant).toSet(), {'Lunch', 'Latte'});
      final accounts = await r.accounts();
      expect(accounts.where((a) => a.type == 'cash'), hasLength(2));
      expect((await r.categories()).where((c) => c.name == 'Coffee'), hasLength(1));
      expect(await r.setting('base_currency'), 'CNY');
    }
    final latte = (await all(phone)).firstWhere((t) => t.merchant == 'Latte');
    expect(latte.author, partner);
    expect((await phone.accounts()).firstWhere((a) => a.id == latte.accountId).owner, partner);
    expect(latte.categoryId, (await phone.categories()).firstWhere((c) => c.name == 'Coffee').id);
    await phone.db.close();
    await theirs.db.close();
  });

  test('capture: my payments go to my accounts, and the partner\'s same payment is not mine', () async {
    final repo = await open('phone');
    final me = await repo.addPerson('Dan');
    final partner = await repo.addPerson('Ann');
    // The accounts this phone came with are the partner's here.
    await repo.claimAsMine(partner, 'Ann');
    final theirAlipay = await repo.addAccount('Alipay', 'CNY', 'alipay', owner: partner);
    await repo.insertTxn(Txn(
        time: t0, amountMinor: 300, currency: 'CNY', kind: TxnKind.expense, accountId: theirAlipay, source: 'alipay:screen', author: partner));
    repo.me = me;
    expect((await repo.myAccounts()).where((a) => a.type == 'alipay'), isEmpty);
    // Both of us paid for the metro in the same minute: theirs is no twin of mine.
    expect(await repo.findSamePayment(appPrefix: 'alipay', kind: TxnKind.expense, amountMinor: 300, time: t0), isNull);
    await repo.db.close();
  });
}
