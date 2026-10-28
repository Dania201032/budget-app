import 'dart:io';

import 'package:budget_app/capture/capture_service.dart';
import 'package:budget_app/data/database.dart';
import 'package:budget_app/data/rates.dart';
import 'package:budget_app/data/repository.dart';
import 'package:budget_app/l10n/strings.dart';
import 'package:budget_app/state/app_state.dart';
import 'package:budget_app/ui/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Android setup of automatic recording: the in-app disclosure comes before any system settings
/// screen (Google Play), and Android 13+ gets the "Restricted settings" walkthrough.
void main() {
  sqfliteFfiInit();
  const channel = MethodChannel('budget/capture');
  final opened = <String>[];
  var sdk = 34;
  var restricted = false;
  var notifications = false;
  var country = 'CN';

  setUp(() {
    opened.clear();
    restricted = false;
    notifications = false;
    country = 'CN';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'status':
          return {'accessibility': false, 'notifications': notifications, 'postNotifications': true, 'sdk': sdk, 'restricted': restricted};
        case 'consumeInbox':
        case 'bankLog':
          return '';
        case 'openAccessibility':
        case 'openNotificationAccess':
        case 'openAppInfo':
          opened.add(call.method);
      }
      return null;
    });
  });

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

  Future<AppState> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2392);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    late AppState state;
    await tester.runAsync(() async {
      await initializeDateFormatting();
      final db = await openAppDatabase(
          factory: databaseFactoryFfi, path: '${Directory.systemTemp.path}/setup_${DateTime.now().microsecondsSinceEpoch}.db');
      final repo = Repository(db);
      await repo.setSetting('onboarded', '1');
      await repo.applyCountryPreset(country, fresh: true, cashName: 'Наличные');
      state = AppState(repo, CaptureService(), RatesService(db, client: MockClient((_) async => http.Response('{}', 404))));
      await state.init();
    });
    currentLanguage = 'ru';
    await tester.pumpWidget(ChangeNotifierProvider.value(value: state, child: const MaterialApp(home: CaptureSetupScreen())));
    await tester.pumpAndSettle();
    return state;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('system settings open only after the disclosure is accepted, and it is asked once', (tester) async {
    sdk = 34;
    final state = await pump(tester);

    await tester.tap(find.text(tr('capture_step1')));
    await settle(tester);
    expect(find.text(tr('disclosure_t')), findsOneWidget);
    await tester.tap(find.text(tr('disclosure_later')));
    await settle(tester);
    expect(opened, isEmpty, reason: '"Not now" opens nothing');

    await tester.tap(find.text(tr('capture_step1')));
    await settle(tester);
    await tester.tap(find.text(tr('disclosure_agree')));
    await settle(tester);
    expect(opened, ['openAccessibility']);
    expect(state.captureConsent, isTrue);

    await tester.tap(find.text(tr('capture_step2')));
    await settle(tester);
    expect(find.text(tr('disclosure_t')), findsNothing, reason: 'asked once');
    expect(opened, ['openAccessibility', 'openNotificationAccess']);
  });

  testWidgets('Android 13+: the "Restricted settings" walkthrough opens App info', (tester) async {
    sdk = 34;
    await pump(tester);
    await tester.scrollUntilVisible(find.text(tr('restricted_t')), 200);
    expect(find.text(tr('restricted_t')), findsOneWidget);
    await tester.ensureVisible(find.text(tr('restricted_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(tr('restricted_button')));
    await settle(tester);
    expect(opened, ['openAppInfo']);
  });

  testWidgets('Android 12: no walkthrough', (tester) async {
    sdk = 31;
    await pump(tester);
    expect(find.text(tr('restricted_t')), findsNothing);
  });

  testWidgets('installed from a file: the lock is lifted first — try the switch, then App info', (tester) async {
    sdk = 34;
    restricted = true;
    final state = await pump(tester);
    state.captureConsent = true;
    expect(find.text(tr('rs_title')), findsOneWidget);
    await tester.tap(find.text(tr('rs_a_btn')));
    await settle(tester);
    // The switch that is still missing: the notifications come first.
    expect(opened, ['openNotificationAccess']);
    await tester.ensureVisible(find.text(tr('rs_b_btn')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(tr('rs_b_btn')));
    await settle(tester);
    expect(opened, ['openNotificationAccess', 'openAppInfo']);
  });

  testWidgets('with bank cards (Russia) the notifications are enough; reading the screen is optional', (tester) async {
    sdk = 34;
    country = 'RU';
    notifications = true;
    final state = await pump(tester);
    expect(state.captureNeedsScreen, isFalse);
    expect(state.captureReady, isTrue, reason: 'notifications on, screen reading off');
    expect(find.textContaining(tr('capture_optional')), findsOneWidget);
    expect(find.text(tr('rs_title')), findsNothing);
  });
}
