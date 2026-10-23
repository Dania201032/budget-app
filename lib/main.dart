import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'capture/capture_service.dart';
import 'data/database.dart';
import 'data/rates.dart';
import 'data/repository.dart';
import 'io/home_widgets.dart';
import 'l10n/strings.dart';
import 'state/app_state.dart';
import 'ui/analytics_screen.dart';
import 'ui/home_screen.dart';
import 'ui/ledger.dart';
import 'ui/ledger_icons.dart';
import 'ui/lock_screen.dart';
import 'ui/money_screen.dart';
import 'ui/motion.dart';
import 'ui/onboarding.dart';
import 'ui/overview_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/split_sheet.dart';
import 'ui/txn_editor.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting();
  final repo = Repository(await openAppDatabase());
  // Before the user picks a language: the phone's, if supported.
  if (await repo.setting('language') == null) {
    currentLanguage = guessLanguage(WidgetsBinding.instance.platformDispatcher.locale.languageCode);
    await repo.setSetting('language', currentLanguage);
  }
  final state = AppState(repo, CaptureService(), RatesService(repo.db));
  await state.init();
  await appLock.load();
  HomeWidgetsBridge.listen(state);
  runApp(ChangeNotifierProvider.value(value: state, child: const BudgetApp()));
}

/// Started by Android without any UI (widgets/WidgetRefresh.kt) after a background capture, at
/// midnight or on a clock change: imports captured payments, recomputes, updates the widgets.
@pragma('vm:entry-point')
Future<void> widgetsBackground() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await initializeDateFormatting();
    final repo = Repository(await openAppDatabase());
    final state = AppState(repo, CaptureService(), RatesService(repo.db));
    await state.init();
    await HomeWidgetsBridge.push(state);
  } catch (_) {
    // The widgets keep their last figures; the next trigger tries again.
  }
  await HomeWidgetsBridge.backgroundDone();
}

class BudgetApp extends StatelessWidget {
  const BudgetApp({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final lang = currentLanguage;
    return MaterialApp(
      // A new key rebuilds every screen when the language changes.
      key: ValueKey(lang),
      title: switch (lang) { 'zh' => '预算', 'ru' || 'kk' => 'Бюджет', _ => 'Budget' },
      debugShowCheckedModeBanner: false,
      theme: ledgerTheme(Brightness.light),
      darkTheme: ledgerTheme(Brightness.dark),
      locale: Locale(lang),
      supportedLocales: [for (final l in supportedLanguages) Locale(l)],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: state.onboarded ? const Shell() : const OnboardingFlow(),
      // The app lock covers every screen, dialogs included.
      builder: (context, child) => LockGate(child: child ?? const SizedBox()),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  int _tab = 0;

  /// A short fade when switching tabs, so the change of screen is seen.
  late final AnimationController _fade = AnimationController(vsync: this, duration: motionShort, value: 1);
  late final Animation<double> _opacity = CurvedAnimation(parent: _fade, curve: motionCurve);

  void _go(int tab) {
    if (tab != _tab && MediaQuery.maybeDisableAnimationsOf(context) != true) _fade.forward(from: 0.3);
    setState(() => _tab = tab);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openPendingSplit());
  }

  @override
  void dispose() {
    _fade.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Payments captured in the background are imported on return; changes are backed up on leaving.
  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState s) async {
    final state = context.read<AppState>();
    if (s == AppLifecycleState.resumed) {
      await state.refresh();
      _openPendingSplit();
    } else if (s == AppLifecycleState.paused) {
      await state.autoBackup();
    }
  }

  /// "Split…" pressed on a "Recorded" notification, or a home-screen widget tapped.
  void _openPendingSplit() {
    final state = context.read<AppState>();
    _openPendingWidget(state);
    final t = state.pendingSplit;
    if (t == null || !mounted) return;
    state.clearPendingSplit();
    showSplitSheet(context, t);
  }

  void _openPendingWidget(AppState state) {
    final w = state.pendingWidgetRoute;
    if (w == null || !mounted) return;
    state.clearPendingWidgetRoute();
    Navigator.of(context).popUntil((r) => r.isFirst);
    switch (w.route) {
      case 'add':
        _go(0);
        openTxnEditor(context, draft: w.categoryId == null ? null : w.draft(state.baseCurrency));
      case 'overview_calendar':
        state.setOverviewView('calendar');
        _go(1);
      case 'analytics':
        _go(2);
      default:
        _go(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FadeTransition(
        opacity: _opacity,
        child: IndexedStack(
          index: _tab,
          children: const [HomeScreen(), OverviewScreen(), AnalyticsScreen(), MoneyScreen(), SettingsScreen()],
        ),
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: Ledger.inkOf(context))),
        ),
        child: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: _go,
          destinations: [
            for (final (glyph, label) in [
              (LedgerGlyph.home, 'nav_home'),
              (LedgerGlyph.overview, 'nav_overview'),
              (LedgerGlyph.analytics, 'nav_analytics'),
              (LedgerGlyph.money, 'nav_money'),
              (LedgerGlyph.settings, 'nav_settings'),
            ])
              NavigationDestination(
                icon: LedgerIcon(glyph),
                selectedIcon: LedgerIcon(glyph, selected: true),
                label: tr(label),
              ),
          ],
        ),
      ),
    );
  }
}
