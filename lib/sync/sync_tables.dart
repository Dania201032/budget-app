import 'package:sqflite_common/sqlite_api.dart';

/// What is synchronized between the phone and the computer, and how a row is identified there.
///
/// Rows with a local integer id get a `uid` (random, or fixed for built-ins: "cat:food",
/// "acc:cash") that is the same on every device; references between rows travel as uids.
/// Tables with a natural key (a month, a merchant + kind…) are identified by it.
class SyncTable {
  final String name;

  /// Natural key columns; empty = identified by `uid`.
  final List<String> keyCols;

  /// Column -> table it refers to (by local id).
  final Map<String, String> refs;

  /// Only these rows are synchronized (settings: not the language, the backup folder…).
  final String? rowFilter;

  const SyncTable(this.name, {this.keyCols = const [], this.refs = const {}, this.rowFilter});

  bool get byUid => keyCols.isEmpty;
}

/// Settings that are the same on all devices; the rest (language, backup folder, capture…) are per device.
/// "household" is the shared budget's setup; `pbudget:<person>` a person's own monthly limit;
/// "desk_holdings" the investments, property and loans; "networth_history" the net worth by month;
/// "envelopes" the envelope budgeting; "tax_tags" the tax marks of categories.
const syncedSettings = [
  'base_currency', 'budget_enabled', 'default_budget_minor', 'default_budget_currency', 'daily_limit',
  'self_names', 'runway_config', 'country', 'household', 'desk_holdings', 'networth_history', 'envelopes', 'tax_tags',
];

const _settingsFilter = "(key IN ('base_currency', 'budget_enabled', 'default_budget_minor', 'default_budget_currency', "
    "'daily_limit', 'self_names', 'runway_config', 'country', 'household', 'desk_holdings', 'networth_history', "
    "'envelopes', 'tax_tags') OR key LIKE 'pbudget:%')";

/// In dependency order: parents before the rows that refer to them.
const syncTables = [
  SyncTable('people'),
  SyncTable('categories'),
  SyncTable('accounts'),
  SyncTable('goals', refs: {'account_id': 'accounts'}),
  SyncTable('transactions',
      refs: {'category_id': 'categories', 'account_id': 'accounts', 'pair_id': 'transactions', 'goal_id': 'goals'}),
  SyncTable('debts', refs: {'txn_id': 'transactions'}),
  SyncTable('recurring', refs: {'category_id': 'categories', 'account_id': 'accounts'}),
  SyncTable('budgets', keyCols: ['month']),
  SyncTable('merchant_rules', keyCols: ['merchant', 'kind'], refs: {'category_id': 'categories'}),
  SyncTable('manual_rates', keyCols: ['base', 'quote']),
  SyncTable('settings', keyCols: ['key'], rowFilter: _settingsFilter),
];

SyncTable syncTable(String name) => syncTables.firstWhere((t) => t.name == name);

/// Separator of natural key parts ("merchant␟kind").
const keySep = '\u001f';

const _now = "CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)";

String _keyExpr(SyncTable t, String row) => t.keyCols.map((c) => '$row.$c').join(" || char(31) || ");

String _filter(SyncTable t, String row) {
  final f = t.rowFilter;
  if (f == null) return '';
  return ' AND ${f.replaceAll(RegExp(r'\bkey\b'), '$row.key')}';
}

/// v9: uids, the change log the triggers fill while sync is on, and what is known of other devices.
Future<void> migrateSyncV9(Database db) async {
  // (Hand-made old databases in tests may lack some tables.)
  final existing = {
    for (final r in await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'")) r['name'] as String,
  };
  final tables = [for (final t in syncTables) if (existing.contains(t.name)) t];
  for (final t in tables.where((t) => t.byUid)) {
    await db.execute('ALTER TABLE ${t.name} ADD COLUMN uid TEXT');
  }
  // Built-ins get the same uid on every device, so a fresh install merges with the phone's.
  final cols = {
    for (final t in ['categories', 'accounts'])
      if (existing.contains(t)) t: {for (final c in await db.rawQuery('PRAGMA table_info($t)')) c['name'] as String},
  };
  if (cols['categories']?.contains('key') ?? false) {
    await db.execute("UPDATE categories SET uid = 'cat:' || key WHERE key IS NOT NULL");
  }
  if (cols['accounts']?.contains('key') ?? false) {
    await db.execute("UPDATE accounts SET uid = 'acc:' || key WHERE key IS NOT NULL");
  }
  for (final t in tables.where((t) => t.byUid)) {
    await db.execute('UPDATE ${t.name} SET uid = lower(hex(randomblob(16))) WHERE uid IS NULL');
    await db.execute('CREATE UNIQUE INDEX idx_${t.name}_uid ON ${t.name}(uid)');
  }

  // tracking = 1 while sync is on and not applying another device's changes.
  await db.execute('CREATE TABLE sync_state(id INTEGER PRIMARY KEY CHECK (id = 1), tracking INTEGER NOT NULL DEFAULT 0)');
  await db.insert('sync_state', {'id': 1, 'tracking': 0});
  await db.execute('''
    CREATE TABLE sync_outbox(
      seq INTEGER PRIMARY KEY AUTOINCREMENT,
      tbl TEXT NOT NULL,
      rid INTEGER,
      rkey TEXT,
      op TEXT NOT NULL,
      ts INTEGER NOT NULL
    )''');
  // The last change known for each row (mine or another device's): newer wins.
  await db.execute('''
    CREATE TABLE sync_rows(
      tbl TEXT NOT NULL,
      rkey TEXT NOT NULL,
      ts INTEGER NOT NULL,
      device TEXT NOT NULL,
      deleted INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(tbl, rkey)
    )''');
  // The last file read from each other device.
  await db.execute('CREATE TABLE sync_peers(device TEXT PRIMARY KEY, seq INTEGER NOT NULL)');

  for (final t in tables) {
    await createSyncTriggers(db, t);
  }
}

Future<void> createSyncTriggers(Database db, SyncTable t) async {
  const tracking = '(SELECT tracking FROM sync_state WHERE id = 1) = 1';
  final n = t.name;
  if (t.byUid) {
    // Every new row gets its uid, whether sync is on or not.
    await db.execute('''
      CREATE TRIGGER sync_${n}_uid AFTER INSERT ON $n WHEN NEW.uid IS NULL BEGIN
        UPDATE $n SET uid = lower(hex(randomblob(16))) WHERE id = NEW.id;
      END''');
    for (final (event, row) in [('INSERT', 'NEW'), ('UPDATE', 'NEW')]) {
      await db.execute('''
        CREATE TRIGGER sync_${n}_${event.toLowerCase()} AFTER $event ON $n WHEN $tracking BEGIN
          INSERT INTO sync_outbox(tbl, rid, op, ts) VALUES ('$n', $row.id, 'u', $_now);
        END''');
    }
    await db.execute('''
      CREATE TRIGGER sync_${n}_delete AFTER DELETE ON $n WHEN $tracking AND OLD.uid IS NOT NULL BEGIN
        INSERT INTO sync_outbox(tbl, rkey, op, ts) VALUES ('$n', OLD.uid, 'd', $_now);
      END''');
  } else {
    for (final (event, row, op) in [('INSERT', 'NEW', 'u'), ('UPDATE', 'NEW', 'u'), ('DELETE', 'OLD', 'd')]) {
      await db.execute('''
        CREATE TRIGGER sync_${n}_${event.toLowerCase()} AFTER $event ON $n WHEN $tracking${_filter(t, row)} BEGIN
          INSERT INTO sync_outbox(tbl, rkey, op, ts) VALUES ('$n', ${_keyExpr(t, row)}, '$op', $_now);
        END''');
    }
  }
}

/// v10: the shared budget for two (or more). People, who owns an account (null: common) and
/// whether the others may see it, who recorded an operation.
Future<void> migrateHouseholdV10(Database db) async {
  final existing = {
    for (final r in await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'")) r['name'] as String,
  };
  await db.execute('''
    CREATE TABLE people(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      uid TEXT,
      name TEXT NOT NULL,
      color INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL
    )''');
  await db.execute('CREATE UNIQUE INDEX idx_people_uid ON people(uid)');
  if (existing.contains('accounts')) {
    await db.execute('ALTER TABLE accounts ADD COLUMN owner TEXT');
    await db.execute('ALTER TABLE accounts ADD COLUMN private INTEGER NOT NULL DEFAULT 0');
  }
  if (existing.contains('transactions')) await db.execute('ALTER TABLE transactions ADD COLUMN author TEXT');
  if (existing.contains('sync_state')) {
    await createSyncTriggers(db, syncTable('people'));
    // The settings that travel now include the shared budget's.
    if (existing.contains('settings')) await recreateSettingsTriggers(db);
  }
}

/// The synced settings' triggers again, after [syncedSettings] grew.
Future<void> recreateSettingsTriggers(Database db) async {
  for (final e in ['insert', 'update', 'delete']) {
    await db.execute('DROP TRIGGER IF EXISTS sync_settings_$e');
  }
  await createSyncTriggers(db, syncTable('settings'));
}
