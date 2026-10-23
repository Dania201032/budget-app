import 'dart:convert';
import 'dart:io';

import 'package:budget_app/capture/capture_service.dart';
import 'package:budget_app/data/database.dart';
import 'package:budget_app/data/models.dart';
import 'package:budget_app/data/rates.dart';
import 'package:budget_app/data/repository.dart';
import 'package:budget_app/io/home_widgets.dart';
import 'package:budget_app/l10n/strings.dart';
import 'package:budget_app/main.dart';
import 'package:budget_app/state/app_state.dart';
import 'package:budget_app/ui/analytics_screen.dart';
import 'package:budget_app/ui/bank_log_screen.dart';
import 'package:budget_app/ui/home_screen.dart';
import 'package:budget_app/ui/lock_screen.dart';
import 'package:budget_app/ui/settings_screen.dart';
import 'package:budget_app/ui/txn_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/text_audit.dart';

/// Runs the whole app on the desktop test engine: onboarding, every tab and the main screens,
/// in all four languages. Catches crashes and layout overflows before they reach the phone.
void main() {
  sqfliteFfiInit();
  // Real fonts: overflows and wrapping are measured as on the phone.
  setUpAll(loadAppFonts);
  TextAudit? audit;

  final fakeRates = MockClient((req) async => http.Response(
      jsonEncode({'date': '2026-10-13', 'cny': {'rub': 12.4, 'kzt': 70.0, 'usd': 0.14}}), 200));

  Future<AppState> makeState(WidgetTester tester, {required bool withData}) async {
    late AppState state;
    await tester.runAsync(() async {
      await initializeDateFormatting();
      // A separate database per test (the shared in-memory one would carry data over).
      final db = await openAppDatabase(
          factory: databaseFactoryFfi,
          path: '${Directory.systemTemp.path}/smoke_${DateTime.now().microsecondsSinceEpoch}.db');
      final repo = Repository(db);
      if (withData) {
        final now = DateTime.now();
        final food = (await repo.categories()).firstWhere((c) => c.key == 'food');
        final id = await repo.insertTxn(Txn(
            time: now, amountMinor: 12000, currency: 'CNY', kind: TxnKind.expense, categoryId: food.id,
            merchant: '海底捞', source: 'alipay:screen'));
        await repo.setDebts(id, [('Alex', 6000)], 'CNY');
        await repo.insertTxn(Txn(time: now, amountMinor: 0, currency: 'CNY', kind: TxnKind.income,
            merchant: 'Alex', source: 'wechat:prompt', needsReview: true, raw: 'prompt:1'));
        await repo.insertTxn(Txn(time: now, amountMinor: 45000, currency: 'RUB', kind: TxnKind.expense, merchant: 'Магнит', source: 'sber:bank'));
        await repo.addGoal(name: 'Поездка домой', targetMinor: 800000, savedMinor: 100000, currency: 'CNY',
            deadline: DateTime(now.year, now.month + 3, 1), reserve: true);
        await repo.setAccountBalance((await repo.accounts()).first.id, 500000, now.subtract(const Duration(days: 1)));
        await repo.setSetting('onboarded', '1');
        await repo.setSetting('budget_enabled', '1');
      }
      state = AppState(repo, CaptureService(), RatesService(db, client: fakeRates));
      await state.init();
    });
    return state;
  }

  /// Lets real database I/O (started from taps) finish, rebuilding in between.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    if (audit != null) {
      // The screen on top: the title of its app bar.
      final bars = tester.widgetList<AppBar>(find.byType(AppBar).hitTestable());
      final title = bars.map((b) => b.title).whereType<Text>().map((t) => t.data).firstOrNull;
      audit!.check(tester, title ?? 'home');
    }
  }

  Future<void> back(WidgetTester tester) async {
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.pop();
    await tester.pumpAndSettle();
  }

  testWidgets('first start: country -> language -> guide -> app', (tester) async {
    tester.view.physicalSize = const Size(1080, 2392);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    currentLanguage = 'ru';
    final state = await makeState(tester, withData: false);
    await tester.pumpWidget(ChangeNotifierProvider.value(value: state, child: const BudgetApp()));
    await tester.pumpAndSettle();

    expect(find.text(tr('choose_country')), findsOneWidget);
    await tester.tap(find.textContaining(tr('country_KZ')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(tr('next')));
    await tester.pumpAndSettle();
    expect(find.text('Қазақша'), findsOneWidget);
    await tester.tap(find.text('Қазақша'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(tr('next')));
    await tester.pumpAndSettle();
    // The app lock is offered; "Not now" leaves it off.
    expect(find.text(tr('lock_offer_t')), findsOneWidget);
    await tester.tap(find.text(tr('lock_offer_no')));
    await tester.pumpAndSettle();
    expect(appLock.enabled, isFalse);
    // Guide in Kazakh: walk through all 5 steps.
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text(tr('next')));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text(tr('start')));
    await settle(tester);
    expect(state.onboarded, isTrue);
    expect(state.baseCurrency, 'KZT');
    expect(find.text(tr('nav_home')), findsWidgets);
  });

  testWidgets('home-screen widget snapshot carries what the widgets draw', (tester) async {
    currentLanguage = 'ru';
    final state = await makeState(tester, withData: true);
    late Map<String, Object?> snap;
    await tester.runAsync(() async => snap = await HomeWidgetsBridge.snapshot(state));
    final json = jsonDecode(jsonEncode(snap)) as Map<String, dynamic>; // must survive the platform channel
    expect(json['date'], isNotEmpty);
    expect(json['cur'], '¥');
    final month = json['month'] as Map<String, dynamic>;
    expect((month['days'] as List).length, DateUtils.getDaysInMonth(DateTime.now().year, DateTime.now().month));
    expect(month['spent'], isNotEmpty);
    expect(json['today'], isNotNull);
    final quick = json['quick'] as List;
    expect(quick.length, 4);
    expect((quick.first as Map)['name'], 'Еда'); // the only category used
    expect((json['labels'] as Map)['record'], 'Запись');
  });

  for (final lang in supportedLanguages) {
    testWidgets('all tabs and main screens render in $lang', (tester) async {
      tester.view.physicalSize = const Size(1080, 2392);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      currentLanguage = lang;
      audit = TextAudit(lang);
      addTearDown(() => audit?.write());
      final state = await makeState(tester, withData: true);
      await tester.runAsync(() => state.setLanguage(lang));
      await tester.pumpWidget(ChangeNotifierProvider.value(value: state, child: const BudgetApp()));
      await settle(tester);

      // Home in every period type.
      for (final p in ['period_day', 'period_week', 'period_month', 'period_year']) {
        await tester.tap(find.text(tr(p)).first);
        await settle(tester);
      }
      expect(find.text(tr('review_banner', [1])), findsOneWidget);

      // Search: by payee, then the period filter.
      await tester.tap(find.byTooltip(tr('search')).first);
      await settle(tester);
      await tester.enterText(find.byType(TextField).first, '海底');
      await settle(tester);
      expect(find.textContaining('海底捞'), findsWidgets);
      await tester.tap(find.text(tr('search_range_all')));
      await settle(tester);
      await tester.tap(find.text(tr('search_range_month')).last);
      await settle(tester);
      expect(find.textContaining('海底捞'), findsWidgets);
      await back(tester);
      await settle(tester);

      // Review screen with an amount field for the WeChat transfer.
      await tester.tap(find.text(tr('review_banner', [1])));
      await settle(tester);
      expect(find.text(tr('how_much_in')), findsOneWidget);
      await back(tester);
      await settle(tester);

      // Transaction editor + split sheet.
      final dinner = state.homeTxns.firstWhere((t) => t.merchant == '海底捞');
      openTxnEditor(tester.element(find.byType(HomeScreen)), txn: dinner);
      await settle(tester);
      await tester.tap(find.textContaining(tr('split_bill')).first);
      await settle(tester);
      final apply = find.widgetWithText(FilledButton, tr('split_apply'));
      expect(apply, findsOneWidget);
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await settle(tester);

      for (final tab in ['nav_overview', 'nav_money', 'nav_settings']) {
        await tester.tap(find.text(tr(tab)).last);
        await settle(tester);
      }

      // Regular payments: add one due tomorrow; it shows in "Soon" on the home screen.
      await tester.scrollUntilVisible(find.text(tr('recurring')), 200,
          scrollable: find.descendant(of: find.byType(SettingsScreen), matching: find.byType(Scrollable)).first);
      await tester.tap(find.text(tr('recurring')));
      await settle(tester);
      await tester.tap(find.text(tr('recurring_add')));
      await settle(tester);
      await tester.enterText(find.byType(TextField).at(0), 'Rent');
      await tester.enterText(find.byType(TextField).at(1), '3000');
      await tester.ensureVisible(find.widgetWithText(FilledButton, tr('save')));
      await tester.tap(find.widgetWithText(FilledButton, tr('save')));
      await settle(tester);
      expect(state.recurring.single.name, 'Rent');
      await back(tester);
      await settle(tester);
      await tester.tap(find.text(tr('nav_home')).last);
      await settle(tester);
      expect(find.text(tr('soon').toUpperCase()), findsWidgets);
      await tester.tap(find.text(tr('nav_settings')).last);
      await settle(tester);
      // Overview grid in month and year.
      await tester.tap(find.text(tr('nav_overview')).last);
      await settle(tester);
      // 'By day' in all three views.
      await tester.scrollUntilVisible(find.text(tr('view_calendar')), 300, scrollable: find.byType(Scrollable).first);
      expect(find.textContaining(tr('grid_day_left'), findRichText: true), findsWidgets);
      for (final v in ['view_calendar', 'view_table', 'view_list']) {
        await tester.tap(find.text(tr(v)));
        await settle(tester);
      }

      // Analytics: forecast card, its settings, chart picker, year charts.
      await tester.tap(find.text(tr('nav_analytics')).last);
      await settle(tester);
      expect(find.text(tr('chart_runway').toUpperCase()), findsWidgets);
      await tester.tap(find.byTooltip(tr('runway_settings')));
      await settle(tester);
      expect(find.text(tr('rs_money')), findsOneWidget);
      await tester.scrollUntilVisible(find.text(tr('rs_target')), 300, scrollable: find.byType(Scrollable).last);
      await back(tester);
      await settle(tester);
      await tester.scrollUntilVisible(find.descendant(of: find.byType(AnalyticsScreen), matching: find.text(tr('period_year'))), 200,
          scrollable: find.descendant(of: find.byType(AnalyticsScreen), matching: find.byType(Scrollable)).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(tr('period_year')).last);
      await settle(tester);
      await tester.tap(find.byTooltip(tr('charts_shown')));
      await settle(tester);
      await back(tester);
      await settle(tester);

      // Money: goal editor.
      await tester.tap(find.text(tr('nav_money')).last);
      await settle(tester);
      expect(find.text('Поездка домой'), findsOneWidget);
      expect(find.byType(PopupMenuButton<String>), findsWidgets);
      await tester.tap(find.text(tr('add_goal')));
      await settle(tester);
      await back(tester);
      await settle(tester);

      // Settings: help, categories, backup screens.
      await tester.tap(find.text(tr('nav_settings')).last);
      await settle(tester);
      for (final item in ['help', 'categories', 'backup']) {
        await tester.scrollUntilVisible(find.text(tr(item)), 200, scrollable: find.byType(Scrollable).last);
        // Keep it clear of the bottom navigation bar.
        await tester.drag(find.byType(Scrollable).last, const Offset(0, -300));
        await tester.pumpAndSettle();
        await tester.tap(find.text(tr(item)));
        await settle(tester);
        await back(tester);
        await settle(tester);
      }

      // Screens reached deeper in Settings, opened directly (their tiles may sit under the navigation bar).
      for (final screen in const <Widget>[CaptureSetupScreen(), BankLogScreen(), RatesScreen(), LockSettingsScreen()]) {
        Navigator.of(tester.element(find.byType(SettingsScreen))).push(MaterialPageRoute<void>(builder: (_) => screen));
        await settle(tester);
        await back(tester);
        await settle(tester);
      }
    });
  }
}
