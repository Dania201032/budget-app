import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// The shared folder the devices exchange their change files through: a Google Drive folder
/// (on the computer, the folder of Google Drive for desktop; on the phone, picked through Android's
/// folder picker). Only flat files, so any cloud works.
abstract class SyncFolder {
  /// Shown to the user ("G:\My Drive\Budget").
  String get label;
  Future<List<String>> list();
  Future<Uint8List?> read(String name);
  Future<void> write(String name, Uint8List bytes);
  Future<void> delete(String name);
}

/// A folder on disk: the computer, and tests.
class IoSyncFolder implements SyncFolder {
  final Directory dir;
  IoSyncFolder(String path) : dir = Directory(path);

  @override
  String get label => dir.path;

  @override
  Future<List<String>> list() async {
    if (!dir.existsSync()) return const [];
    return [for (final e in dir.listSync()) if (e is File) p.basename(e.path)];
  }

  @override
  Future<Uint8List?> read(String name) async {
    final f = File(p.join(dir.path, name));
    return f.existsSync() ? f.readAsBytes() : null;
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    dir.createSync(recursive: true);
    // Written aside and renamed, so the cloud client never uploads half a file.
    final tmp = File(p.join(dir.path, '.$name.part'));
    await tmp.writeAsBytes(bytes, flush: true);
    final target = File(p.join(dir.path, name));
    if (target.existsSync()) target.deleteSync();
    tmp.renameSync(target.path);
  }

  @override
  Future<void> delete(String name) async {
    final f = File(p.join(dir.path, name));
    if (f.existsSync()) f.deleteSync();
  }
}

/// A folder picked with Android's folder picker (Google Drive's provider), through the native side.
class SafSyncFolder implements SyncFolder {
  static const _channel = MethodChannel('budget/sync');
  final String uri;
  @override
  final String label;
  SafSyncFolder(this.uri, this.label);

  /// Opens the folder picker; null when cancelled. Returns (uri, shown name).
  static Future<(String, String)?> pick() async {
    final r = await _channel.invokeMapMethod<String, String>('pickFolder');
    if (r == null) return null;
    return (r['uri']!, r['name'] ?? '');
  }

  @override
  Future<List<String>> list() async => (await _channel.invokeListMethod<String>('list', {'uri': uri})) ?? const [];

  @override
  Future<Uint8List?> read(String name) => _channel.invokeMethod<Uint8List>('read', {'uri': uri, 'name': name});

  @override
  Future<void> write(String name, Uint8List bytes) =>
      _channel.invokeMethod('write', {'uri': uri, 'name': name, 'bytes': bytes});

  @override
  Future<void> delete(String name) => _channel.invokeMethod('delete', {'uri': uri, 'name': name});
}
