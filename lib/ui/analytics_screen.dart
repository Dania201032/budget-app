import 'dart:math' as math;
import 'dart:ui' as ui show TextDirection;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../domain/money.dart';
import '../domain/periods.dart';
import '../domain/runway.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'ledger.dart';
import 'motion.dart';
import 'runway_settings_screen.dart';
import 'widgets.dart';

/// Chart colors: validated categorical slots (light/dark steps), never status colors.
/// Categories always use their own color, so a category looks the same everywhere in the app.
class ChartColors {
  final Color series1; // blue: spending, balance
  final Color series2; // orange: expenses in income-vs-expenses
  final Color series3; // aqua: income
  final Color muted; // budget pace, reserve, grid
  const ChartColors(this.series1, this.series2, this.series3, this.muted);

  static ChartColors of(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final muted = Theme.of(context).colorScheme.outline;
    // Ledger palette: emerald ink, ochre, sea green (dark: mint, warm yellow, sea green).
    return dark
        ? ChartColors(const Color(0xFF7FD1AE), const Color(0xFFE0A93A), const Color(0xFF4F9E86), muted)
        : ChartColors(const Color(0xFF0E3B34), const Color(0xFFD08E1F), const Color(0xFF3E9A78), muted);
  }
}

const analyticsCharts = ['runway', 'categories', 'daily', 'cumulative', 'months', 'payees'];

class AnalyticsScreen extends StatelessWidget {
  const AnalyticsScreen({super.key});

  Future<void> _chooseCharts(BuildContext context) async {
    final state = context.read<AppState>();
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (c) => StatefulBuilder(
        builder: (c, setState) => SafeArea(
          child: ListView(shrinkWrap: true, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(tr('charts_shown'), style: Theme.of(c).textTheme.titleLarge),
            ),
            for (final id in analyticsCharts)
              CheckboxListTile(
                value: !state.hiddenCharts.contains(id),
                title: Text(tr('chart_$id')),
                onChanged: (v) async {
                  await state.setChartVisible(id, v ?? true);
                  setState(() {});
                },
              ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final stats = state.analyticsStats;
    if (stats == null) return const Center(child: CircularProgressIndicator());
    final period = state.analyticsPeriod;
    bool shown(String id) => !state.hiddenCharts.contains(id);
    final hasBuckets = period.type != PeriodType.day;

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('nav_analytics')),
        actions: [
          IconButton(icon: const Icon(Icons.tune), tooltip: tr('charts_shown'), onPressed: () => _chooseCharts(context)),
        ],
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        if (shown('runway')) const RunwayCard(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
          child: PeriodSwitcher(period: period, onChanged: state.setAnalyticsPeriod),
        ),
        Container(
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Ledger.inkOf(context)))),
          child: PeriodTabs(selected: period.type, onChanged: state.setAnalyticsPeriodType),
        ),
        if (shown('categories')) _CategoriesDonut(stats: stats),
        if (shown('daily') && hasBuckets) _BucketBars(stats: stats),
        if (shown('cumulative') && hasBuckets && state.budgetEnabled) _CumulativeLine(stats: stats),
        if (shown('months')) const _MonthsBars(),
        if (shown('payees')) const _TopPayees(),
      ]),
    );
  }
}

class _ChartCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  const _ChartCard({required this.title, this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        LedgerSection(title, padding: EdgeInsets.zero),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(subtitle!, style: theme.textTheme.bodySmall?.copyWith(color: Ledger.mutedOf(context))),
          ),
        const SizedBox(height: 12),
        child,
      ]),
    );
  }
}

/// Compact axis labels: 1 234 567 -> "1,2 млн"-like short form via intl compact.
String _compact(double minor) => NumberFormat.compact(locale: intlLocale).format(minor / 100);

/// A money axis with a round step (1, 2, 2.5 or 5 × 10ⁿ) whose ends are whole steps: fl_chart always
/// labels the min and the max, so off-grid ends ("17,1 тыс." next to "10 тыс.") collide with their
/// neighbours. Labels never wrap; the label column is as wide as the widest one.
class _ValueAxis {
  final double min;
  final double max;
  final double step;
  const _ValueAxis._(this.min, this.max, this.step);

  /// [lo]..[hi] in minor units, with a little headroom above.
  factory _ValueAxis.of(double lo, double hi, {int ticks = 4}) {
    hi = hi > 0 ? hi * 1.05 : hi;
    if (hi - lo < 100) hi = lo + 100;
    final raw = (hi - lo) / ticks;
    final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    final norm = raw / mag;
    final nice = norm <= 1 ? 1.0 : (norm <= 2 ? 2.0 : (norm <= 2.5 ? 2.5 : (norm <= 5 ? 5.0 : 10.0)));
    final step = nice * mag;
    return _ValueAxis._((lo / step).floor() * step, (hi / step).ceil() * step, step);
  }

  Iterable<double> get ticks sync* {
    for (var v = min; v <= max + step / 1000; v += step) {
      yield v;
    }
  }

  FlGridData grid(BuildContext c) => FlGridData(
        drawVerticalLine: false,
        horizontalInterval: step,
        getDrawingHorizontalLine: (_) => _grid(c),
      );

  AxisTitles titles(TextStyle style) {
    var width = 0.0;
    for (final v in ticks) {
      final tp = TextPainter(text: TextSpan(text: _compact(v), style: style), textDirection: ui.TextDirection.ltr)..layout();
      width = math.max(width, tp.width);
    }
    return AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        interval: step,
        reservedSize: width + 8,
        getTitlesWidget: (v, meta) {
          // Only grid values (fl_chart may also pass a rounding leftover near the ends).
          if (((v - min) / step - ((v - min) / step).round()).abs() > 0.01) return const SizedBox.shrink();
          return SideTitleWidget(
            meta: meta,
            space: 6,
            child: Text(_compact(v), style: style, maxLines: 1, softWrap: false),
          );
        },
      ),
    );
  }
}

/// A bottom label kept inside the chart: the first and last ones don't slide under the value
/// labels or past the right edge.
Widget _bottomLabel(TitleMeta meta, String text, TextStyle style) => SideTitleWidget(
      meta: meta,
      fitInside: SideTitleFitInsideData.fromTitleMeta(meta),
      child: Text(text, style: style, maxLines: 1, softWrap: false),
    );

/// Bottom labels at a fixed [interval]; the extra one fl_chart adds at the very end is dropped when it
/// would sit right next to the previous one ("13 окт" over "14 окт").
bool _offInterval(double v, TitleMeta meta, double interval) =>
    v == meta.max && (v - meta.min) % interval > interval * 0.01 && (v - meta.min) % interval < interval * 0.6;

Widget _legendDot(Color c, String label, BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 10, height: 10, color: c),
      const SizedBox(width: 6),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ]);

FlLine _grid(BuildContext c) => FlLine(color: Ledger.ruleOf(c), strokeWidth: 1, dashArray: [3, 3]);
TextStyle _axis(BuildContext c) => mono(size: 10, weight: FontWeight.w400, color: Ledger.mutedOf(c));
FlBorderData _baseline(BuildContext c) => FlBorderData(show: true, border: Border(bottom: BorderSide(color: Ledger.inkOf(c))));
TextStyle _tip(BuildContext c) => mono(size: 12, color: Theme.of(c).colorScheme.surface);

// --- Runway ---

class RunwayCard extends StatefulWidget {
  const RunwayCard({super.key});

  @override
  State<RunwayCard> createState() => _RunwayCardState();
}

class _RunwayCardState extends State<RunwayCard> {
  static const _scenarioPercents = [0, -10, -20];
  Future<RunwayResult>? _future;
  Future<List<RunwayResult>>? _scenarios;
  Object? _key;

  /// "As now / 10% less / 20% less" with the spending per day and the date the money runs out.
  Widget _scenarioTable(BuildContext context, String cur, int current) => FutureBuilder<List<RunwayResult>>(
        future: _scenarios,
        builder: (context, snap) {
          final list = snap.data;
          if (list == null) return const SizedBox.shrink();
          final now = DateTime.now();
          String until(RunwayResult r) {
            final d = r.daysLeft(now);
            if (r.runsOutOn == null) return '∞';
            if (d != null && d <= 0) return '—';
            return DateFormat('dd.MM.yy', intlLocale).format(r.runsOutOn!);
          }

          return Container(
            margin: const EdgeInsets.only(top: 10),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: Ledger.inkOf(context)))),
            child: Column(children: [
              for (var i = 0; i < list.length; i++)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Ledger.ruleOf(context)))),
                  child: Row(children: [
                    Expanded(
                      child: Text(
                        _scenarioPercents[i] == 0 ? tr('scenario_now') : tr('scenario_less', [-_scenarioPercents[i]]),
                        style: TextStyle(fontWeight: _scenarioPercents[i] == current ? FontWeight.w600 : FontWeight.w400),
                      ),
                    ),
                    Text(tr('per_day_short', [formatAmount(list[i].spendPerDay.round(), pattern: '#,##0')]),
                        style: mono(size: 12.5, weight: FontWeight.w400, color: Ledger.mutedOf(context))),
                    SizedBox(width: 92, child: Text(until(list[i]), textAlign: TextAlign.end, style: mono(size: 14))),
                  ]),
                ),
            ]),
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final colors = ChartColors.of(context);
    final cfg = state.runwayConfig;
    final cur = state.baseCurrency;
    // Recompute when settings or data change.
    final key = Object.hash(cfg.toJsonString(), state.balances.toString(), state.goals.length, state.todayStats?.spentMinor,
        state.baseCurrency, state.homeTxns.length);
    if (key != _key) {
      _key = key;
      _future = state.computeRunwayFor(cfg);
      _scenarios = Future.wait([for (final p in _scenarioPercents) state.computeRunwayFor(cfg.copyWith(adjustPercent: p))]);
    }

    return Container(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Ledger.ruleOf(context)))),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: FutureBuilder<RunwayResult>(
          future: _future,
          builder: (context, snap) {
            final r = snap.data;
            if (r == null) return const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()));
            final now = DateTime.now();
            final days = r.daysLeft(now);
            final noMoney = state.accountsWithBalance.isEmpty && cfg.extraMinor == 0 && !cfg.includeGoalSavings;
            final headline = r.runsOutOn == null
                ? tr('runway_forever', [maxYears])
                : days! <= 0
                    ? tr('runway_now')
                    : tr('runway_until', [DateFormat.yMMMMd(intlLocale).format(r.runsOutOn!)]);

            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: LedgerCaption(tr('chart_runway'))),
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: tr('runway_settings'),
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RunwaySettingsScreen())),
                ),
              ]),
              if (noMoney)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(tr('runway_no_balance'), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
                ),
              Text(headline,
                  style: mono(
                    size: 24,
                    color: (days != null && days < 30) ? Ledger.badOf(context) : Ledger.accentOf(context),
                    height: 1.2,
                  )),
              if (days != null && days > 0) Text(_durationText(days), style: theme.textTheme.bodyMedium),
              const SizedBox(height: 6),
              Text(
                tr('runway_inputs', [
                  formatMoney(r.startMinor, cur),
                  formatMoney(r.spendPerDay.round(), cur),
                  formatMoney(r.incomePerDay.round(), cur),
                  // Where the spending figure comes from (it differs from the home screen's average).
                  switch (cfg.spendMode) {
                    SpendMode.average => tr('runway_basis_avg', [cfg.averageDays]),
                    SpendMode.budget => tr('runway_basis_budget'),
                    SpendMode.custom => tr('runway_basis_custom'),
                  },
                ]),
                style: theme.textTheme.bodySmall?.copyWith(color: Ledger.mutedOf(context)),
              ),
              _scenarioTable(context, cur, cfg.adjustPercent),
              const SizedBox(height: 12),
              SizedBox(height: 180, child: _RunwayChart(result: r, reserve: cfg.reserveMinor, colors: colors)),
              const SizedBox(height: 4),
              Wrap(spacing: 12, children: [
                _legendDot(colors.series1, tr('runway_balance'), context),
                if (cfg.reserveMinor > 0) _legendDot(colors.muted, tr('runway_reserve'), context),
              ]),
              if (r.allowedPerDayForTarget != null) ...[
                const SizedBox(height: 12),
                Text(
                  tr('runway_target', [
                    DateFormat.yMMMMd(intlLocale).format(cfg.targetDate!),
                    formatMoney(math.max(0, r.allowedPerDayForTarget!).round(), cur),
                    formatMoney(r.spendPerDay.round(), cur),
                  ]),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: r.allowedPerDayForTarget! < r.spendPerDay ? theme.colorScheme.error : null,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                cfg.adjustPercent == 0
                    ? tr('runway_adjust_none')
                    : tr(cfg.adjustPercent < 0 ? 'runway_adjust_less' : 'runway_adjust_more', [cfg.adjustPercent.abs()]),
                style: theme.textTheme.bodySmall,
              ),
              Slider(
                value: cfg.adjustPercent.toDouble(),
                min: -50,
                max: 50,
                divisions: 20,
                label: '${cfg.adjustPercent > 0 ? '+' : ''}${cfg.adjustPercent}%',
                onChanged: (v) => state.saveRunwayConfig(cfg.copyWith(adjustPercent: v.round())),
              ),
            ]);
          },
        ),
      ),
    );
  }

  String _durationText(int days) {
    final months = days ~/ 30;
    final rest = days % 30;
    return months > 0 ? tr('runway_months_days', [months, rest]) : tr('runway_days', [days]);
  }
}

class _RunwayChart extends StatelessWidget {
  final RunwayResult result;
  final int reserve;
  final ChartColors colors;
  const _RunwayChart({required this.result, required this.reserve, required this.colors});

  @override
  Widget build(BuildContext context) {
    final pts = result.projection;
    if (pts.length < 2) return const SizedBox.shrink();
    final start = pts.first.day;
    // A point per 3 days keeps the line light on long horizons.
    final step = pts.length > 400 ? 7 : (pts.length > 120 ? 3 : 1);
    final spots = <FlSpot>[
      for (var i = 0; i < pts.length; i += step) FlSpot(i.toDouble(), pts[i].balanceMinor.toDouble()),
      FlSpot((pts.length - 1).toDouble(), pts.last.balanceMinor.toDouble()),
    ];
    final values = pts.map((p) => p.balanceMinor);
    final axis = _ValueAxis.of(
        math.min(0, values.reduce(math.min)).toDouble(), math.max(values.reduce(math.max), reserve).toDouble());
    final small = _axis(context);
    // Four dates: the end ones are pulled inside the chart, so five would touch.
    final dateInterval = math.max(1, (pts.length / 3).floorToDouble()).toDouble();

    return LineChart(LineChartData(
      minY: axis.min,
      maxY: axis.max,
      gridData: axis.grid(context),
      borderData: _baseline(context),
      extraLinesData: ExtraLinesData(horizontalLines: [
        HorizontalLine(y: 0, color: colors.muted.withValues(alpha: 0.6), strokeWidth: 1),
        if (reserve > 0) HorizontalLine(y: reserve.toDouble(), color: colors.muted, strokeWidth: 2, dashArray: [6, 4]),
      ]),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(),
        rightTitles: const AxisTitles(),
        leftTitles: axis.titles(small),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 22,
            interval: dateInterval,
            getTitlesWidget: (v, m) {
              if (_offInterval(v, m, dateInterval)) return const SizedBox.shrink();
              final d = start.add(Duration(days: v.round()));
              // From about a year on the same day-month repeats (18 окт. … 18 окт.): month and year.
              final fmt = pts.length > 300 ? DateFormat('LLL yyyy', intlLocale) : DateFormat.MMMd(intlLocale);
              return _bottomLabel(m, fmt.format(d), small);
            },
          ),
        ),
      ),
      lineTouchData: LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => Ledger.inkOf(context),
          getTooltipItems: (spots) => [
            for (final s in spots)
              LineTooltipItem(
                '${DateFormat.yMMMd(intlLocale).format(start.add(Duration(days: s.x.round())))}\n${formatMoney(s.y.round(), context.read<AppState>().baseCurrency)}',
                _tip(context),
              ),
          ],
        ),
      ),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          color: colors.series1,
          barWidth: 2,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(show: true, color: colors.series1.withValues(alpha: 0.12)),
        ),
      ],
    ), duration: motion(context, motionMedium), curve: motionCurve);
  }
}

// --- Categories donut ---

class _CategoriesDonut extends StatefulWidget {
  final PeriodStats stats;
  const _CategoriesDonut({required this.stats});

  @override
  State<_CategoriesDonut> createState() => _CategoriesDonutState();
}

class _CategoriesDonutState extends State<_CategoriesDonut> {
  int? _touched;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final stats = widget.stats;
    final cur = state.baseCurrency;
    final entries = stats.spentByCategory.entries.where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
    final total = stats.spentMinor;
    Color colorOf(int? id) => id == null ? theme.colorScheme.outline : Color(state.categoryById[id]?.color ?? 0xFF8A8F98);
    String nameOf(int? id) => id == null || state.categoryById[id] == null ? tr('no_category') : state.categoryName(state.categoryById[id]!);

    final selected = _touched != null && _touched! < entries.length ? _touched : null;
    final muted = Ledger.mutedOf(context);
    final maxValue = entries.isEmpty ? 1 : entries.first.value;

    return _ChartCard(
      title: tr('chart_categories'),
      child: entries.isEmpty
          ? Text(tr('no_expenses'))
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // The selected line (or the total) as one big figure.
              Text(selected == null ? tr('spent') : nameOf(entries[selected].key),
                  style: theme.textTheme.bodySmall?.copyWith(color: muted)),
              AnimatedMoney(selected == null ? total : entries[selected].value, cur, style: mono(size: 26)),
              const SizedBox(height: 8),
              // Shares as one strip, like a 100% stacked column of the sheet.
              SizedBox(
                height: 16,
                child: Row(children: [
                  for (var i = 0; i < entries.length; i++)
                    Expanded(
                      flex: math.max(1, (entries[i].value * 1000 / math.max(1, total)).round()),
                      child: Container(
                        margin: EdgeInsets.only(right: i == entries.length - 1 ? 0 : 1),
                        color: selected == null || selected == i
                            ? colorOf(entries[i].key)
                            : colorOf(entries[i].key).withValues(alpha: 0.25),
                      ),
                    ),
                ]),
              ),
              const SizedBox(height: 10),
              Container(height: 1, color: Ledger.inkOf(context)),
              for (var i = 0; i < entries.length; i++)
                InkWell(
                  onTap: () => setState(() => _touched = _touched == i ? null : i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    color: selected == i ? Ledger.shadeOf(context) : null,
                    child: Column(children: [
                      Row(children: [
                        Container(width: 10, height: 10, color: colorOf(entries[i].key)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(nameOf(entries[i].key),
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontWeight: selected == i ? FontWeight.w600 : FontWeight.w400)),
                        ),
                        Text(formatAmount(entries[i].value, pattern: '#,##0.00'), style: mono(size: 14)),
                        SizedBox(
                          width: 44,
                          child: Text('${total == 0 ? 0 : (entries[i].value * 100 / total).round()}%',
                              textAlign: TextAlign.end, style: mono(size: 12, weight: FontWeight.w400, color: muted)),
                        ),
                      ]),
                      const SizedBox(height: 3),
                      Padding(
                        padding: const EdgeInsets.only(left: 18, right: 44),
                        child: LedgerBar(value: entries[i].value / maxValue, color: colorOf(entries[i].key), height: 3),
                      ),
                    ]),
                  ),
                ),
            ]),
    );
  }
}

// --- Spending per bucket with the limit line ---

class _BucketBars extends StatelessWidget {
  final PeriodStats stats;
  const _BucketBars({required this.stats});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final colors = ChartColors.of(context);
    final period = stats.period;
    final buckets = period.buckets;
    final small = _axis(context);
    final limit = buckets.isEmpty ? 0 : stats.budgetByBucket.fold<int>(0, (a, b) => a + b) / buckets.length;
    final axis = _ValueAxis.of(0, math.max(stats.spentByBucket.fold<int>(0, math.max).toDouble(), limit.toDouble()));
    final cur = state.baseCurrency;
    final barWidth = buckets.length > 20 ? 6.0 : (buckets.length > 8 ? 12.0 : 18.0);

    return _ChartCard(
      title: tr(period.type == PeriodType.year ? 'chart_daily_year' : 'chart_daily'),
      subtitle: state.budgetEnabled ? tr('chart_daily_sub', [formatMoney(limit.round(), cur)]) : null,
      child: SizedBox(
        height: 200,
        child: BarChart(BarChartData(
          maxY: axis.max,
          gridData: axis.grid(context),
          borderData: _baseline(context),
          extraLinesData: ExtraLinesData(horizontalLines: [
            if (state.budgetEnabled && limit > 0)
              HorizontalLine(y: limit.toDouble(), color: Ledger.inkOf(context), strokeWidth: 1.5, dashArray: [5, 4]),
          ]),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: axis.titles(small),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 22,
                getTitlesWidget: (v, m) {
                  final i = v.round();
                  if (i < 0 || i >= buckets.length) return const SizedBox.shrink();
                  // Every 5th day on a month, every bucket otherwise.
                  if (period.type == PeriodType.month && (i + 1) % 5 != 0 && i != 0) return const SizedBox.shrink();
                  return _bottomLabel(m, period.type == PeriodType.month ? '${i + 1}' : period.bucketLabel(buckets[i]), small);
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => Ledger.inkOf(context),
              getTooltipItem: (group, gi, rod, ri) => BarTooltipItem(
                '${period.bucketLabel(buckets[group.x])}\n${formatMoney(rod.toY.round(), cur)}',
                _tip(context),
              ),
            ),
          ),
          barGroups: [
            for (var i = 0; i < buckets.length; i++)
              BarChartGroupData(x: i, barRods: [
                BarChartRodData(
                  toY: stats.spentByBucket[i].toDouble(),
                  color: state.budgetEnabled && stats.budgetByBucket[i] > 0 && stats.spentByBucket[i] > stats.budgetByBucket[i]
                      ? Ledger.yellow
                      : colors.series1,
                  width: barWidth,
                  borderRadius: BorderRadius.zero,
                ),
              ]),
          ],
        ), duration: motion(context, motionMedium), curve: motionCurve),
      ),
    );
  }
}

// --- Cumulative spending vs the budget pace ---

class _CumulativeLine extends StatelessWidget {
  final PeriodStats stats;
  const _CumulativeLine({required this.stats});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final colors = ChartColors.of(context);
    final period = stats.period;
    final buckets = period.buckets;
    final now = DateTime.now();
    final small = _axis(context);
    final cur = state.baseCurrency;

    var acc = 0.0, plan = 0.0;
    final spent = <FlSpot>[];
    final pace = <FlSpot>[];
    for (var i = 0; i < buckets.length; i++) {
      plan += stats.budgetByBucket[i];
      pace.add(FlSpot(i.toDouble(), plan));
      if (!buckets[i].isAfter(now)) {
        acc += stats.spentByBucket[i];
        spent.add(FlSpot(i.toDouble(), acc));
      }
    }
    final axis = _ValueAxis.of(0, math.max(plan, acc));
    final dayInterval = math.max(1, (buckets.length / 5).floorToDouble()).toDouble();

    return _ChartCard(
      title: tr('chart_cumulative'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          height: 180,
          child: LineChart(LineChartData(
            minY: axis.min,
            maxY: axis.max,
            gridData: axis.grid(context),
            borderData: _baseline(context),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(),
              rightTitles: const AxisTitles(),
              leftTitles: axis.titles(small),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 22,
                  interval: dayInterval,
                  getTitlesWidget: (v, m) {
                    if (_offInterval(v, m, dayInterval)) return const SizedBox.shrink();
                    final i = v.round();
                    if (i < 0 || i >= buckets.length) return const SizedBox.shrink();
                    return _bottomLabel(m, period.type == PeriodType.month ? '${i + 1}' : period.bucketLabel(buckets[i]), small);
                  },
                ),
              ),
            ),
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => Ledger.inkOf(context),
                getTooltipItems: (spots) => [
                  for (final s in spots)
                    LineTooltipItem(formatMoney(s.y.round(), cur), _tip(context)),
                ],
              ),
            ),
            lineBarsData: [
              LineChartBarData(spots: pace, color: colors.muted, barWidth: 2, dashArray: [6, 4], dotData: const FlDotData(show: false)),
              LineChartBarData(spots: spent, color: colors.series1, barWidth: 2, dotData: const FlDotData(show: false)),
            ],
          ), duration: motion(context, motionMedium), curve: motionCurve),
        ),
        const SizedBox(height: 6),
        Wrap(spacing: 12, children: [
          _legendDot(colors.series1, tr('legend_spent'), context),
          _legendDot(colors.muted, tr('legend_plan'), context),
        ]),
      ]),
    );
  }
}

// --- Income vs expenses, last 6 months ---

class _MonthsBars extends StatelessWidget {
  const _MonthsBars();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final colors = ChartColors.of(context);
    final data = state.monthlyTotals;
    final small = _axis(context);
    final cur = state.baseCurrency;
    final axis = _ValueAxis.of(0, data.fold<int>(0, (m, e) => math.max(m, math.max(e.$2, e.$3))).toDouble());

    return _ChartCard(
      title: tr('chart_months'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          height: 200,
          child: BarChart(BarChartData(
            maxY: axis.max,
            gridData: axis.grid(context),
            borderData: _baseline(context),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(),
              rightTitles: const AxisTitles(),
              leftTitles: axis.titles(small),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 22,
                  getTitlesWidget: (v, m) {
                    final i = v.round();
                    if (i < 0 || i >= data.length) return const SizedBox.shrink();
                    return _bottomLabel(m, DateFormat.LLL(intlLocale).format(data[i].$1), small);
                  },
                ),
              ),
            ),
            barTouchData: BarTouchData(
              touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => Ledger.inkOf(context),
                getTooltipItem: (group, gi, rod, ri) => BarTooltipItem(
                  '${ri == 0 ? tr('expenses') : tr('income')}\n${formatMoney(rod.toY.round(), cur)}',
                  _tip(context),
                ),
              ),
            ),
            barGroups: [
              for (var i = 0; i < data.length; i++)
                BarChartGroupData(x: i, barsSpace: 2, barRods: [
                  BarChartRodData(
                      toY: data[i].$2.toDouble(), color: colors.series2, width: 10,
                      borderRadius: BorderRadius.zero),
                  BarChartRodData(
                      toY: data[i].$3.toDouble(), color: colors.series3, width: 10,
                      borderRadius: BorderRadius.zero),
                ]),
            ],
          ), duration: motion(context, motionMedium), curve: motionCurve),
        ),
        const SizedBox(height: 6),
        Wrap(spacing: 12, children: [
          _legendDot(colors.series2, tr('expenses'), context),
          _legendDot(colors.series3, tr('income'), context),
        ]),
      ]),
    );
  }
}

// --- Top payees (bar list) ---

class _TopPayees extends StatelessWidget {
  const _TopPayees();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final colors = ChartColors.of(context);
    final theme = Theme.of(context);
    final list = state.topPayees;
    final max = list.isEmpty ? 1 : list.first.$2;
    return _ChartCard(
      title: tr('chart_payees'),
      child: list.isEmpty
          ? Text(tr('no_expenses'))
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (var i = 0; i < list.length; i++)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Ledger.ruleOf(context)))),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      SizedBox(
                        width: 24,
                        child: Text('${i + 1}', style: mono(size: 12, weight: FontWeight.w400, color: Ledger.mutedOf(context))),
                      ),
                      Expanded(child: Text(list[i].$1, overflow: TextOverflow.ellipsis)),
                      Text(formatAmount(list[i].$2, pattern: '#,##0.00'), style: mono(size: 14)),
                    ]),
                    const SizedBox(height: 3),
                    Padding(
                      padding: const EdgeInsets.only(left: 24),
                      child: LedgerBar(value: list[i].$2 / max, color: colors.series1, height: 3),
                    ),
                  ]),
                ),
              const SizedBox(height: 6),
              Text(tr('payees_hint'), style: theme.textTheme.bodySmall?.copyWith(color: Ledger.mutedOf(context))),
            ]),
    );
  }
}
