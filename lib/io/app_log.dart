import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../platform.dart';

/// The computer version's log (budget.log next to its database): startup steps and errors, so a
/// problem on someone's PC can be seen. Holds no data — only what the app was doing. Phone: nothing.
class AppLog {
  static File? _file;

  static Future<void> start() async {
    if (!appIsDesktop) return;
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File(p.join(dir.path, 'budget.log'));
      // Kept small: the last run only.
      if (_file!.existsSync() && _file!.lengthSync() > 200000) _file!.deleteSync();
    } catch (_) {
      _file = null;
    }
  }

  static void line(String message) {
    final f = _file;
    if (f == null) return;
    try {
      f.writeAsStringSync('${DateTime.now().toIso8601String()} $message\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }
}
