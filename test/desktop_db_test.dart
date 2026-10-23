import 'dart:io';

import 'package:budget_app/data/database.dart';
import 'package:budget_app/data/repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// The computer's database: encrypted on disk, readable only with its key.
void main() {
  test('the Windows database file is encrypted', () async {
    final dir = Directory.systemTemp.createTempSync('budget_desktop_');
    final path = '${dir.path}/budget.db';
    final key = 'a1' * 32;
    final db = await openDesktopDatabase(path: path, key: key);
    await Repository(db).setSetting('base_currency', 'EUR');
    await db.close();

    final head = String.fromCharCodes(File(path).readAsBytesSync().take(15));
    expect(head, isNot('SQLite format 3'));

    final again = await openDesktopDatabase(path: path, key: key);
    expect(await Repository(again).setting('base_currency'), 'EUR');
    await again.close();

    await expectLater(openDesktopDatabase(path: path, key: 'b2' * 32), throwsA(anything));
    dir.deleteSync(recursive: true);
  });
}
