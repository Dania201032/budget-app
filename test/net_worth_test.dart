import 'dart:convert';
import 'dart:io';

import 'package:budget_app/capture/capture_service.dart';
import 'package:budget_app/data/database.dart';
import 'package:budget_app/data/rates.dart';
import 'package:budget_app/data/repository.dart';
import 'package:budget_app/domain/holding.dart';
import 'package:budget_app/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Net worth: accounts, goals, investments, property and friends' debts, minus cards and loans.
void main() {
  sqfliteFfiInit();
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late AppState state;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('budget_nw_');
    final db = await openAppDatabase(factory: databaseFactoryFfi, path: '${tmp.path}/b.db');
    state = AppState(Repository(db), CaptureService(),
        RatesService(db, client: MockClient((_) async => http.Response(jsonEncode({'date': '2026-10-18', 'cny': {}}), 200))));
    await state.init();
  });
  tearDown(() async {
    await state.repo.db.close();
    tmp.deleteSync(recursive: true);
  });

  test('what one has minus what one owes, recorded for the month and kept in a shared setting', () async {
    final accounts = await state.repo.accounts();
    final alipay = accounts.firstWhere((a) => a.type == 'alipay');
    final card = await state.repo.addAccount('Card', 'CNY', 'bank');
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    await state.repo.setAccountBalance(alipay.id, 500000, yesterday);
    await state.repo.setAccountBalance(card, -20000, yesterday);
    await state.addGoal(name: 'Trip', targetMinor: 300000, savedMinor: 100000, reserve: false);
    await state.saveHolding(const Holding(id: 'h1', type: 'deposit', name: 'Deposit', currency: 'CNY', amountMinor: 1000000));
    await state.saveHolding(const Holding(id: 'h2', type: 'loan', name: 'Student loan', currency: 'CNY', amountMinor: 250000));
    await state.refresh();

    final nw = state.netWorth;
    expect(nw.accounts, 500000);
    expect(nw.cards, 20000);
    expect(nw.goals, 100000);
    expect(nw.investments, 1000000);
    expect(nw.loans, 250000);
    expect(nw.total, 500000 - 20000 + 100000 + 1000000 - 250000);
    expect(state.netWorthHistory.values.last, nw.total);
    // The computer's Income page reads the same setting.
    expect(await state.repo.setting('desk_holdings'), contains('Student loan'));
    expect(const Holding(id: 'x', type: 'loan', name: '', currency: 'CNY', amountMinor: 100).signedMinor, -100);
  });
}
