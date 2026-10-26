import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/repository.dart';
import '../security/secure_store.dart';
import 'sync_crypto.dart';
import 'sync_engine.dart';
import 'sync_folder.dart';

/// Whether this device takes part in sync, with which folder, and its last result.
/// The folder's location and this device's id are settings (not synchronized); the key made from
/// the sync password is kept in secure storage, the password itself nowhere.
class SyncService extends ChangeNotifier {
  final Repository repo;
  SyncService(this.repo);

  SyncFolder? _folder;
  SyncCipher? _cipher;
  String? _device;

  /// Shared budget: whose device this is, and that person's own key (for accounts hidden from
  /// the others), if they set a personal password.
  String? person;
  SyncCipher? personCipher;

  bool busy = false;
  String? lastError;

  /// What the sync running now is doing (null when idle).
  SyncProgress? progress;

  /// The last finished exchange: what came and went, what the cloud hasn't downloaded yet.
  SyncReport? lastReport;

  void _onProgress(SyncProgress p) {
    progress = p;
    notifyListeners();
  }

  /// When changes last actually went to or came from another device — not just a look at the folder.
  DateTime? lastSync;

  /// When the folder was last looked at (with or without changes).
  DateTime? lastCheck;

  /// When another device last left its changes in the folder (computer only: from the files' times).
  DateTime? otherDeviceSeen;

  bool get enabled => _folder != null && _cipher != null && _device != null;
  String? get folderLabel => _folder?.label;
  String? get device => _device;
  SyncFolder? get folder => _folder;
  SyncCipher? get cipher => _cipher;

  /// The folder on disk (the computer), to watch for new files; null on the phone.
  String? get folderPath {
    final f = _folder;
    return f is IoSyncFolder ? f.dir.path : null;
  }

  Future<void> load() async {
    final kind = await repo.setting('sync_kind');
    final location = await repo.setting('sync_folder');
    final key = await SecureStore.instance.read('sync_key');
    _device = await repo.setting('sync_device');
    if (kind != null && location != null && key != null && _device != null) {
      _folder = folderOf(kind, location, await repo.setting('sync_label') ?? location);
      _cipher = SyncCipher.fromKey(key);
    }
    person = await repo.setting('sync_person');
    final personKey = await SecureStore.instance.read('sync_person_key');
    personCipher = personKey == null ? null : SyncCipher.fromKey(personKey);
    await _readTimes();
  }

  /// The engine writes `sync_last` only when files were sent or taken, so it is the real time.
  Future<void> _readTimes() async {
    final last = int.tryParse(await repo.setting('sync_last') ?? '');
    lastSync = last == null ? null : DateTime.fromMillisecondsSinceEpoch(last);
    otherDeviceSeen = _otherDeviceSeen();
  }

  DateTime? _otherDeviceSeen() {
    final f = _folder;
    if (f is! IoSyncFolder || _device == null || !f.dir.existsSync()) return null;
    DateTime? latest;
    try {
      for (final e in f.dir.listSync()) {
        final name = e.uri.pathSegments.last;
        if (e is! File || !name.startsWith('bs-') || !name.endsWith('.bsync') || name.startsWith('bs-$_device-')) continue;
        final t = e.lastModifiedSync();
        if (latest == null || t.isAfter(latest)) latest = t;
      }
    } catch (_) {
      // A cloud folder that is still downloading: no time this round.
    }
    return latest;
  }

  /// This device belongs to [uid] (shared budget).
  Future<void> setPerson(String? uid) async {
    person = uid;
    if (uid == null) {
      await repo.db.delete('settings', where: 'key = ?', whereArgs: ['sync_person']);
    } else {
      await repo.setSetting('sync_person', uid);
    }
  }

  /// The person's own key from their personal password: created with the first of their devices,
  /// checked on the others (like the group's password). Throws [WrongSyncPassword].
  static Future<SyncCipher> openPersonKey(SyncFolder folder, String person, String password) =>
      SyncEngine.openGroup(folder, password, metaName: 'budget-person-$person.json');

  /// Whether [person] already set a personal password (then their other devices must enter it).
  static Future<bool> hasPersonKey(SyncFolder folder, String person) async =>
      await folder.read('budget-person-$person.json') != null;

  Future<void> setPersonCipher(SyncCipher? c) async {
    personCipher = c;
    await SecureStore.instance.write('sync_person_key', c == null ? null : await c.exportKey());
  }

  static SyncFolder folderOf(String kind, String location, String label) =>
      kind == 'saf' ? SafSyncFolder(location, label) : IoSyncFolder(location);

  /// True when another device already syncs through [folder]: its password is asked once, not set twice.
  static Future<bool> hasGroup(SyncFolder folder) async => await folder.read(SyncEngine.metaName) != null;

  /// Joins (or starts) sync through [folder]. Throws [WrongSyncPassword]. [wipe] and [beforeSend]:
  /// see [SyncEngine.enable] (a person joining a shared budget).
  Future<SyncReport> connect(SyncFolder folder, String password,
      {required String kind,
      required String location,
      bool wipe = false,
      Future<void> Function()? beforeTake,
      Future<void> Function()? beforeSend}) async {
    final cipher = await SyncEngine.openGroup(folder, password);
    final device = await repo.setting('sync_device') ?? SyncEngine.newDeviceId();
    await repo.setSetting('sync_device', device);
    await repo.setSetting('sync_kind', kind);
    await repo.setSetting('sync_folder', location);
    await repo.setSetting('sync_label', folder.label);
    await SecureStore.instance.write('sync_key', await cipher.exportKey());
    _folder = folder;
    _cipher = cipher;
    _device = device;
    busy = true;
    notifyListeners();
    try {
      final r = await SyncEngine(repo.db, folder, cipher, device, person: person, personCipher: personCipher, onProgress: _onProgress)
          .enable(wipe: wipe, beforeTake: beforeTake, beforeSend: beforeSend);
      lastCheck = DateTime.now();
      await _readTimes();
      lastError = null;
      lastReport = r;
      return r;
    } finally {
      busy = false;
      progress = null;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    await SyncEngine.disable(repo.db);
    // A new device id next time: its file numbers start again, and the others must not skip them.
    for (final k in ['sync_kind', 'sync_folder', 'sync_label', 'sync_last', 'sync_seq', 'sync_device', 'sync_person']) {
      await repo.db.delete('settings', where: 'key = ?', whereArgs: [k]);
    }
    await SecureStore.instance.write('sync_key', null);
    await SecureStore.instance.write('sync_person_key', null);
    person = null;
    personCipher = null;
    _folder = null;
    _cipher = null;
    _device = null;
    lastSync = null;
    lastCheck = null;
    otherDeviceSeen = null;
    lastError = null;
    lastReport = null;
    notifyListeners();
  }

  /// Sends and takes changes; null when off or already running. Errors are kept in [lastError].
  Future<SyncReport?> sync() async {
    if (!enabled || busy) return null;
    busy = true;
    notifyListeners();
    try {
      final r = await SyncEngine(repo.db, _folder!, _cipher!, _device!, person: person, personCipher: personCipher, onProgress: _onProgress).run();
      lastCheck = DateTime.now();
      await _readTimes();
      lastError = null;
      // A look that found nothing new keeps the last real exchange's numbers; files still
      // downloading are always the current count.
      lastReport = r.received > 0 || r.sent > 0 || lastReport == null
          ? r
          : SyncReport(lastReport!.received, lastReport!.sent, pending: r.pending, alone: lastReport!.alone);
      return r;
    } catch (e) {
      debugPrint('Sync failed: $e');
      lastCheck = DateTime.now();
      lastError = '$e';
      return null;
    } finally {
      busy = false;
      progress = null;
      notifyListeners();
    }
  }
}
