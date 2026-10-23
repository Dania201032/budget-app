import 'dart:io';

import 'package:budget_app/data/database.dart';
import 'package:budget_app/data/models.dart';
import 'package:budget_app/data/repository.dart';
import 'package:budget_app/sync/sync_crypto.dart';
import 'package:budget_app/sync/sync_engine.dart';
import 'package:budget_app/sync/sync_folder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The phone and the computer as two databases sharing a cloud folder.
void main() {
  sqfliteFfiInit();
  late Directory tmp;
  late IoSyncFolder folder;
  late SyncCipher cipher;
  late Repository phone;
  late Repository pc;
  late SyncEngine phoneSync;
  late SyncEngine pcSync;
  final t0 = DateTime(2026, 10, 20, 12);

  Future<Repository> open(String name) async =>
      Repository(await openAppDatabase(factory: databaseFactoryFfi, path: '${tmp.path}/$name.db'));

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('budget_sync_');
    folder = IoSyncFolder('${tmp.path}/drive');
    // Few rounds: the real number makes each test seconds slower and proves nothing more.
    cipher = await SyncCipher.fromPassword('secret', SyncCipher.newSalt(), rounds: 1000);
    phone = await open('phone');
    pc = await open('pc');
    phoneSync = SyncEngine(phone.db, folder, cipher, 'aaaa0001');
    pcSync = SyncEngine(pc.db, folder, cipher, 'bbbb0002');
  });

  tearDown(() async {
    await phone.db.close();
    await pc.db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<int> food(Repository r) async => (await r.categories()).firstWhere((c) => c.key == 'food').id;
  Future<List<Txn>> all(Repository r) => r.txnsBetween(DateTime(2026), DateTime(2027));

  Txn expense(int minor, int? category, {String? merchant, int? account}) => Txn(
      time: t0, amountMinor: minor, currency: 'CNY', kind: TxnKind.expense, categoryId: category,
      merchant: merchant, accountId: account, source: 'manual');

  /// The phone has data and turns sync on first; the fresh computer joins and gets it all.
  Future<void> pairUp() async {
    await phone.insertTxn(expense(4500, await food(phone), merchant: 'Lanzhou noodles'));
    await phone.setSetting('budget_enabled', '1');
    await phoneSync.enable();
    await pcSync.enable();
  }

  test('a fresh computer joining gets the phone\'s data with the right categories', () async {
    final alipay = (await phone.accounts()).firstWhere((a) => a.type == 'alipay').id;
    await phone.insertTxn(expense(1200, await food(phone), merchant: 'Coffee', account: alipay));
    // The computer has seed data of its own that must not be mixed in.
    await pc.addAccount('Old account', 'CNY', 'bank');
    await pairUp();

    final txns = await all(pc);
    expect(txns.map((t) => t.merchant).toSet(), {'Coffee', 'Lanzhou noodles'});
    final coffee = txns.firstWhere((t) => t.merchant == 'Coffee');
    expect(coffee.categoryId, await food(pc));
    expect((await pc.accounts()).firstWhere((a) => a.id == coffee.accountId).type, 'alipay');
    expect((await pc.accounts()).any((a) => a.name == 'Old account'), isFalse);
    expect(await pc.setting('budget_enabled'), '1');
  });

  test('additions, edits and deletions travel both ways', () async {
    await pairUp();
    // Added on the computer.
    final id = await pc.insertTxn(expense(9900, await food(pc), merchant: 'Rent deposit'));
    await pcSync.run();
    await phoneSync.run();
    final onPhone = (await all(phone)).firstWhere((t) => t.merchant == 'Rent deposit');
    expect(onPhone.amountMinor, 9900);

    // Edited on the phone.
    await phone.updateTxn(onPhone.copyWith(amountMinor: 9000, merchant: () => 'Deposit'));
    await phoneSync.run();
    await pcSync.run();
    final onPc = (await pc.txnById(id))!;
    expect(onPc.amountMinor, 9000);
    expect(onPc.merchant, 'Deposit');

    // Deleted on the computer.
    await pc.deleteTxn(id);
    await pcSync.run();
    await phoneSync.run();
    expect((await all(phone)).any((t) => t.merchant == 'Deposit'), isFalse);
  });

  test('the same row changed on both: the later change wins on both', () async {
    await pairUp();
    final p = (await all(phone)).single;
    final c = (await all(pc)).single;
    await phone.updateTxn(p.copyWith(note: () => 'from the phone'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await pc.updateTxn(c.copyWith(note: () => 'from the computer'));
    await phoneSync.run();
    await pcSync.run();
    await phoneSync.run();
    expect((await all(phone)).single.note, 'from the computer');
    expect((await all(pc)).single.note, 'from the computer');
  });

  test('references between rows: transfer pairs, debts, new categories', () async {
    await pairUp();
    final cat = await phone.addCategory('Gym', TxnKind.expense, 'fitness_center', 0xFF000000);
    final a = await phone.insertTxn(expense(50000, cat, merchant: 'VTB'));
    final b = await phone.insertTxn(Txn(time: t0, amountMinor: 50000, currency: 'CNY', kind: TxnKind.income, source: 'manual'));
    await phone.linkOwnTransfer((await phone.txnById(a))!, await phone.txnById(b));
    await phone.setDebts(a, [('Alex', 25000)], 'CNY');
    await phoneSync.run();
    await pcSync.run();

    final out = (await all(pc)).firstWhere((t) => t.merchant == 'VTB');
    expect((await pc.categories()).firstWhere((c) => c.id == out.categoryId).name, 'Gym');
    expect(out.ownTransfer, isTrue);
    final twin = (await pc.txnById(out.pairId!))!;
    expect(twin.kind, TxnKind.income);
    expect(twin.pairId, out.id);
    final debts = await pc.openDebts();
    expect(debts.single.person, 'Alex');
    expect(debts.single.txnId, out.id);
  });

  test('settings: shared ones travel, per-device ones stay', () async {
    await pairUp();
    await phone.setSetting('base_currency', 'EUR');
    await phone.setSetting('language', 'de');
    await phoneSync.run();
    await pcSync.run();
    expect(await pc.setting('base_currency'), 'EUR');
    expect(await pc.setting('language'), isNot('de'));
  });

  test('nothing to send when nothing changed; files are encrypted', () async {
    await pairUp();
    final before = await folder.list();
    final r = await phoneSync.run();
    expect(r.sent, 0);
    expect(await folder.list(), before);
    final file = before.firstWhere((n) => n.startsWith('bs-aaaa0001'));
    final bytes = (await folder.read(file))!;
    expect(String.fromCharCodes(bytes).contains('Lanzhou'), isFalse);
  });

  test('the folder\'s password: set by the first device, checked on the next', () async {
    final group = IoSyncFolder('${tmp.path}/group');
    final first = await SyncEngine.openGroup(group, 'correct horse');
    final again = await SyncEngine.openGroup(group, 'correct horse');
    final sealed = await first.seal([1, 2, 3]);
    expect(await again.open(sealed), [1, 2, 3]);
    expect(() => SyncEngine.openGroup(group, 'wrong'), throwsA(isA<WrongSyncPassword>()));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
