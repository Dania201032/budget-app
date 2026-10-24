import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import '../data/models.dart';
import '../data/repository.dart';

/// The shared budget ("бюджет на двоих"): several people keep one budget through one sync folder.
/// It is the sync of lib/sync/ with people added: each device belongs to a person, accounts may
/// belong to a person (or be common), and a person may hide their accounts from the others.
///
/// The answers given when it was set up are kept here (and travel to every device).
class HouseholdConfig {
  /// The others may not see accounts a person hid (else everything is visible to everyone).
  final bool hiddenAccounts;

  /// Besides the common monthly limit, each person has a limit of their own for their accounts.
  final bool personalLimits;

  /// What the second person uses (android | iphone | computer) and the cloud folder's service
  /// (gdrive | onedrive | yandex | jianguoyun | other): they choose the instructions shown.
  final String partnerDevice;
  final String cloud;

  const HouseholdConfig({
    this.hiddenAccounts = false,
    this.personalLimits = false,
    this.partnerDevice = 'android',
    this.cloud = 'gdrive',
  });

  Map<String, Object?> toJson() =>
      {'hidden': hiddenAccounts, 'personal': personalLimits, 'device': partnerDevice, 'cloud': cloud};

  factory HouseholdConfig.fromJson(Map<String, dynamic> j) => HouseholdConfig(
        hiddenAccounts: j['hidden'] as bool? ?? false,
        personalLimits: j['personal'] as bool? ?? false,
        partnerDevice: j['device'] as String? ?? 'android',
        cloud: j['cloud'] as String? ?? 'gdrive',
      );
}

/// Whose budget an operation counts in when people have their own limits.
enum BudgetScope { all, common, mine }

/// Person colors, in the order people join.
const personColors = [0xFF2E7D6B, 0xFFC0603A, 0xFF5B6CC4, 0xFFB08A1E];

extension HouseholdRepository on Repository {
  Future<HouseholdConfig?> household() async {
    final s = await setting('household');
    return s == null ? null : HouseholdConfig.fromJson(jsonDecode(s) as Map<String, dynamic>);
  }

  Future<void> setHousehold(HouseholdConfig? c) async {
    if (c == null) {
      await db.delete('settings', where: 'key = ?', whereArgs: ['household']);
    } else {
      await setSetting('household', jsonEncode(c.toJson()));
    }
  }

  Future<List<Person>> people() async => (await db.query('people', orderBy: 'created_at, id')).map(Person.fromRow).toList();

  /// Adds a person; returns their uid.
  Future<String> addPerson(String name, {String? uid}) async {
    final n = (await db.rawQuery('SELECT COUNT(*) AS n FROM people')).first['n'] as int;
    final id = await db.insert('people', {
      'name': name.trim(),
      'color': personColors[n % personColors.length],
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'uid': ?uid,
    });
    return (await db.query('people', columns: ['uid'], where: 'id = ?', whereArgs: [id])).first['uid'] as String;
  }

  Future<void> renamePerson(String uid, String name) =>
      db.update('people', {'name': name.trim()}, where: 'uid = ?', whereArgs: [uid]);

  /// [owner]: a person's uid, or null for a common account.
  Future<void> setAccountOwner(int accountId, String? owner) async {
    await db.update('accounts', {'owner': owner, if (owner == null) 'private': 0}, where: 'id = ?', whereArgs: [accountId]);
  }

  /// Hides an account (and everything recorded in it) from the other people, or shows it again.
  /// Hiding tells their devices to delete those rows; showing sends them again.
  Future<void> setAccountHidden(int accountId, bool hidden) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final op = hidden ? 'h' : 'u';
    await db.transaction((tx) async {
      await tx.update('accounts', {'private': hidden ? 1 : 0}, where: 'id = ? AND owner IS NOT NULL', whereArgs: [accountId]);
      final tracking = (await tx.query('sync_state', where: 'id = 1')).firstOrNull?['tracking'] == 1;
      if (!tracking) return;
      Future<void> enqueue(String table, String where) =>
          tx.execute("INSERT INTO sync_outbox(tbl, rid, op, ts) SELECT '$table', id, '$op', $now FROM $table WHERE $where", [accountId]);
      if (hidden) {
        await tx.execute("INSERT INTO sync_outbox(tbl, rid, op, ts) VALUES ('accounts', ?, 'h', $now)", [accountId]);
      }
      await enqueue('transactions', 'account_id = ?');
      await enqueue('goals', 'account_id = ?');
      await enqueue('recurring', 'account_id = ?');
      await enqueue('debts', 'txn_id IN (SELECT id FROM transactions WHERE account_id = ?)');
    });
  }

  /// A person's own monthly limit (amount, currency), or null.
  Future<(int, String)?> personalBudget(String person) async {
    final s = await setting('pbudget:$person');
    final parts = s?.split(':');
    if (parts == null || parts.length != 2) return null;
    final amount = int.tryParse(parts[0]);
    return amount == null ? null : (amount, parts[1]);
  }

  Future<void> setPersonalBudget(String person, int amountMinor, String currency) =>
      setSetting('pbudget:$person', '$amountMinor:$currency');

  /// A person's data joining a shared budget that already has data: their accounts become theirs
  /// (the built-in cash wallet gets an id of its own, else it would merge with the other
  /// person's), and what they recorded is marked as theirs.
  Future<void> claimAsMine(String person, String personName) async {
    await db.transaction((tx) async {
      final cash = await tx.query('accounts', where: "uid = 'acc:cash'");
      if (cash.isNotEmpty) {
        await tx.execute("UPDATE accounts SET uid = lower(hex(randomblob(16))), key = NULL, name = name || ' · ' || ? "
            "WHERE uid = 'acc:cash'", [personName]);
      }
      await tx.update('accounts', {'owner': person}, where: 'owner IS NULL');
      await tx.update('transactions', {'author': person}, where: 'author IS NULL');
    });
  }

  /// Categories of the same name and direction (mine and the shared budget's after joining)
  /// become one: the operations, rules and regular payments of the duplicate move over.
  Future<int> mergeSameNamedCategories() async {
    var merged = 0;
    // The shared budget's came last: they stay, mine go (deleting theirs would delete them everywhere).
    final rows = await db.query('categories', where: 'archived = 0', orderBy: 'id DESC');
    final seen = <String, int>{};
    for (final r in rows) {
      final key = '${(r['name'] as String).trim().toLowerCase()}\u0000${r['kind']}';
      final keep = seen[key];
      final id = r['id'] as int;
      if (keep == null) {
        seen[key] = id;
        continue;
      }
      await db.transaction((tx) async {
        await tx.update('transactions', {'category_id': keep}, where: 'category_id = ?', whereArgs: [id]);
        await tx.update('recurring', {'category_id': keep}, where: 'category_id = ?', whereArgs: [id]);
        await tx.update('merchant_rules', {'category_id': keep}, where: 'category_id = ?', whereArgs: [id],
            conflictAlgorithm: ConflictAlgorithm.ignore);
        await tx.delete('merchant_rules', where: 'category_id = ?', whereArgs: [id]);
        await tx.delete('categories', where: 'id = ?', whereArgs: [id]);
      });
      merged++;
    }
    return merged;
  }
}
