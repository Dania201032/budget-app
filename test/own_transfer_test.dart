import 'dart:convert';
import 'dart:io';

import 'package:budget_app/capture/capture_service.dart';
import 'package:budget_app/data/database.dart';
import 'package:budget_app/data/models.dart';
import 'package:budget_app/data/rates.dart';
import 'package:budget_app/data/repository.dart';
import 'package:budget_app/l10n/strings.dart';
import 'package:budget_app/state/app_state.dart';
import 'package:budget_app/ui/txn_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A transfer to myself with its other account chosen by hand ("from which" / "to which").
void main() {
  sqfliteFfiInit();
  late Database db;
  late Repository repo;
  final t0 = DateTime(2026, 10, 18, 12);

  setUp(() async {
    db = await openAppDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    repo = Repository(db)..convert = (a, from, to, at) => from == 'RUB' && to == 'CNY' ? a ~/ 12 : (from == to ? a : null);
  });
  tearDown(() => db.close());

  Future<(int, int, int)> setup() async {
    final vtb = await repo.addAccount('ВТБ', 'RUB', 'vtb');
    final tbank = await repo.addAccount('Т-Банк', 'RUB', 'tbank');
    final alipay = (await repo.accounts()).firstWhere((a) => a.type == 'alipay').id;
    for (final id in [vtb, tbank, alipay]) {
      await repo.setAccountBalance(id, 0, t0.subtract(const Duration(days: 1)));
    }
    return (vtb, tbank, alipay);
  }

  Future<Txn> outOf(int account, int minor) async {
    final id = await repo.insertTxn(Txn(time: t0, amountMinor: minor, currency: 'RUB', kind: TxnKind.expense, accountId: account));
    await repo.linkOwnTransfer((await repo.txnById(id))!, null);
    return (await repo.txnById(id))!;
  }

  Account acc(List<Account> all, int id) => all.firstWhere((a) => a.id == id);

  test('choosing the other account adds its side, so both balances move', () async {
    final (vtb, tbank, _) = await setup();
    final t = await outOf(vtb, 500000);
    expect(await repo.setTransferCounterpart(t, acc(await repo.accounts(), tbank)), isTrue);
    final b = await repo.accountBalances();
    expect(b[vtb], -500000);
    expect(b[tbank], 500000);
    final mirror = (await repo.txnById((await repo.txnById(t.id!))!.pairId!))!;
    expect(mirror.kind, TxnKind.income);
    expect(mirror.ownTransfer && mirror.excluded, isTrue);
    expect(mirror.merchant, 'ВТБ');
  });

  test('another currency goes by the rate; changing the account moves the side; "not in the app" removes it', () async {
    final (vtb, tbank, alipay) = await setup();
    final t = await outOf(vtb, 120000);
    final accounts = await repo.accounts();
    await repo.setTransferCounterpart(t, acc(accounts, alipay));
    expect((await repo.accountBalances())[alipay], 10000, reason: '1 200 ₽ = 100 ¥');

    await repo.setTransferCounterpart((await repo.txnById(t.id!))!, acc(accounts, tbank));
    var b = await repo.accountBalances();
    expect(b[alipay], 0);
    expect(b[tbank], 120000);

    await repo.setTransferCounterpart((await repo.txnById(t.id!))!, null);
    b = await repo.accountBalances();
    expect(b[tbank], 0);
    expect((await repo.txnById(t.id!))!.ownTransfer, isTrue);
    expect(await repo.txnsBetween(DateTime(2026), DateTime(2027)), hasLength(1));
  });

  test('"not a transfer to myself" removes the side the app added', () async {
    final (vtb, tbank, _) = await setup();
    final t = await outOf(vtb, 500000);
    await repo.setTransferCounterpart(t, acc(await repo.accounts(), tbank));
    await repo.unlinkOwnTransfer((await repo.txnById(t.id!))!);
    expect(await repo.txnsBetween(DateTime(2026), DateTime(2027)), hasLength(1));
    expect((await repo.accountBalances())[tbank], 0);
  });

  testWidgets('editor: turn on the transfer, pick "to which account", save', (tester) async {
    tester.view.physicalSize = const Size(1080, 2392);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    late AppState state;
    late Txn t;
    late int tbank;
    await tester.runAsync(() async {
      await initializeDateFormatting();
      final file = await openAppDatabase(
          factory: databaseFactoryFfi, path: '${Directory.systemTemp.path}/own_${DateTime.now().microsecondsSinceEpoch}.db');
      final r = Repository(file);
      final vtb = await r.addAccount('ВТБ', 'RUB', 'vtb');
      tbank = await r.addAccount('Т-Банк', 'RUB', 'tbank');
      final id = await r.insertTxn(Txn(time: t0, amountMinor: 500000, currency: 'RUB', kind: TxnKind.expense, accountId: vtb, source: 'vtb:bank'));
      t = (await r.txnById(id))!;
      state = AppState(r, CaptureService(),
          RatesService(file, client: MockClient((_) async => http.Response(jsonEncode({'date': '2026-10-18', 'cny': {}}), 200))));
      await state.init();
    });
    currentLanguage = 'ru';
    await tester.pumpWidget(ChangeNotifierProvider.value(value: state, child: MaterialApp(home: TxnEditor(txn: t))));
    await tester.pumpAndSettle();

    Future<void> settle() async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await tester.scrollUntilVisible(find.text(tr('own_transfer')), 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text(tr('own_transfer')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text(tr('transfer_to_account')), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text(tr('transfer_not_in_app')), findsOneWidget);
    await tester.tap(find.text(tr('transfer_not_in_app')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Т-Банк').last);
    await tester.pumpAndSettle();
    expect(find.text('Т-Банк'), findsOneWidget);

    await tester.tap(find.text(tr('save')).first);
    // Saving writes the mirror in several steps; under a loaded full run that takes longer.
    var saved = t;
    for (var i = 0; i < 20 && saved.pairId == null; i++) {
      await settle();
      saved = (await tester.runAsync<Txn?>(() => state.repo.txnById(t.id!)))!;
    }
    expect(saved.ownTransfer, isTrue);
    final mirror = (await tester.runAsync(() => state.repo.txnById(saved.pairId!)))!;
    expect(mirror.accountId, tbank);
  });
}
