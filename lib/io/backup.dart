import 'dart:convert';
import 'dart:io' show gzip;

import 'package:flutter/services.dart';

import '../data/database.dart';
import '../data/repository.dart';

/// Whole-database backup: JSON of all tables, gzipped; the native side encrypts it with the user's
/// password and writes it to a folder of a cloud app (OneDrive, Google Drive, Yandex Disk, Baidu…).
class BackupService {
  static const _channel = MethodChannel('budget/backup');
  final Repository repo;
  BackupService(this.repo);

  /// Device settings that must not travel to another phone.
  static const _localSettings = {'backup_uri', 'backup_folder', 'backup_last', 'backup_password'};

  Future<Uint8List> serialize() async {
    final data = await repo.dumpAll(backupTables);
    data['settings'] = data['settings']!.where((r) => !_localSettings.contains(r['key'])).toList();
    final json = jsonEncode({'app': 'budget', 'schema': schemaVersion, 'created': DateTime.now().toIso8601String(), 'data': data});
    return Uint8List.fromList(gzip.encode(utf8.encode(json)));
  }

  /// Restores from the decrypted payload; keeps this phone's backup settings.
  Future<void> restore(Uint8List payload) async {
    final json = jsonDecode(utf8.decode(gzip.decode(payload))) as Map<String, dynamic>;
    if (json['app'] != 'budget') throw const FormatException('not a backup of this app');
    final raw = json['data'] as Map<String, dynamic>;
    final keep = (await repo.dumpAll(['settings']))['settings']!
        .where((r) => _localSettings.contains(r['key']))
        .toList();
    final data = {
      for (final e in raw.entries)
        e.key: [for (final r in e.value as List) Map<String, Object?>.from(r as Map)],
    };
    data['settings'] = [...?data['settings']?.where((r) => !_localSettings.contains(r['key'])), ...keep];
    await repo.restoreAll(data, backupTables);
  }

  /// A new file every time ("create + write once" works with every cloud provider).
  static String fileName(DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    return 'budget-backup-${now.year}-${two(now.month)}-${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}.bkp';
  }

  /// (uri, folder name) or null if cancelled.
  Future<(String, String)?> pickFolder() async {
    final r = await _channel.invokeMapMethod<String, Object?>('pickFolder');
    if (r == null) return null;
    return (r['uri'] as String, r['name'] as String? ?? '');
  }

  /// Encrypted on the native side with the key derived from the backup password (if set).
  Future<void> writeToFolder(String uri, Uint8List payload) => _channel.invokeMethod('write', {
        'uri': uri,
        'name': fileName(DateTime.now()),
        'bytes': payload,
        'keep': 20,
      });

  /// True when the backup folder is in Google Drive and the phone is not on Wi-Fi: Drive keeps the
  /// file in its upload queue until Wi-Fi (its default "Transfer files only over Wi-Fi").
  Future<bool> waitsForWifi(String uri) async {
    final r = await _channel.invokeMapMethod<String, Object?>('connection', {'uri': uri});
    if (r == null) return false;
    final provider = r['provider'] as String? ?? '';
    return provider.startsWith('com.google.android.apps.docs') && r['wifi'] != true;
  }

  /// Encrypted backup as a file in the app cache (path), to share via the system share sheet.
  Future<String> packToCache(Uint8List payload) async =>
      (await _channel.invokeMethod<String>('packToCache', {'bytes': payload, 'name': fileName(DateTime.now())}))!;

  /// Keeps only a key derived from the password in the Android Keystore; null/empty = no encryption.
  Future<void> setPassword(String? password) => _channel.invokeMethod('setPassword', {'password': password});

  Future<bool> hasPassword() async => await _channel.invokeMethod<bool>('hasPassword') ?? false;

  Future<bool> checkPassword(String password) async =>
      await _channel.invokeMethod<bool>('checkPassword', {'password': password}) ?? false;

  Future<List<Map<String, Object?>>> listFolder(String uri) async =>
      ((await _channel.invokeListMethod<Object?>('list', {'uri': uri})) ?? const [])
          .map((e) => Map<String, Object?>.from(e as Map))
          .toList();

  Future<Uint8List> readFromFolder(String uri, String name) async =>
      (await _channel.invokeMethod<Uint8List>('readFromFolder', {'uri': uri, 'name': name}))!;

  /// Raw file bytes chosen by the user, or null if cancelled.
  Future<Uint8List?> pickFile() => _channel.invokeMethod<Uint8List>('pickFile');

  Future<bool> isEncrypted(Uint8List file) async => (await _channel.invokeMethod<bool>('isEncrypted', {'bytes': file}))!;

  /// Throws PlatformException on a wrong password or a damaged file.
  Future<Uint8List> unpack(Uint8List file, String? password) async =>
      (await _channel.invokeMethod<Uint8List>('unpack', {'bytes': file, 'password': password}))!;
}
