import 'dart:io';

import 'package:budget_app/version.dart';
import 'package:flutter_test/flutter_test.dart';

/// The version shown in the app is the one being released.
void main() {
  test('appVersion matches pubspec.yaml', () {
    final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    expect(line.substring(8).trim().split('+').first, appVersion);
  });
}
