import 'dart:convert';
import 'dart:io';

import 'package:budget_app/capture/capture_service.dart';
import 'package:budget_app/data/database.dart';
import 'package:budget_app/data/models.dart';
import 'package:budget_app/data/rates.dart';
import 'package:budget_app/data/repository.dart';
import 'package:budget_app/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// "Close a goal": a purchase paid from a goal's savings.
void main() {
  sqfliteFfiInit();
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late AppState state;
  final t0 = DateTime.now();

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('budget_goal_');
    final db = await openAppDatabase(factory: databaseFactoryFfi, path: '${tmp.path}/b.db');
    state = AppState(Repository(db), CaptureService(),
        RatesService(db, client: MockClient((_) async => http.Response(jsonEncode({'date': '2026-10-18', 'cny': {}}), 200))));
    await state.init();
  });
  tearDown(() async {
    await state.repo.db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<Goal> goal(int target, int saved) async {
    await state.addGoal(name: 'Laptop', targetMinor: target, savedMinor: saved, reserve: true);
    return state.goals.last;
  }

  Future<Txn> purchase(int minor, {int? account, int? category}) async {
    final id = await state.repo.insertTxn(Txn(
        time: t0, amountMinor: minor, currency: 'CNY', kind: TxnKind.expense, merchant: 'Shop', accountId: account, categoryId: category));
    return (await state.repo.txnById(id))!;
  }

  test('fully: the savings pay, no account moves again, the category stays, the goal closes', () async {
    final card = (await state.repo.accounts()).firstWhere((a) => a.type == 'alipay').id;
    await state.repo.setAccountBalance(card, 1000000, t0.subtract(const Duration(days: 1)));
    final g = await goal(500000, 480000);
    final shopping = state.categories.firstWhere((c) => c.key == 'shopping').id;
    final t = await purchase(450000, account: card, category: shopping);
    await state.spendFromGoal(t, g, close: true);
    final after = (await state.repo.txnById(t.id!))!;
    expect(after.goalId, g.id);
    expect(after.excluded, isTrue);
    expect(after.accountId, isNull);
    expect(after.categoryId, shopping);
    expect((await state.repo.accountBalances())[card], 1000000);
    expect(state.goals, isEmpty);
    expect((await state.repo.goalById(g.id))!.savedMinor, 30000);
    expect(state.goalNames[g.id], 'Laptop');
  });

  test('partly: only this amount leaves the savings, the goal stays', () async {
    final g = await goal(500000, 200000);
    final t = await purchase(50000);
    await state.spendFromGoal(t, g, close: false);
    expect(state.goals.single.savedMinor, 150000);
    expect((await state.repo.txnById(t.id!))!.excluded, isTrue);
  });

  test('more than was saved: the savings pay their part, the rest is an ordinary purchase', () async {
    final card = (await state.repo.accounts()).firstWhere((a) => a.type == 'alipay').id;
    final g = await goal(500000, 20000);
    final t = await purchase(50000, account: card);
    await state.spendFromGoal(t, g, close: false);
    expect(state.goals.single.savedMinor, 0);
    final rest = (await state.repo.txnById(t.id!))!;
    expect(rest.amountMinor, 30000);
    expect(rest.accountId, card);
    expect(rest.excluded, isFalse);
    final paid = (await state.repo.allTxns()).firstWhere((x) => x.goalId == g.id);
    expect(paid.amountMinor, 20000);
    expect(paid.excluded, isTrue);
    expect(paid.accountId, isNull);
  });

  test('not from the goal after all: the money goes back and the goal opens again', () async {
    final g = await goal(500000, 480000);
    final t = await purchase(450000);
    await state.spendFromGoal(t, g, close: true);
    final card = (await state.repo.accounts()).firstWhere((a) => a.type == 'alipay').id;
    await state.returnToGoal((await state.repo.txnById(t.id!))!, accountId: card);
    final after = (await state.repo.txnById(t.id!))!;
    expect(after.goalId, isNull);
    expect(after.excluded, isFalse);
    expect(after.accountId, card);
    expect(state.goals.single.savedMinor, 480000);
  });

  test('from the goal card: a purchase recorded straight from the savings', () async {
    final g = await goal(500000, 500000);
    await state.buyFromGoal(g, 500000, merchant: 'Laptop shop', close: true);
    final t = (await state.repo.allTxns()).single;
    expect(t.merchant, 'Laptop shop');
    expect(t.goalId, g.id);
    expect(t.accountId, isNull);
    expect(t.excluded, isTrue);
    expect(state.goals, isEmpty);
  });
}
