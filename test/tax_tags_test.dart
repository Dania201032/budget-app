import 'dart:convert';
import 'dart:io';

import 'package:budget_app/capture/capture_service.dart';
import 'package:budget_app/data/database.dart';
import 'package:budget_app/data/models.dart';
import 'package:budget_app/data/rates.dart';
import 'package:budget_app/data/repository.dart';
import 'package:budget_app/domain/tax_tags.dart';
import 'package:budget_app/l10n/strings.dart';
import 'package:budget_app/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Tax marks: a category's mark, an operation's own (or "none"), the year's report.
void main() {
  sqfliteFfiInit();
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late AppState state;
  final year = DateTime.now().year;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('budget_tax_');
    final db = await openAppDatabase(factory: databaseFactoryFfi, path: '${tmp.path}/b.db');
    state = AppState(Repository(db), CaptureService(),
        RatesService(db, client: MockClient((_) async => http.Response(jsonEncode({'date': '2026-10-18', 'cny': {}}), 200))));
    await state.init();
  });
  tearDown(() async {
    await state.repo.db.close();
    tmp.deleteSync(recursive: true);
  });

  test('marks come from the category unless the operation has its own', () async {
    final health = state.categories.firstWhere((c) => c.key == 'health');
    final food = state.categories.firstWhere((c) => c.key == 'food');
    await state.setCategoryTaxTag(health, 'medical');
    Future<void> spend(int minor, Category c, {String? tag}) => state.repo.insertTxn(Txn(
        time: DateTime(year, 3, 1), amountMinor: minor, currency: state.baseCurrency, kind: TxnKind.expense, categoryId: c.id, taxTag: tag));
    await spend(5000, health);
    await spend(700, health, tag: 'none');
    await spend(3000, food, tag: 'medical'); // a pharmacy bought with groceries
    await spend(900, food);

    final r = await state.taxReport(year);
    expect(r.keys, ['medical']);
    expect(r['medical']!.map((t) => t.amountMinor).toSet(), {5000, 3000});
    expect(state.categoryTaxTag(health.id), 'medical');
    expect(jsonDecode((await state.repo.setting('tax_tags'))!), hasLength(1));
  });

  test('every mark has its text', () {
    for (final t in taxTagKeys) {
      expect(hasTr('tax_$t'), isTrue, reason: t);
    }
  });
}
