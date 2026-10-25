import 'dart:convert';
import 'dart:io';

import 'package:budget_app/capture/capture_service.dart';
import 'package:budget_app/data/database.dart';
import 'package:budget_app/data/models.dart';
import 'package:budget_app/data/rates.dart';
import 'package:budget_app/data/repository.dart';
import 'package:budget_app/domain/envelopes.dart';
import 'package:budget_app/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Envelope budgeting: what is left carries over, overspending too, money moves between envelopes.
void main() {
  sqfliteFfiInit();
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late AppState state;
  final now = DateTime.now();
  final thisMonth = DateTime(now.year, now.month);
  final lastMonth = DateTime(now.year, now.month - 1);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('budget_env_');
    final db = await openAppDatabase(factory: databaseFactoryFfi, path: '${tmp.path}/b.db');
    state = AppState(Repository(db), CaptureService(),
        RatesService(db, client: MockClient((_) async => http.Response(jsonEncode({'date': '2026-10-18', 'cny': {}}), 200))));
    await state.init();
  });
  tearDown(() async {
    await state.repo.db.close();
    tmp.deleteSync(recursive: true);
  });

  Category cat(String key) => state.categories.firstWhere((c) => c.key == key);
  Future<void> spend(String key, int minor, DateTime at) => state.repo.insertTxn(
      Txn(time: at.add(const Duration(days: 2)), amountMinor: minor, currency: state.baseCurrency, kind: TxnKind.expense, categoryId: cat(key).id));
  Envelope of(List<Envelope> l, String key) => l.firstWhere((e) => e.categoryId == cat(key).id);

  test('leftovers and overspending carry into the next month; moving money covers a minus', () async {
    await state.setEnvelopesOn(true);
    state.envelopes.start = envelopeMonth(lastMonth);
    await state.setEnvelope(cat('food'), lastMonth, 100000, everyMonth: true);
    await state.setEnvelope(cat('fun'), lastMonth, 20000, everyMonth: true);
    await spend('food', 80000, lastMonth); // 200 left in food
    await spend('fun', 30000, lastMonth); // 100 over in fun
    await spend('food', 50000, thisMonth);

    final list = await state.envelopesFor(thisMonth);
    expect(of(list, 'food').allocated, 100000);
    expect(of(list, 'food').spent, 50000);
    expect(of(list, 'food').available, 100000 + 100000 - 80000 - 50000);
    expect(of(list, 'fun').available, 20000 + 20000 - 30000);

    await state.moveEnvelope(cat('food'), cat('fun'), thisMonth, 15000);
    final after = await state.envelopesFor(thisMonth);
    expect(of(after, 'fun').allocated, 35000);
    expect(of(after, 'food').allocated, 85000);
    // Last month is untouched; the default plan stays.
    expect(of(await state.envelopesFor(lastMonth), 'food').allocated, 100000);
    // Shared as one setting, by category uid.
    expect(jsonDecode((await state.repo.setting('envelopes'))!)['plan'], hasLength(2));
    expect((await envelopePlanById(state.repo))[cat('food').id], 100000);
  });
}
