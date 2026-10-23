import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show databaseFactoryFfi, sqfliteFfiInit;
import 'package:sqflite_sqlcipher/sqflite.dart' as cipher;
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../io/app_log.dart';
import '../platform.dart';
import '../security/secure_store.dart';
import '../sync/sync_tables.dart';

const schemaVersion = 9;

/// Tables in dependency order (parents first) — used by backup/restore.
const backupTables = [
  'settings', 'accounts', 'categories', 'budgets', 'merchant_rules', 'rates', 'manual_rates',
  'transactions', 'goals', 'debts', 'dismissed', 'recurring',
];

Future<void> _configure(Database db) => db.execute('PRAGMA foreign_keys = ON');

Future<void> _create(Database db, int _) async {
  await _createV1(db);
  await _createV2(db);
  await _seed(db);
  await _migrateV3(db);
  await _migrateV4(db, fresh: true);
  await _migrateV5(db);
  await _migrateV6(db);
  await _migrateV7(db);
  await _migrateV8(db);
  await migrateSyncV9(db);
}

Future<void> _upgrade(Database db, int from, int to) async {
  if (from < 2) await _createV2(db);
  if (from < 3) await _migrateV3(db);
  if (from < 4) await _migrateV4(db, fresh: false);
  if (from < 5) await _migrateV5(db);
  if (from < 6) await _migrateV6(db);
  if (from < 7) await _migrateV7(db);
  if (from < 8) await _migrateV8(db);
  // v9: sync between the phone and the computer (uids, change log).
  if (from < 9) await migrateSyncV9(db);
}

/// The app's database. On the phone it is encrypted (SQLCipher, AES-256) with a random key kept
/// by the phone's secure hardware; tests pass a [factory] and get a plain one.
Future<Database> openAppDatabase({DatabaseFactory? factory, String? path}) async {
  if (factory != null) {
    final dbPath = path ?? p.join(await factory.getDatabasesPath(), 'budget.db');
    return factory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(version: schemaVersion, onConfigure: _configure, onCreate: _create, onUpgrade: _upgrade),
    );
  }
  if (appIsDesktop) return openDesktopDatabase(path: path);
  final dbPath = path ?? p.join(await cipher.getDatabasesPath(), 'budget.db');
  final key = await _databaseKey();
  await _encryptIfPlain(dbPath, key);
  Future<Database> open() => cipher.openDatabase(dbPath,
      password: key, version: schemaVersion, onConfigure: _configure, onCreate: _create, onUpgrade: _upgrade);
  try {
    return await open();
  } on DatabaseException catch (e) {
    // The key is gone (secure storage wiped) and the file can't be read: keep it aside and start
    // empty — the onboarding offers to restore from a backup.
    debugPrint('Database unreadable, kept aside: $e');
    final aside = '$dbPath.unreadable-${DateTime.now().millisecondsSinceEpoch}';
    if (File(dbPath).existsSync()) File(dbPath).renameSync(aside);
    return open();
  }
}

/// The computer's database (Windows): SQLite3MultipleCiphers through FFI, encrypted with the same kind
/// of random key, kept in the system's credential store. [key] is given by tests.
Future<Database> openDesktopDatabase({String? path, String? key}) async {
  sqfliteFfiInit();
  final dbPath = path ?? p.join((await getApplicationSupportDirectory()).path, 'budget.db');
  AppLog.line('database: key');
  final dbKey = key ?? await _databaseKey();
  AppLog.line('database: opening $dbPath');
  return databaseFactoryFfi.openDatabase(
    dbPath,
    options: OpenDatabaseOptions(
      version: schemaVersion,
      // The key must come before anything else reads the file.
      onConfigure: (db) async {
        await db.execute("PRAGMA key = '$dbKey'");
        await _configure(db);
      },
      onCreate: _create,
      onUpgrade: _upgrade,
    ),
  );
}

/// A random 256-bit key, made on first start and kept in the Keystore / Keychain (this device only).
Future<String> _databaseKey() async {
  final store = SecureStore.instance;
  final existing = await store.read('db_key');
  if (existing != null) return existing;
  final r = Random.secure();
  final key = List.generate(32, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  await store.write('db_key', key);
  return key;
}

/// Databases from before encryption (v0.8.x) are rewritten encrypted once, in place.
Future<void> _encryptIfPlain(String path, String key) async {
  final file = File(path);
  if (!file.existsSync() || file.lengthSync() < 16) return;
  final raf = file.openSync();
  final head = String.fromCharCodes(raf.readSync(15));
  raf.closeSync();
  if (head != 'SQLite format 3') return;

  final tmp = '$path.encrypting';
  if (File(tmp).existsSync()) File(tmp).deleteSync();
  final plain = await cipher.openDatabase(path, singleInstance: false);
  final version = await plain.getVersion();
  await plain.execute("ATTACH DATABASE '${tmp.replaceAll("'", "''")}' AS enc KEY '$key'");
  await plain.rawQuery("SELECT sqlcipher_export('enc')");
  await plain.execute('PRAGMA enc.user_version = $version');
  await plain.execute('DETACH DATABASE enc');
  await plain.close();

  file.renameSync('$path.plain');
  File(tmp).renameSync(path);
  for (final leftover in ['$path.plain', '$path-journal', '$path-wal', '$path-shm']) {
    if (File(leftover).existsSync()) File(leftover).deleteSync();
  }
}

Future<void> _createV1(Database db) async {
  final b = db.batch();
  b.execute('''
    CREATE TABLE accounts(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      currency TEXT NOT NULL,
      type TEXT NOT NULL,
      sort INTEGER NOT NULL DEFAULT 0,
      archived INTEGER NOT NULL DEFAULT 0
    )''');
  b.execute('''
    CREATE TABLE categories(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      icon TEXT NOT NULL,
      color INTEGER NOT NULL,
      kind TEXT NOT NULL,
      sort INTEGER NOT NULL DEFAULT 0,
      archived INTEGER NOT NULL DEFAULT 0
    )''');
  b.execute('''
    CREATE TABLE transactions(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts INTEGER NOT NULL,
      amount_minor INTEGER NOT NULL,
      currency TEXT NOT NULL,
      kind TEXT NOT NULL,
      category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
      account_id INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
      merchant TEXT,
      note TEXT,
      source TEXT NOT NULL DEFAULT 'manual',
      needs_review INTEGER NOT NULL DEFAULT 0,
      raw TEXT,
      created_at INTEGER NOT NULL
    )''');
  b.execute('CREATE INDEX idx_transactions_ts ON transactions(ts)');
  // One budget per month ("2026-10"); months without a row use the latest earlier budget.
  b.execute('''
    CREATE TABLE budgets(
      month TEXT PRIMARY KEY,
      amount_minor INTEGER NOT NULL,
      currency TEXT NOT NULL
    )''');
  // Learned "merchant -> category" for auto-captured payments.
  b.execute('''
    CREATE TABLE merchant_rules(
      merchant TEXT PRIMARY KEY,
      category_id INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
      updated_at INTEGER NOT NULL
    )''');
  b.execute('CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)');
  await b.commit(noResult: true);
}

/// Exchange rates: `rate` = how many [quote] for 1 [base] on [date] (yyyy-MM-dd).
/// Manual rates override downloaded ones for every date.
Future<void> _createV2(Database db) async {
  final b = db.batch();
  b.execute('''
    CREATE TABLE rates(
      date TEXT NOT NULL,
      base TEXT NOT NULL,
      quote TEXT NOT NULL,
      rate REAL NOT NULL,
      PRIMARY KEY(date, base, quote)
    )''');
  b.execute('''
    CREATE TABLE manual_rates(
      base TEXT NOT NULL,
      quote TEXT NOT NULL,
      rate REAL NOT NULL,
      PRIMARY KEY(base, quote)
    )''');
  await b.commit(noResult: true);
}

/// v3: merchant rules per direction — "Alex" can be "Переводы" as income and something else as
/// expense (a rule learned from an incoming transfer was applied to an outgoing one).
/// Also adds an expense category for transfers to people.
Future<void> _migrateV3(Database db) async {
  await db.execute('''
    CREATE TABLE merchant_rules_v3(
      merchant TEXT NOT NULL,
      kind TEXT NOT NULL,
      category_id INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY(merchant, kind)
    )''');
  await db.execute('''
    INSERT INTO merchant_rules_v3(merchant, kind, category_id, updated_at)
    SELECT r.merchant, c.kind, r.category_id, r.updated_at
    FROM merchant_rules r JOIN categories c ON c.id = r.category_id''');
  await db.execute('DROP TABLE merchant_rules');
  await db.execute('ALTER TABLE merchant_rules_v3 RENAME TO merchant_rules');
  // v0.2 took Alipay's page title for the merchant of payment-code payments.
  await db.delete('merchant_rules', where: 'merchant = ?', whereArgs: ['Pay / Receive']);

  final exists = await db.query('categories',
      where: "name = 'Переводы' AND kind = 'expense' AND archived = 0", limit: 1);
  if (exists.isEmpty) {
    final maxSort = Sqflite.firstIntValue(await db.rawQuery("SELECT MAX(sort) FROM categories WHERE kind = 'expense'")) ?? 0;
    await db.insert('categories', {
      'name': 'Переводы',
      'icon': 'swap_horiz',
      'color': 0xFF4A90C2,
      'kind': 'expense',
      'sort': maxSort + 1,
    });
  }
}

/// Keys of built-in categories, by their original Russian names (shown translated in the UI).
const defaultCategoryKeys = {
  ('Еда', 'expense'): 'food',
  ('Питьё', 'expense'): 'drinks',
  ('Транспорт', 'expense'): 'transport',
  ('Развлечения', 'expense'): 'fun',
  ('Покупки', 'expense'): 'shopping',
  ('Жильё', 'expense'): 'housing',
  ('Связь и подписки', 'expense'): 'subscriptions',
  ('Здоровье', 'expense'): 'health',
  ('Учёба', 'expense'): 'education',
  ('Другое', 'expense'): 'other',
  ('Переводы', 'expense'): 'transfers_out',
  ('Стипендия', 'income'): 'stipend',
  ('Зарплата', 'income'): 'salary',
  ('Переводы', 'income'): 'transfers_in',
  ('Другое', 'income'): 'other_income',
};

/// v4: bill splitting (my share, debts), account balances, savings goals, translated built-ins.
Future<void> _migrateV4(Database db, {required bool fresh}) async {
  await db.execute('ALTER TABLE transactions ADD COLUMN share_minor INTEGER');
  await db.execute('ALTER TABLE transactions ADD COLUMN excluded INTEGER NOT NULL DEFAULT 0');
  await db.execute('ALTER TABLE accounts ADD COLUMN key TEXT');
  await db.execute('ALTER TABLE accounts ADD COLUMN balance_minor INTEGER');
  await db.execute('ALTER TABLE accounts ADD COLUMN balance_at INTEGER');
  await db.execute('ALTER TABLE categories ADD COLUMN key TEXT');
  await db.execute('''
    CREATE TABLE goals(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      target_minor INTEGER NOT NULL,
      saved_minor INTEGER NOT NULL DEFAULT 0,
      currency TEXT NOT NULL,
      deadline INTEGER,
      reserve INTEGER NOT NULL DEFAULT 1,
      created_at INTEGER NOT NULL,
      archived INTEGER NOT NULL DEFAULT 0
    )''');
  await db.execute('''
    CREATE TABLE debts(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      txn_id INTEGER REFERENCES transactions(id) ON DELETE CASCADE,
      person TEXT,
      amount_minor INTEGER NOT NULL,
      settled_minor INTEGER NOT NULL DEFAULT 0,
      currency TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )''');

  for (final e in defaultCategoryKeys.entries) {
    await db.update('categories', {'key': e.value},
        where: 'name = ? AND kind = ? AND key IS NULL', whereArgs: [e.key.$1, e.key.$2]);
  }
  await db.update('accounts', {'key': 'cash'}, where: "type = 'cash'");
  // Existing users already work with a monthly budget; new ones turn it on themselves.
  await db.insert('settings', {'key': 'budget_enabled', 'value': fresh ? '0' : '1'},
      conflictAlgorithm: ConflictAlgorithm.replace);
}

/// v5: a goal can be linked to the account where its savings live.
Future<void> _migrateV5(Database db) async {
  await db.execute('ALTER TABLE goals ADD COLUMN account_id INTEGER REFERENCES accounts(id) ON DELETE SET NULL');
}

/// Built-in category colors before the ledger design (v0.7) → their ledger counterparts.
const ledgerPaletteMigration = <int, int>{
  0xFFE8833A: 0xFF2F7A66, // Еда
  0xFF8D6E63: 0xFF8C6A4A, // Питьё
  0xFF3F7FD9: 0xFF4A6FA5, // Транспорт
  0xFFB45AC9: 0xFF9A5B8C, // Развлечения
  0xFFD9506A: 0xFFC98A1E, // Покупки
  0xFF4C9A6A: 0xFF5E7F3A, // Жильё
  0xFF2BA3B5: 0xFF3E8E9E, // Связь и подписки
  0xFFE05252: 0xFFB5524A, // Здоровье
  0xFF6A6AD9: 0xFF6A64A8, // Учёба
  0xFF8A8F98: 0xFF8A8880, // Другое
  0xFF3E9E5C: 0xFF3E9A78, // Стипендия
  0xFF2E8B57: 0xFF4F9E86, // Зарплата
  0xFF4A90C2: 0xFF5B87A8, // Переводы
};

/// Defaults mirror the user's spreadsheet ("Еда", "Питьё", "Транспорт", "Развлечения", "Другое")
/// plus a few common categories.
Future<void> _seed(Database db) async {
  final b = db.batch();
  const accounts = [
    ('Alipay', 'CNY', 'alipay'),
    ('WeChat', 'CNY', 'wechat'),
    ('Наличные', 'CNY', 'cash'),
  ];
  for (var i = 0; i < accounts.length; i++) {
    final (name, currency, type) = accounts[i];
    b.insert('accounts', {'name': name, 'currency': currency, 'type': type, 'sort': i});
  }

  const expense = [
    ('Еда', 'restaurant', 0xFF2F7A66),
    ('Питьё', 'local_cafe', 0xFF8C6A4A),
    ('Транспорт', 'directions_bus', 0xFF4A6FA5),
    ('Развлечения', 'celebration', 0xFF9A5B8C),
    ('Покупки', 'shopping_bag', 0xFFC98A1E),
    ('Жильё', 'home', 0xFF5E7F3A),
    ('Связь и подписки', 'wifi', 0xFF3E8E9E),
    ('Здоровье', 'favorite', 0xFFB5524A),
    ('Учёба', 'school', 0xFF6A64A8),
    ('Другое', 'more_horiz', 0xFF8A8880),
  ];
  for (var i = 0; i < expense.length; i++) {
    final (name, icon, color) = expense[i];
    b.insert('categories', {'name': name, 'icon': icon, 'color': color, 'kind': 'expense', 'sort': i});
  }
  const income = [
    ('Стипендия', 'school', 0xFF3E9A78),
    ('Зарплата', 'work', 0xFF4F9E86),
    ('Переводы', 'swap_horiz', 0xFF5B87A8),
    ('Другое', 'more_horiz', 0xFF8A8880),
  ];
  for (var i = 0; i < income.length; i++) {
    final (name, icon, color) = income[i];
    b.insert('categories', {'name': name, 'icon': icon, 'color': color, 'kind': 'income', 'sort': i});
  }

  b.insert('settings', {'key': 'base_currency', 'value': 'CNY'});
  b.insert('settings', {'key': 'default_budget_minor', 'value': '300000'});
  b.insert('settings', {'key': 'default_budget_currency', 'value': 'CNY'});
  await b.commit(noResult: true);
}

/// Auto-captured operations the user deleted: re-reading a bank's history or Alipay's Bills
/// must not bring them back.
Future<void> _migrateV6(Database db) async {
  await db.execute('''
    CREATE TABLE dismissed(
      app TEXT NOT NULL,
      kind TEXT NOT NULL,
      amount_minor INTEGER NOT NULL,
      ts INTEGER NOT NULL
    )''');
}

/// v7: transfers between my own accounts (VTB → Sber) — excluded from stats, linked in pairs.
Future<void> _migrateV7(Database db) async {
  await db.execute('ALTER TABLE transactions ADD COLUMN own_transfer INTEGER NOT NULL DEFAULT 0');
  await db.execute('ALTER TABLE transactions ADD COLUMN pair_id INTEGER');
}

/// v8: regular payments and incomes (rent, subscriptions, stipend) with reminders.
Future<void> _migrateV8(Database db) async {
  await db.execute('''
    CREATE TABLE recurring(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      amount_minor INTEGER NOT NULL,
      currency TEXT NOT NULL,
      kind TEXT NOT NULL,
      category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
      account_id INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
      every TEXT NOT NULL,
      day INTEGER NOT NULL DEFAULT 1,
      next_ts INTEGER NOT NULL,
      remind INTEGER NOT NULL DEFAULT 1,
      archived INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL
    )''');
}
