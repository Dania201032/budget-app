import 'dart:io';

import 'package:budget_app/data/database.dart';
import 'package:budget_app/data/models.dart';
import 'package:budget_app/data/repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('v2 -> v3 keeps merchant rules (with their direction) and adds the expense "Переводы"', () async {
    final dir = await Directory.systemTemp.createTemp('budget_migration');
    final path = '${dir.path}/budget.db';
    // The parts of the v2 schema the migration touches, as on the user's phone.
    final old = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, _) async {
            await db.execute('CREATE TABLE categories(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, '
                'icon TEXT NOT NULL, color INTEGER NOT NULL, kind TEXT NOT NULL, sort INTEGER NOT NULL DEFAULT 0, '
                'archived INTEGER NOT NULL DEFAULT 0)');
            await db.execute('CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)');
            await db.execute('CREATE TABLE accounts(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, '
                'currency TEXT NOT NULL, type TEXT NOT NULL, sort INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0)');
            await db.execute('CREATE TABLE transactions(id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, '
                'amount_minor INTEGER NOT NULL, currency TEXT NOT NULL, kind TEXT NOT NULL, category_id INTEGER, '
                "account_id INTEGER, merchant TEXT, note TEXT, source TEXT NOT NULL DEFAULT 'manual', "
                'needs_review INTEGER NOT NULL DEFAULT 0, raw TEXT, created_at INTEGER NOT NULL)');
            await db.execute('CREATE TABLE merchant_rules(merchant TEXT PRIMARY KEY, category_id INTEGER NOT NULL, '
                'updated_at INTEGER NOT NULL)');
            await db.insert('categories', {'id': 1, 'name': 'Еда', 'icon': 'restaurant', 'color': 1, 'kind': 'expense'});
            await db.insert('categories', {'id': 13, 'name': 'Переводы', 'icon': 'swap_horiz', 'color': 1, 'kind': 'income'});
            await db.insert('merchant_rules', {'merchant': '全家便利店', 'category_id': 1, 'updated_at': 1});
            await db.insert('merchant_rules', {'merchant': 'Alex', 'category_id': 13, 'updated_at': 1});
          },
        ));
    await old.close();

    final db = await openAppDatabase(factory: databaseFactoryFfi, path: path);
    final repo = Repository(db);
    expect(await repo.categoryForMerchant('全家便利店', TxnKind.expense), 1);
    expect(await repo.categoryForMerchant('Alex', TxnKind.income), 13);
    expect(await repo.categoryForMerchant('Alex', TxnKind.expense), isNull);
    final expenseTransfers = (await repo.categories()).where((c) => c.name == 'Переводы' && c.kind == TxnKind.expense);
    expect(expenseTransfers, hasLength(1));
    await db.close();
    await dir.delete(recursive: true);
  });

  Repository repo0(Database db) => Repository(db);

  // Optional: a copy of the real phone database (not committed).
  final real = File(r'D:\dev\tmp\budget.db');
  test('real phone database upgrades without losing anything', () async {
    final dir = await Directory.systemTemp.createTemp('budget_real');
    final path = '${dir.path}/budget.db';
    await real.copy(path);
    final before = await databaseFactoryFfi.openDatabase(path);
    final txCount = Sqflite.firstIntValue(await before.rawQuery('SELECT COUNT(*) FROM transactions'));
    // The bogus "Pay / Receive" rule (v0.2 bug) is dropped on purpose.
    final ruleCount = Sqflite.firstIntValue(
        await before.rawQuery("SELECT COUNT(*) FROM merchant_rules WHERE merchant != 'Pay / Receive'"));
    await before.close();

    final db = await openAppDatabase(factory: databaseFactoryFfi, path: path);
    expect(await db.getVersion(), schemaVersion);
    expect(await repo0(db).setting('budget_enabled'), '1', reason: 'existing users keep their budget');
    expect(Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM transactions')), txCount);
    expect(Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM merchant_rules')), ruleCount);
    final repo = Repository(db);
    expect((await repo.categories()).where((c) => c.name == 'Переводы' && c.kind == TxnKind.expense), hasLength(1));
    // ignore: avoid_print
    print('real db: $txCount transactions, $ruleCount rules, '
        'rules: ${await db.rawQuery('SELECT merchant, kind, category_id FROM merchant_rules')}');
    await db.close();
    await dir.delete(recursive: true);
  }, skip: real.existsSync() ? false : 'no local copy');
}
