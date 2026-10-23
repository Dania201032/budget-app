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

  bool busy = false;
  String? lastError;
  DateTime? lastSync;

  bool get enabled => _folder != null && _cipher != null && _device != null;
  String? get folderLabel => _folder?.label;
  String? get device => _device;

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
    final last = int.tryParse(await repo.setting('sync_last') ?? '');
    lastSync = last == null ? null : DateTime.fromMillisecondsSinceEpoch(last);
  }

  static SyncFolder folderOf(String kind, String location, String label) =>
      kind == 'saf' ? SafSyncFolder(location, label) : IoSyncFolder(location);

  /// True when another device already syncs through [folder]: its password is asked once, not set twice.
  static Future<bool> hasGroup(SyncFolder folder) async => await folder.read(SyncEngine.metaName) != null;

  /// Joins (or starts) sync through [folder]. Throws [WrongSyncPassword].
  Future<SyncReport> connect(SyncFolder folder, String password, {required String kind, required String location}) async {
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
      final r = await SyncEngine(repo.db, folder, cipher, device).enable();
      lastSync = DateTime.now();
      lastError = null;
      return r;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    await SyncEngine.disable(repo.db);
    // A new device id next time: its file numbers start again, and the others must not skip them.
    for (final k in ['sync_kind', 'sync_folder', 'sync_label', 'sync_last', 'sync_seq', 'sync_device']) {
      await repo.db.delete('settings', where: 'key = ?', whereArgs: [k]);
    }
    await SecureStore.instance.write('sync_key', null);
    _folder = null;
    _cipher = null;
    _device = null;
    lastSync = null;
    lastError = null;
    notifyListeners();
  }

  /// Sends and takes changes; null when off or already running. Errors are kept in [lastError].
  Future<SyncReport?> sync() async {
    if (!enabled || busy) return null;
    busy = true;
    notifyListeners();
    try {
      final r = await SyncEngine(repo.db, _folder!, _cipher!, _device!).run();
      lastSync = DateTime.now();
      lastError = null;
      return r;
    } catch (e) {
      debugPrint('Sync failed: $e');
      lastError = '$e';
      return null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
