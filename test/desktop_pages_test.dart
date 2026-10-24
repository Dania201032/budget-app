import 'dart:convert';
import 'dart:io';

import 'package:budget_app/capture/capture_service.dart';
import 'package:budget_app/data/database.dart';
import 'package:budget_app/data/models.dart';
import 'package:budget_app/data/rates.dart';
import 'package:budget_app/data/repository.dart';
import 'package:budget_app/desktop/first_run_page.dart';
import 'package:budget_app/desktop/kit.dart';
import 'package:budget_app/desktop/shell.dart';
import 'package:budget_app/l10n/strings.dart';
import 'package:budget_app/platform.dart';
import 'package:budget_app/state/app_state.dart';
import 'package:budget_app/ui/ledger.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/text_audit.dart';

/// Opens every page of the computer version on real data, wide and narrow, in several
/// languages: catches crashes and layout overflows before the Windows build.
void main() {
  sqfliteFfiInit();
  setUpAll(loadAppFonts);

  final fakeRates = MockClient((req) async => http.Response(
      jsonEncode({'date': '2026-10-13', 'cny': {'rub': 11.2, 'eur': 0.12, 'usd': 0.14}}), 200));

  Future<AppState> makeState(WidgetTester tester, {bool onboarded = true}) async {
    late AppState state;
    await tester.runAsync(() async {
      await initializeDateFormatting();
      final db = await openAppDatabase(
          factory: databaseFactoryFfi,
          path: '${Directory.systemTemp.path}/desk_${DateTime.now().microsecondsSinceEpoch}.db');
      final repo = Repository(db);
      final now = DateTime.now();
      final cats = await repo.categories();
      final food = cats.firstWhere((c) => c.key == 'food');
      final transport = cats.firstWhere((c) => c.key == 'transport');
      final salary = cats.firstWhere((c) => c.key == 'salary');
      final acc = (await repo.accounts()).first;
      for (var m = 0; m < 8; m++) {
        for (var d = 1; d <= 20; d += 3) {
          final t = DateTime(now.year, now.month - m, d, 12 + d % 8);
          if (t.isAfter(now)) continue;
          await repo.insertTxn(Txn(time: t, amountMinor: 3000 + d * 200, currency: 'CNY', kind: TxnKind.expense,
              categoryId: d.isEven ? food.id : transport.id, accountId: acc.id, merchant: d.isEven ? 'Canteen' : 'Metro', source: 'manual'));
        }
        final pay = DateTime(now.year, now.month - m, 1, 9);
        await repo.insertTxn(Txn(time: pay, amountMinor: 3000000, currency: 'RUB', kind: TxnKind.income,
            categoryId: salary.id, merchant: 'Employer', source: 'manual'));
      }
      await repo.insertTxn(Txn(time: now, amountMinor: 4400, currency: 'CNY', kind: TxnKind.expense,
          merchant: 'Shop', source: 'alipay:notification', needsReview: true, raw: '你有一笔44.00元的支出'));
      await repo.addGoal(name: 'Trip', targetMinor: 600000, savedMinor: 420000, currency: 'CNY',
          deadline: DateTime(now.year, now.month + 2, 20), reserve: false);
      await repo.setAccountBalance(acc.id, 624000, now.subtract(const Duration(days: 1)));
      await repo.setSetting('desk_countries', jsonEncode([{'code': 'CN', 'home': true}, {'code': 'RU', 'home': false}]));
      await repo.setSetting('desk_holdings', jsonEncode([
        {'id': '1', 'type': 'deposit', 'name': 'Deposit', 'currency': 'RUB', 'amount': 4600000, 'rate': 16, 'received': 610000, 'counted': true},
      ]));
      if (onboarded) await repo.setSetting('onboarded', '1');
      await repo.setSetting('budget_enabled', '1');
      state = AppState(repo, CaptureService(), RatesService(db, client: fakeRates));
      await state.init(syncAfter: false);
      await state.setBudget(450000);
    });
    return state;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 16; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Widget app(AppState state, Widget home) => ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(theme: ledgerTheme(Brightness.light), home: home),
      );

  for (final lang in ['ru', 'en', 'zh', 'de']) {
    for (final width in [1440.0, 820.0]) {
      testWidgets('desktop pages · $lang · ${width.toInt()}', (tester) async {
        appIsDesktop = true;
        currentLanguage = lang;
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final state = await makeState(tester);
        await tester.pumpWidget(app(state, const DesktopShell()));
        // The shell folds a year of data before the first page shows.
        for (var i = 0; i < 300 && find.byType(DeskPage).evaluate().isEmpty; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
          await tester.pump(const Duration(milliseconds: 50));
        }
        await settle(tester);
        expect(tester.takeException(), isNull);
        final desk = tester.element(find.byType(DeskPage).first).read<DeskController>();
        for (final page in [
          DeskPages.summary, DeskPages.operations, DeskPages.income, DeskPages.analytics, DeskPages.forecast,
          DeskPages.taxes, DeskPages.documents, DeskPages.excel, DeskPages.settings,
        ]) {
          desk.go(page);
          await settle(tester);
          expect(tester.takeException(), isNull, reason: 'page $page');
          // Statement import and the shared budget are reachable on the computer too.
          if (page == DeskPages.operations) expect(find.text(tr('stmt_title')), findsWidgets);
          if (page == DeskPages.settings) {
            expect(find.text(tr('hh_title'), skipOffstage: false), findsWidgets);
            expect(find.text(tr('stmt_title'), skipOffstage: false), findsWidgets);
          }
          // Scroll to the end: lazily built parts get laid out too.
          await tester.drag(find.byType(ListView).first, const Offset(0, -6000));
          await settle(tester);
          expect(tester.takeException(), isNull, reason: 'page $page, scrolled');
        }
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
      });
    }
  }

  testWidgets('desktop first run', (tester) async {
    appIsDesktop = true;
    currentLanguage = 'ru';
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = await makeState(tester, onboarded: false);
    await tester.pumpWidget(app(state, const FirstRunPage()));
    await settle(tester);
    expect(tester.takeException(), isNull);
    // Only the phone's countries are offered.
    expect(find.text(tr('d_c_US')), findsNothing);
    await tester.tap(find.text(tr('d_c_DE')).first);
    await settle(tester);
    expect(find.textContaining('EUR'), findsWidgets);
    // The language comes first and switches the whole page.
    await tester.tap(find.text('English'));
    await settle(tester);
    expect(currentLanguage, 'en');
    expect(find.text(tr('d_welcome')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('taxes calculator reacts to typing', (tester) async {
    appIsDesktop = true;
    currentLanguage = 'ru';
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = await makeState(tester);
    await tester.pumpWidget(app(state, const DesktopShell()));
    for (var i = 0; i < 300 && find.byType(DeskPage).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await settle(tester);
    final desk = tester.element(find.byType(DeskPage).first).read<DeskController>();
    desk.go(DeskPages.taxes);
    await settle(tester);
    final label = tr('d_calc_gross_in', [tr('d_calc_month').toLowerCase(), '{c}']);
    final field = find.byWidgetPredicate((w) => w is FieldBox && (w.label == label.replaceAll('{c}', 'CNY') || w.label == label.replaceAll('{c}', 'RUB')));
    for (var i = 0; i < 20 && field.evaluate().isEmpty; i++) {
      await tester.drag(find.descendant(of: find.byType(DeskPage), matching: find.byType(ListView)).first, const Offset(0, -500));
      await settle(tester);
    }
    await settle(tester);
    String texts() => tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? '').join('|');
    final before = texts();
    await tester.enterText(find.descendant(of: field, matching: find.byType(TextField)), '1000000');
    await settle(tester);
    final after = texts();
    expect(after == before, isFalse, reason: 'nothing changed after typing');
    expect(find.text(tr('d_calc_enter')), findsNothing);
    expect(find.text(tr('d_calc_steps')), findsOneWidget);
    // Clear all brings the prompt back.
    await tester.ensureVisible(find.text(tr('d_clear_all')).first);
    await settle(tester);
    await tester.tap(find.text(tr('d_clear_all')).first);
    await settle(tester);
    expect(find.text(tr('d_calc_enter')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
