import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Photos of receipts, kept in the app's own folder on this device (not in the synced data: the
/// other devices see that an operation has a receipt, the picture stays here).
Future<Directory> _dir() async {
  final d = Directory('${(await getApplicationDocumentsDirectory()).path}/receipts');
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

/// Copies the picture at [path] into the receipts folder; returns its file name.
Future<String> keepReceipt(String path) async {
  final ext = path.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
  final name = 'r${DateTime.now().millisecondsSinceEpoch}.$ext';
  await File(path).copy('${(await _dir()).path}/$name');
  return name;
}

/// The receipt's file on this device, or null when it lives on another device.
Future<File?> receiptFile(String name) async {
  final f = File('${(await _dir()).path}/$name');
  return f.existsSync() ? f : null;
}
