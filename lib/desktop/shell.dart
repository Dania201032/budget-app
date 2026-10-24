import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../domain/money.dart';
import '../domain/runway.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../ui/ledger.dart';
import '../ui/search_screen.dart';
import '../ui/txn_editor.dart';
import 'analytics_page.dart';
import 'desk_data.dart';
import 'documents_page.dart';
import 'excel_page.dart';
import 'forecast_page.dart';
import 'income_page.dart';
import 'kit.dart';
import 'operations_page.dart';
import 'profile.dart';
import 'settings_page.dart';
import 'summary_page.dart';
import 'taxes_page.dart';

/// Theme mode and text size chosen in the computer's settings (the app's MaterialApp listens).
final deskLook = ValueNotifier<(ThemeMode, double)>((ThemeMode.system, 1.0));

/// Pages of the computer version, in sidebar order; Excel opens from Documents.
abstract final class DeskPages {
  static const summary = 0, operations = 1, income = 2, analytics = 3, forecast = 4, taxes = 5, documents = 6;
  static const excel = 7, settings = 8;
}

/// State of the computer version: the profile, the folded data and which page is open.
class DeskController extends ChangeNotifier {
  final AppState state;
  DeskController(this.state);

  DeskProfile profile = DeskProfile();
  DeskData data = DeskData.empty();
  bool ready = false;
  int page = DeskPages.summary;

  /// What the Operations page should show when opened from elsewhere ('review', 'cat:12'…).
  String? opsFilter;
  Timer? _soon;
  bool _loading = false;
  bool _again = false;

  Future<void> init() async {
    profile = await DeskProfile.load(state.repo, country: state.country, baseCurrency: state.baseCurrency);
    _applyLook();
    await reload();
    ready = true;
    notifyListeners();
  }

  void _applyLook() {
    deskLook.value = (
      switch (profile.themeMode) { 'light' => ThemeMode.light, 'dark' => ThemeMode.dark, _ => ThemeMode.system },
      profile.textScale,
    );
  }

  /// Folds the data again (coalescing bursts of changes).
  Future<void> reload() async {
    if (_loading) {
      _again = true;
      return;
    }
    _loading = true;
    try {
      data = await DeskData.load(state, profile);
      runway = await state.computeRunwayFor(runwayConfig(withScenarios: true));
    } catch (e) {
      debugPrint('desk reload: $e');
    } finally {
      _loading = false;
    }
    notifyListeners();
    if (_again) {
      _again = false;
      await reload();
    }
  }

  void stateChanged() {
    _soon?.cancel();
    _soon = Timer(const Duration(milliseconds: 250), reload);
  }

  void go(int p, {String? filter}) {
    page = p;
    if (filter != null) opsFilter = filter;
    notifyListeners();
  }

  /// "How long the money lasts" with the enabled scenarios (the Summary and Forecast show it).
  RunwayResult? runway;

  /// Counted investments in the base currency (added to "All money" and the forecast).
  int countedHoldings() {
    final now = DateTime.now();
    return profile.holdings
        .where((h) => h.counted)
        .fold(0, (t, h) => t + (state.toBaseAmount(h.amountMinor, h.currency, now) ?? 0));
  }

  /// The user's forecast settings plus counted investments and, optionally, scenarios.
  RunwayConfig runwayConfig({bool withScenarios = false, Set<String>? only}) {
    final c = state.runwayConfig;
    final now = DateTime.now();
    final until = DateTime(now.year, now.month + c.horizonMonths + 1);
    final extra = <PlannedItem>[];
    if (withScenarios) {
      for (final sc in profile.scenarios) {
        if (only != null ? !only.contains(sc.id) : !sc.enabled) continue;
        if (!sc.monthly) {
          extra.add(PlannedItem(name: sc.name, amountMinor: sc.amountMinor, date: sc.from));
          continue;
        }
        for (var i = 0; sc.months == 0 || i < sc.months; i++) {
          final d = DateTime(sc.from.year, sc.from.month + i, sc.from.day);
          if (d.isAfter(until)) break;
          extra.add(PlannedItem(name: sc.name, amountMinor: sc.amountMinor, date: d));
        }
      }
    }
    return c.copyWith(extraMinor: c.extraMinor + countedHoldings(), planned: [...c.planned, ...extra]);
  }

  String? takeOpsFilter() {
    final f = opsFilter;
    opsFilter = null;
    return f;
  }

  Future<void> saveProfile({bool refold = true}) async {
    await profile.save(state.repo);
    _applyLook();
    notifyListeners();
    if (refold) await reload();
  }

  @override
  void dispose() {
    _soon?.cancel();
    super.dispose();
  }
}

class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key});
  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> with WidgetsBindingObserver {
  late final DeskController desk = DeskController(context.read<AppState>());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    desk.state.addListener(desk.stateChanged);
    HardwareKeyboard.instance.addHandler(_onKey);
    desk.init().then((_) {
      if (mounted) runAutoDocuments(context, desk);
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    desk.state.removeListener(desk.stateChanged);
    WidgetsBinding.instance.removeObserver(this);
    desk.dispose();
    super.dispose();
  }

  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState s) async {
    if (s == AppLifecycleState.resumed) {
      desk.state.foreground = true;
      await desk.state.refresh();
      await desk.state.syncNow();
    } else if (s == AppLifecycleState.inactive || s == AppLifecycleState.hidden) {
      desk.state.foreground = false;
      await desk.state.syncNow();
    }
  }

  bool _typing() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx != null && (ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null);
  }

  /// 1–7 pages, N new expense, I new income, / search, Ctrl+K commands; not while typing or
  /// while another screen is on top.
  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || !mounted) return false;
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (ctrl && e.logicalKey == LogicalKeyboardKey.keyK) {
      _palette();
      return true;
    }
    if (ctrl || HardwareKeyboard.instance.isAltPressed || _typing()) return false;
    final digits = [
      LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit3, LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5, LogicalKeyboardKey.digit6, LogicalKeyboardKey.digit7,
    ];
    final i = digits.indexOf(e.logicalKey);
    if (i >= 0) {
      desk.go(i);
      return true;
    }
    if (e.logicalKey == LogicalKeyboardKey.keyN) {
      openTxnEditor(context);
      return true;
    }
    if (e.logicalKey == LogicalKeyboardKey.keyI) {
      newIncome(context);
      return true;
    }
    if (e.logicalKey == LogicalKeyboardKey.slash) {
      openSearch(context);
      return true;
    }
    return false;
  }

  Future<void> _palette() async {
    final actions = <(String, String, VoidCallback)>[
      for (final (i, k) in _nav) (tr(k), tr('d_cmd_page'), () => desk.go(i)),
      (tr('d_new_expense'), 'N', () => openTxnEditor(context)),
      (tr('d_new_income'), 'I', () => newIncome(context)),
      (tr('d_search_ops'), '/', () => openSearch(context)),
      (tr('d_excel_title'), tr('d_cmd_page'), () => desk.go(DeskPages.excel)),
      (tr('settings'), tr('d_cmd_page'), () => desk.go(DeskPages.settings)),
      (tr('d_review_now'), tr('d_cmd_page'), () => desk.go(DeskPages.operations, filter: 'review')),
    ];
    final picked = await showDialog<VoidCallback>(context: context, builder: (_) => _Palette(actions));
    picked?.call();
  }

  static const _nav = [
    (DeskPages.summary, 'd_nav_summary'),
    (DeskPages.operations, 'd_nav_operations'),
    (DeskPages.income, 'd_nav_income'),
    (DeskPages.analytics, 'd_nav_analytics'),
    (DeskPages.forecast, 'd_nav_forecast'),
    (DeskPages.taxes, 'd_nav_taxes'),
    (DeskPages.documents, 'd_nav_documents'),
  ];

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: desk,
      child: Consumer<DeskController>(builder: (context, d, _) {
        final page = switch (d.page) {
          DeskPages.summary => const SummaryPage(),
          DeskPages.operations => const OperationsPage(),
          DeskPages.income => const IncomePage(),
          DeskPages.analytics => const AnalyticsPage(),
          DeskPages.forecast => const ForecastPage(),
          DeskPages.taxes => const TaxesPage(),
          DeskPages.documents => const DocumentsPage(),
          DeskPages.excel => const ExcelPage(),
          _ => const DeskSettingsPage(),
        };
        return Scaffold(
          body: LayoutBuilder(builder: (context, c) {
            final narrow = c.maxWidth < 900;
            final content = d.ready ? KeyedSubtree(key: ValueKey(d.page), child: page) : const Center(child: CircularProgressIndicator());
            if (narrow) {
              return Column(children: [
                _TopNav(nav: _nav, onPalette: _palette),
                Expanded(child: content),
              ]);
            }
            return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(width: 240, child: _Sidebar(nav: _nav, onPalette: _palette)),
              VerticalDivider(width: 1, thickness: 1, color: Ledger.inkOf(context)),
              Expanded(child: content),
            ]);
          }),
        );
      }),
    );
  }
}

/// A new income: the editor opened on the income side.
Future<void> newIncome(BuildContext context) {
  final s = context.read<AppState>();
  return openTxnEditor(context,
      draft: Txn(time: DateTime.now(), amountMinor: 0, currency: s.baseCurrency, kind: TxnKind.income));
}

class _Sidebar extends StatelessWidget {
  final List<(int, String)> nav;
  final VoidCallback onPalette;
  const _Sidebar({required this.nav, required this.onPalette});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final d = context.watch<DeskController>();
    final muted = Ledger.mutedOf(context);
    final active = d.page == DeskPages.excel ? DeskPages.documents : d.page;
    return Container(
      color: sidebarOf(context),
      child: ListView(padding: const EdgeInsets.fromLTRB(14, 20, 14, 16), children: [
        Row(children: [
          const SizedBox(width: 8),
          const AbacusMark(size: 30),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('d_app_name'), style: sans(context, size: 15, weight: FontWeight.w600)),
              Text(tr('d_app_sub'), style: mono(size: 11, color: muted)),
            ]),
          ),
        ]),
        const SizedBox(height: 18),
        InkWell(
          onTap: onPalette,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            constraints: const BoxConstraints(minHeight: 40),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              border: Border.all(color: Ledger.ruleOf(context)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(children: [
              Icon(Icons.search, size: 17, color: muted),
              const SizedBox(width: 8),
              Expanded(child: Text(tr('d_find_or_do'), style: sans(context, size: 13, color: muted))),
              const KeyCap('Ctrl K'),
            ]),
          ),
        ),
        const SizedBox(height: 18),
        for (final (i, key) in nav)
          _NavItem(
            label: tr(key),
            icon: _icons[i],
            selected: active == i,
            badge: i == DeskPages.operations && s.reviewQueue.isNotEmpty ? '${s.reviewQueue.length}' : null,
            keyCap: '${i + 1}',
            onTap: () => d.go(i),
          ),
        const SizedBox(height: 18),
        _Accounts(),
        const SizedBox(height: 18),
        Divider(color: Ledger.ruleOf(context), height: 1),
        const SizedBox(height: 10),
        SyncStatus(onTap: () => d.go(DeskPages.settings)),
        const SizedBox(height: 6),
        _NavItem(
          label: tr('settings'),
          icon: Icons.tune,
          selected: d.page == DeskPages.settings,
          onTap: () => d.go(DeskPages.settings),
        ),
      ]),
    );
  }

  static const _icons = [
    Icons.dashboard_outlined,
    Icons.format_list_bulleted,
    Icons.south_west,
    Icons.bar_chart,
    Icons.trending_up,
    Icons.percent,
    Icons.description_outlined,
  ];
}

/// "just now", "12 min ago", "today at 09:12", "yesterday at 18:40", "12 Oct, 18:40".
String whenText(DateTime t) {
  final now = DateTime.now();
  final m = now.difference(t).inMinutes;
  if (m < 1) return tr('d_just_now');
  if (m < 60) return tr('d_min_ago', [m]);
  final hm = DateFormat.Hm(intlLocale).format(t);
  final day = DateTime(t.year, t.month, t.day), today = DateTime(now.year, now.month, now.day);
  if (day == today) return tr('d_today_at', [hm]);
  if (day == today.subtract(const Duration(days: 1))) return tr('d_yesterday_at', [hm]);
  return '${(t.year == now.year ? DateFormat.MMMd(intlLocale) : DateFormat.yMMMd(intlLocale)).format(t)}, $hm';
}

/// Phone sync in the sidebar: when data really went back and forth (not when the folder was last
/// looked at), when the phone last left its changes, and errors. Refreshes itself as time passes.
class SyncStatus extends StatefulWidget {
  final VoidCallback? onTap;
  const SyncStatus({super.key, this.onTap});
  @override
  State<SyncStatus> createState() => _SyncStatusState();
}

class _SyncStatusState extends State<SyncStatus> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.read<AppState>().sync;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final muted = Ledger.mutedOf(context);
        final String line;
        String? second;
        var warn = false;
        if (!sync.enabled) {
          line = tr('d_sync_off');
        } else if (sync.busy) {
          line = tr('d_syncing');
        } else if (sync.lastError != null) {
          line = tr('d_sync_failed');
          warn = true;
        } else {
          line = sync.lastSync == null ? tr('d_sync_never') : tr('d_sync_ago', [whenText(sync.lastSync!)]);
        }
        if (sync.enabled && sync.otherDeviceSeen != null) second = tr('d_phone_seen', [whenText(sync.otherDeviceSeen!)]);
        final details = [
          if (sync.lastSync != null) tr('d_sync_ago', [whenText(sync.lastSync!)]),
          if (sync.otherDeviceSeen != null) tr('d_phone_seen', [whenText(sync.otherDeviceSeen!)]),
          if (sync.lastCheck != null) tr('d_sync_checked', [whenText(sync.lastCheck!)]),
          if (sync.lastError != null) sync.lastError!,
        ].join('\n');
        return Tooltip(
          message: details,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: sync.busy
                      ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.6, color: Ledger.accentOf(context)))
                      : Icon(warn ? Icons.sync_problem : Icons.smartphone, size: 16, color: warn ? warnOf(context) : Ledger.accentOf(context)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(line, style: sans(context, size: 12.5, color: warn ? warnOf(context) : muted)),
                    if (second != null) Text(second, style: sans(context, size: 11.5, color: muted)),
                  ]),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}

class _NavItem extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final String? badge;
  final String? keyCap;
  final VoidCallback onTap;
  const _NavItem({required this.label, required this.icon, required this.selected, this.badge, this.keyCap, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Ledger.paper : Ledger.inkOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? Ledger.emerald : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            constraints: const BoxConstraints(minHeight: 40),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 10),
              Expanded(child: Text(label, style: sans(context, size: 14, color: fg))),
              if (badge != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(color: const Color(0xFFF2C14E), borderRadius: BorderRadius.circular(10)),
                  child: Text(badge!, style: mono(size: 11, color: Ledger.ink)),
                )
              else if (keyCap != null)
                KeyCap(keyCap!, color: selected ? Ledger.paper : null),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Accounts extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final d = context.watch<DeskController>();
    final muted = Ledger.mutedOf(context);
    final now = DateTime.now();
    final list = s.accounts.where((a) => s.balances.containsKey(a.id)).toList();
    final counted = d.profile.holdings.where((h) => h.counted);
    final holdingsBase = counted.fold<int>(0, (t, h) => t + (s.toBaseAmount(h.amountMinor, h.currency, now) ?? 0));
    final foreign = {for (final a in list) a.currency}..remove(s.baseCurrency);
    String? rateLine;
    if (foreign.isNotEmpty) {
      final c = foreign.first;
      // One unit (100 minor units) of the base currency.
      final r = s.rates.convert(100, s.baseCurrency, c, now);
      if (r != null) rateLine = '1 ${s.baseCurrency} = ${formatAmount(r, pattern: '#,##0.00')} $c';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(tr('d_accounts').toUpperCase(), style: mono(size: 11, color: muted, spacing: .6))),
          if (rateLine != null) Text(rateLine, style: mono(size: 10.5, color: muted)),
        ]),
        const SizedBox(height: 6),
        if (list.isEmpty)
          Text(tr('d_no_balances'), style: sans(context, size: 12.5, color: muted))
        else
          for (final a in list)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Expanded(child: Text(s.accountName(a), overflow: TextOverflow.ellipsis, style: sans(context, size: 13.5))),
                Text(formatMoney(s.balances[a.id]!, a.currency), style: mono(size: 13)),
              ]),
            ),
        if (holdingsBase != 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Expanded(child: Text(tr('d_investments_short'), style: sans(context, size: 13.5))),
              Text(formatMoney(holdingsBase, s.baseCurrency), style: mono(size: 13)),
            ]),
          ),
        Container(
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.only(top: 8),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: Ledger.inkOf(context)))),
          child: Row(children: [
            Expanded(child: Text(tr('d_total'), style: sans(context, size: 13.5, weight: FontWeight.w600))),
            Text('≈ ${formatMoney(s.totalBalance + holdingsBase, s.baseCurrency)}', style: mono(size: 13, weight: FontWeight.w600)),
          ]),
        ),
      ]),
    );
  }
}

/// Narrow window: the sections as a scrolling strip on top.
class _TopNav extends StatelessWidget {
  final List<(int, String)> nav;
  final VoidCallback onPalette;
  const _TopNav({required this.nav, required this.onPalette});

  @override
  Widget build(BuildContext context) {
    final d = context.watch<DeskController>();
    return Container(
      color: sidebarOf(context),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          IconButton(onPressed: onPalette, icon: const Icon(Icons.search), tooltip: tr('d_find_or_do')),
          for (final (i, key) in nav) ...[
            const SizedBox(width: 6),
            Pill(tr(key), selected: d.page == i || (i == DeskPages.documents && d.page == DeskPages.excel), onTap: () => d.go(i)),
          ],
          const SizedBox(width: 6),
          Pill(tr('settings'), selected: d.page == DeskPages.settings, onTap: () => d.go(DeskPages.settings)),
        ]),
      ),
    );
  }
}

/// The abacus logo, drawn.
class AbacusMark extends StatelessWidget {
  final double size;
  const AbacusMark({super.key, this.size = 30});
  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _AbacusPainter());
}

class _AbacusPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 30;
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(7 * k)), Paint()..color = Ledger.emerald);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(6 * k, 6 * k, 18 * k, 18 * k), Radius.circular(2 * k)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6 * k
        ..color = const Color(0xFFF4EEDC),
    );
    final rod = Paint()
      ..strokeWidth = 1.2 * k
      ..color = const Color(0xFF4F9E86);
    canvas.drawLine(Offset(6 * k, 12 * k), Offset(24 * k, 12 * k), rod);
    canvas.drawLine(Offset(6 * k, 18 * k), Offset(24 * k, 18 * k), rod);
    canvas.drawCircle(Offset(11 * k, 12 * k), 2.2 * k, Paint()..color = const Color(0xFFF2C14E));
    canvas.drawCircle(Offset(17 * k, 18 * k), 2.2 * k, Paint()..color = Ledger.mint);
    canvas.drawCircle(Offset(21 * k, 18 * k), 2.2 * k, Paint()..color = Ledger.mint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _Palette extends StatefulWidget {
  final List<(String, String, VoidCallback)> actions;
  const _Palette(this.actions);
  @override
  State<_Palette> createState() => _PaletteState();
}

class _PaletteState extends State<_Palette> {
  String q = '';
  final search = TextEditingController();

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.actions.where((a) => a.$1.toLowerCase().contains(q.toLowerCase())).toList();
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.only(top: 80, left: 24, right: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 460),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: search,
              autofocus: true,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                suffixIcon: clearIcon(search, () => setState(() => q = '')),
                hintText: tr('d_find_or_do'),
              ),
              onChanged: (v) => setState(() => q = v),
              onSubmitted: (_) {
                if (list.isNotEmpty) Navigator.pop(context, list.first.$3);
              },
            ),
          ),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final (label, hint, act) in list)
                ListTile(
                  title: Text(label),
                  trailing: Text(hint, style: mono(size: 12, color: Ledger.mutedOf(context))),
                  onTap: () => Navigator.pop(context, act),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}
