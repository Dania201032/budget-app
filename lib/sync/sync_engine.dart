import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:sqflite_common/sqlite_api.dart';

import 'sync_crypto.dart';
import 'sync_folder.dart';
import 'sync_tables.dart';

/// The sync password doesn't open this folder's files.
class WrongSyncPassword implements Exception {}

class SyncReport {
  /// Changes taken from other devices / sent to them.
  final int received;
  final int sent;

  /// Other devices' files the cloud app hasn't downloaded yet (taken on a later look).
  final int pending;

  /// No other device has left anything in the folder yet: this is the first one.
  final bool alone;
  const SyncReport(this.received, this.sent, {this.pending = 0, this.alone = false});
}

/// What a sync is doing right now, for the screens: a slow first sync must not look stuck.
enum SyncStage { prepare, send, receive }

class SyncProgress {
  final SyncStage stage;

  /// Rows looked at (prepare) or files written (send) / read (receive), of [total].
  final int done;
  final int total;

  /// Changes taken in so far (receive).
  final int changes;
  const SyncProgress(this.stage, this.done, this.total, {this.changes = 0});
}

/// Phone ⇄ computer sync without a server, through a shared cloud folder.
///
/// Each device appends its own numbered change files (`bs-<device>-<seq>.bsync`, encrypted) and
/// reads the other devices' new ones. A change carries the whole row and the time it was made; for
/// the same row the later change wins (ties: by device id), so every device ends up with the same
/// data whatever the order the files arrive in. Deleted rows travel as deletions.
///
/// Shared budget: several people's devices use one folder. Rows of an account its owner hid from
/// the others travel sealed a second time with that person's own key ([personCipher]), so only
/// their devices can read them; a person's device without the key keeps them to itself. Hiding
/// an account sends "hide" records: the other people's devices delete those rows.
class SyncEngine {
  static const metaName = 'budget-sync.json';
  static final _fileRe = RegExp(r'^bs-([0-9a-f]{8})-(\d{8})\.bsync$');

  /// Changes per file: keeps files small for the cloud and for memory.
  static const chunk = 2000;

  final Database db;
  final SyncFolder folder;
  final SyncCipher cipher;
  final String device;

  /// This device's person (shared budget) and that person's own key, if set up.
  final String? person;
  final SyncCipher? personCipher;

  /// Told as the work goes (rows prepared, files written and read).
  final void Function(SyncProgress)? onProgress;

  SyncEngine(this.db, this.folder, this.cipher, this.device, {this.person, this.personCipher, this.onProgress});

  static String newDeviceId() {
    final r = Random.secure();
    return List.generate(4, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  static String fileName(String device, int seq) => 'bs-$device-${seq.toString().padLeft(8, '0')}.bsync';

  // --- The sync group: the folder's salt and a check value for the password ---

  /// Opens the folder's sync group with [password], creating it on the first device.
  static Future<SyncCipher> openGroup(SyncFolder folder, String password, {String metaName = metaName}) async {
    final raw = await folder.read(metaName);
    if (raw == null) {
      final salt = SyncCipher.newSalt();
      final cipher = await SyncCipher.fromPassword(password, salt);
      final check = await cipher.seal(utf8.encode('budget-sync'));
      await folder.write(
        metaName,
        Uint8List.fromList(utf8.encode(jsonEncode({'v': 1, 'salt': base64Encode(salt), 'check': base64Encode(check)}))),
      );
      return cipher;
    }
    final meta = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    final cipher = await SyncCipher.fromPassword(password, base64Decode(meta['salt'] as String));
    final check = await cipher.open(base64Decode(meta['check'] as String));
    if (check == null || utf8.decode(check) != 'budget-sync') throw WrongSyncPassword();
    return cipher;
  }

  /// Turns sync on for this device. A device without operations of its own (a fresh computer)
  /// takes the other devices' data as it is; otherwise everything it has is sent and merged.
  ///
  /// Shared budget: [wipe] drops this device's data for the budget's. [beforeSend] marks a person
  /// with data of their own who joins: [beforeTake] runs (making their accounts theirs before the
  /// budget's built-in ones could merge with them), the budget's data is taken in, [beforeSend]
  /// runs (merging categories), then all of theirs is sent — except the settings, which stay the
  /// budget's.
  Future<SyncReport> enable({bool wipe = false, Future<void> Function()? beforeTake, Future<void> Function()? beforeSend}) async {
    final others = (await folder.list()).map(_fileRe.firstMatch).whereType<RegExpMatch>().where((m) => m[1] != device);
    final hasOwn = (await db.rawQuery('SELECT COUNT(*) AS n FROM transactions')).first['n'] as int > 0;
    final takeTheirs = others.isNotEmpty && (wipe || !hasOwn);
    final joining = others.isNotEmpty && hasOwn && !wipe && beforeSend != null;
    await db.transaction((txn) async {
      await txn.update('sync_state', {'tracking': 0});
      await txn.delete('sync_outbox');
      await txn.delete('sync_rows');
      await txn.delete('sync_peers');
      if (takeTheirs) {
        for (final t in syncTables.reversed) {
          await txn.delete(t.name, where: t.rowFilter);
        }
      }
    });
    var taken = 0;
    if (joining) {
      await beforeTake?.call();
      taken = (await _import()).$1;
      await beforeSend();
    }
    await db.transaction((txn) async {
      await txn.update('sync_state', {'tracking': 0});
      if (!takeTheirs) {
        final now = DateTime.now().millisecondsSinceEpoch;
        for (final t in syncTables) {
          if (joining && t.name == 'settings') continue;
          final key = t.byUid ? 'uid' : t.keyCols.join(' || char(31) || ');
          // Joining: only what is mine goes out, not the budget's rows just taken in.
          final conditions = [
            ?t.rowFilter,
            if (joining) "($key) NOT IN (SELECT rkey FROM sync_rows WHERE tbl = '${t.name}')",
          ];
          final where = conditions.isEmpty ? '' : ' WHERE ${conditions.join(' AND ')}';
          if (t.byUid) {
            await txn.execute("INSERT INTO sync_outbox(tbl, rid, op, ts) SELECT '${t.name}', id, 'u', $now FROM ${t.name}$where");
          } else {
            await txn.execute("INSERT INTO sync_outbox(tbl, rkey, op, ts) SELECT '${t.name}', $key, 'u', $now FROM ${t.name}$where");
          }
        }
      }
      await txn.update('sync_state', {'tracking': 1});
    });
    final r = await run();
    return SyncReport(r.received + taken, r.sent, pending: r.pending, alone: others.isEmpty);
  }

  /// What a shared budget's folder holds, read without changing anything here: its people
  /// (uid -> name) and its setup (the "household" setting), for the questions before joining.
  static Future<(Map<String, String>, String?)> peek(SyncFolder folder, SyncCipher cipher) async {
    final people = <String, (int, String?)>{};
    (int, String?)? household;
    for (final name in await folder.list()) {
      if (!_fileRe.hasMatch(name)) continue;
      final data = await folder.read(name);
      final plain = data == null ? null : await cipher.open(data);
      if (plain == null) continue;
      final body = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      for (final r in (body['records'] as List).cast<Map<String, dynamic>>()) {
        final ts = r['ts'] as int;
        final row = r['r'] as Map<String, dynamic>?;
        if (r['t'] == 'people') {
          final k = r['k'] as String;
          if ((people[k]?.$1 ?? -1) < ts) people[k] = (ts, r['o'] == 'd' ? null : row?['name'] as String?);
        } else if (r['t'] == 'settings' && r['k'] == 'household' && (household?.$1 ?? -1) < ts) {
          household = (ts, r['o'] == 'd' ? null : row?['value'] as String?);
        }
      }
    }
    return (
      {for (final e in people.entries) if (e.value.$2 != null) e.key: e.value.$2!},
      household?.$2,
    );
  }

  /// Stops recording changes for sync (the folder's files stay).
  static Future<void> disable(Database db) async {
    await db.update('sync_state', {'tracking': 0});
    await db.delete('sync_outbox');
  }

  /// Sends this device's changes, then takes the other devices' new ones. Sending first records
  /// the time of my own unsent edits, so an older edit of the same row from elsewhere can't
  /// overwrite them.
  Future<SyncReport> run() async {
    final sent = await _export();
    final (received, pending) = await _import();
    return SyncReport(received, sent, pending: pending);
  }

  // --- Sending ---

  Future<int> _export() async {
    final out = await db.query('sync_outbox', orderBy: 'seq');
    if (out.isEmpty) return 0;
    final maxSeq = out.last['seq'] as int;

    // The last change of each row; a row changed ten times travels once, as it is now.
    final latest = <String, Map<String, Object?>>{};
    final hidden = await _hiddenAccounts();
    var looked = 0;
    for (final o in out) {
      if (++looked % 250 == 0) onProgress?.call(SyncProgress(SyncStage.prepare, looked, out.length));
      final t = syncTable(o['tbl'] as String);
      var key = o['rkey'] as String?;
      Map<String, Object?>? row;
      if (o['op'] == 'h') {
        // Hidden from the other people: they delete it; my own devices keep it.
        final rows = await db.query(t.name, columns: ['uid'], where: 'id = ?', whereArgs: [o['rid']]);
        final uid = rows.firstOrNull?['uid'] as String?;
        if (uid == null || person == null) continue;
        latest['${t.name}\u0000$uid\u0000h'] = {'t': t.name, 'k': uid, 'o': 'h', 'ts': o['ts'], 'p': person};
        continue;
      }
      if (o['op'] == 'u') {
        final rows = t.byUid
            ? await db.query(t.name, where: 'id = ?', whereArgs: [o['rid']])
            : await db.query(t.name, where: t.keyCols.map((c) => '$c = ?').join(' AND '), whereArgs: key!.split(keySep));
        if (rows.isEmpty) continue; // deleted since: its deletion follows
        row = rows.first;
        if (t.byUid) key = row['uid'] as String?;
        if (key == null) continue;
      }
      final owner = row == null ? null : await _hiddenOwner(t, row, hidden);
      if (owner != null) {
        // Only this person's devices may read it; without their key it stays here.
        if (owner != person || personCipher == null) continue;
        final sealed = await personCipher!.seal(utf8.encode(jsonEncode(await _encode(t, row!))));
        latest['${t.name}\u0000$key'] = {'t': t.name, 'k': key, 'o': 'u', 'ts': o['ts'], 'p': owner, 'x': base64Encode(sealed)};
        continue;
      }
      latest['${t.name}\u0000$key'] = {
        't': t.name,
        'k': key,
        'o': o['op'],
        'ts': o['ts'],
        if (row != null) 'r': await _encode(t, row),
      };
    }

    final records = latest.values.toList();
    var seq = int.tryParse(await _setting('sync_seq') ?? '') ?? 0;
    final files = (records.length + chunk - 1) ~/ chunk;
    onProgress?.call(SyncProgress(SyncStage.send, 0, files));
    for (var i = 0; i < records.length; i += chunk) {
      final part = records.sublist(i, min(i + chunk, records.length));
      seq++;
      final body = jsonEncode({'v': 1, 'device': device, 'seq': seq, 'records': part});
      await folder.write(fileName(device, seq), await cipher.seal(utf8.encode(body)));
      await _setSetting('sync_seq', '$seq');
      onProgress?.call(SyncProgress(SyncStage.send, i ~/ chunk + 1, files));
    }
    await db.transaction((txn) async {
      for (final r in records) {
        await _known(txn, r['t'] as String, r['k'] as String, r['ts'] as int, device, r['o'] == 'd');
      }
      await txn.delete('sync_outbox', where: 'seq <= ?', whereArgs: [maxSeq]);
    });
    await _setSetting('sync_last', '${DateTime.now().millisecondsSinceEpoch}');
    return records.length;
  }

  /// Hidden accounts here: local id -> owner.
  Future<Map<int, String>> _hiddenAccounts() async {
    final cols = await _columns(db, 'accounts');
    if (!cols.contains('private')) return const {};
    return {
      for (final r in await db.query('accounts', columns: ['id', 'owner'], where: 'private = 1 AND owner IS NOT NULL'))
        r['id'] as int: r['owner'] as String,
    };
  }

  /// The owner of the hidden account [row] belongs to, or null when everyone may see it.
  Future<String?> _hiddenOwner(SyncTable t, Map<String, Object?> row, Map<int, String> hidden) async {
    if (hidden.isEmpty) return null;
    switch (t.name) {
      case 'accounts':
        return hidden[row['id']];
      case 'transactions' || 'goals' || 'recurring':
        return hidden[row['account_id']];
      case 'debts':
        final txn = await db.query('transactions', columns: ['account_id'], where: 'id = ?', whereArgs: [row['txn_id']]);
        return hidden[txn.firstOrNull?['account_id']];
    }
    return null;
  }

  /// A row as it travels: no local id, references as uids.
  Future<Map<String, Object?>> _encode(SyncTable t, Map<String, Object?> row) async {
    final out = Map<String, Object?>.of(row)..remove('id');
    for (final e in t.refs.entries) {
      final id = row[e.key];
      out[e.key] = id == null ? null : await _uidOf(db, e.value, id as int);
    }
    return out;
  }

  // --- Receiving ---

  /// (changes taken, files not downloaded yet).
  Future<(int, int)> _import() async {
    final peers = {
      for (final r in await db.query('sync_peers')) r['device'] as String: r['seq'] as int,
    };
    final files = <(String, int, String)>[];
    for (final name in await folder.list()) {
      final m = _fileRe.firstMatch(name);
      if (m == null || m[1] == device) continue;
      final seq = int.parse(m[2]!);
      if (seq > (peers[m[1]] ?? 0)) files.add((m[1]!, seq, name));
    }
    files.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));

    var applied = 0, read = 0;
    if (files.isNotEmpty) onProgress?.call(SyncProgress(SyncStage.receive, 0, files.length));
    for (final (dev, seq, name) in files) {
      final data = await folder.read(name);
      if (data == null) break; // not downloaded yet: next time, in order
      read++;
      final plain = await cipher.open(data);
      if (plain != null) {
        final body = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
        final records = (body['records'] as List).cast<Map<String, dynamic>>();
        applied += await _apply(records, dev);
      }
      // A damaged file is skipped for good rather than blocking the ones after it.
      await db.insert('sync_peers', {'device': dev, 'seq': seq}, conflictAlgorithm: ConflictAlgorithm.replace);
      onProgress?.call(SyncProgress(SyncStage.receive, read, files.length, changes: applied));
    }
    if (read > 0) await _setSetting('sync_last', '${DateTime.now().millisecondsSinceEpoch}');
    return (applied, files.length - read);
  }

  Future<int> _apply(List<Map<String, dynamic>> records, String dev) async {
    final order = {for (var i = 0; i < syncTables.length; i++) syncTables[i].name: i};
    records.sort((a, b) {
      final byTable = order[a['t']]!.compareTo(order[b['t']]!);
      return byTable != 0 ? byTable : (a['ts'] as int).compareTo(b['ts'] as int);
    });
    var applied = 0;
    await db.transaction((txn) async {
      await txn.update('sync_state', {'tracking': 0});
      // References to rows that come later in the same batch (the other half of a transfer pair).
      final later = <(String, String, String, String, String)>[];
      for (final r in records) {
        final tableName = r['t'] as String;
        if (!order.containsKey(tableName)) continue;
        final t = syncTable(tableName);
        final key = r['k'] as String;
        final ts = r['ts'] as int;
        // Another person's hidden rows can't be read here; my own "hide" doesn't apply to my devices.
        final owner = r['p'] as String?;
        if (owner != null && r['o'] == 'h' && owner == person) continue;
        if (owner != null && r['o'] != 'h') {
          if (owner != person || personCipher == null) continue;
          final plain = await personCipher!.open(base64Decode(r['x'] as String));
          if (plain == null) continue;
          r['r'] = jsonDecode(utf8.decode(plain));
        }
        final known = await txn.query('sync_rows', where: 'tbl = ? AND rkey = ?', whereArgs: [t.name, key]);
        if (known.isNotEmpty) {
          final kts = known.first['ts'] as int;
          final kdev = known.first['device'] as String;
          // Mine (or one already taken) is newer.
          if (kts > ts || (kts == ts && kdev.compareTo(dev) >= 0)) continue;
        }
        final deleted = r['o'] == 'd' || r['o'] == 'h';
        if (deleted) {
          if (t.byUid) {
            await txn.delete(t.name, where: 'uid = ?', whereArgs: [key]);
          } else {
            await txn.delete(t.name, where: t.keyCols.map((c) => '$c = ?').join(' AND '), whereArgs: key.split(keySep));
          }
        } else if (!await _upsert(txn, t, key, Map<String, Object?>.of(r['r'] as Map<String, dynamic>), later)) {
          continue;
        }
        await _known(txn, t.name, key, ts, dev, deleted);
        applied++;
      }
      for (final (tbl, uid, col, refTable, refUid) in later) {
        final id = await _idOf(txn, refTable, refUid);
        if (id != null) await txn.update(tbl, {col: id}, where: 'uid = ?', whereArgs: [uid]);
      }
      await txn.update('sync_state', {'tracking': 1});
    });
    return applied;
  }

  Future<bool> _upsert(
    DatabaseExecutor txn,
    SyncTable t,
    String key,
    Map<String, Object?> row,
    List<(String, String, String, String, String)> later,
  ) async {
    final cols = await _columns(txn, t.name);
    final values = <String, Object?>{
      for (final e in row.entries)
        if (cols.contains(e.key) && e.key != 'id') e.key: e.value,
    };
    for (final e in t.refs.entries) {
      final refUid = row[e.key] as String?;
      if (refUid == null) continue;
      final id = await _idOf(txn, e.value, refUid);
      values[e.key] = id;
      if (id == null && t.byUid) later.add((t.name, key, e.key, e.value, refUid));
    }
    if (t.byUid) {
      values['uid'] = key;
      final existing = await _idOf(txn, t.name, key);
      if (existing != null) {
        await txn.update(t.name, values, where: 'id = ?', whereArgs: [existing]);
      } else {
        await txn.insert(t.name, values);
      }
    } else {
      // A rule for a category this device doesn't have can't be kept.
      if (values.entries.any((e) => t.refs.containsKey(e.key) && e.value == null)) return false;
      await txn.insert(t.name, values, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    return true;
  }

  // --- Helpers ---

  final _columnCache = <String, Set<String>>{};

  Future<Set<String>> _columns(DatabaseExecutor ex, String table) async =>
      _columnCache[table] ??= {for (final c in await ex.rawQuery('PRAGMA table_info($table)')) c['name'] as String};

  static Future<String?> _uidOf(DatabaseExecutor ex, String table, int id) async {
    final r = await ex.query(table, columns: ['uid'], where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : r.first['uid'] as String?;
  }

  static Future<int?> _idOf(DatabaseExecutor ex, String table, String uid) async {
    final r = await ex.query(table, columns: ['id'], where: 'uid = ?', whereArgs: [uid]);
    return r.isEmpty ? null : r.first['id'] as int;
  }

  static Future<void> _known(DatabaseExecutor ex, String tbl, String key, int ts, String dev, bool deleted) =>
      ex.insert('sync_rows', {'tbl': tbl, 'rkey': key, 'ts': ts, 'device': dev, 'deleted': deleted ? 1 : 0},
          conflictAlgorithm: ConflictAlgorithm.replace);

  Future<String?> _setting(String key) async {
    final r = await db.query('settings', where: 'key = ?', whereArgs: [key]);
    return r.isEmpty ? null : r.first['value'] as String;
  }

  Future<void> _setSetting(String key, String value) =>
      db.insert('settings', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
}
