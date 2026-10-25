import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../domain/budget_math.dart';
import '../domain/money.dart';
import '../domain/periods.dart';
import '../domain/runway.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../ui/home_screen.dart' show BudgetScopeBar, editBudgetDialog;
import '../ui/ledger.dart';
import '../ui/motion.dart';
import '../ui/txn_editor.dart';
import 'kit.dart';
import 'charts.dart';
import 'shell.dart';

class SummaryPage extends StatelessWidget {
  const SummaryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final d = context.watch<DeskController>();
    final m = s.todayStats;
    final now = DateTime.now();
    return DeskPage(
      title: tr('d_nav_summary'),
      subtitle: tr('d_day_of', [DateFormat.MMMMEEEEd(intlLocale).format(now), now.day, DateTime(now.year, now.month + 1, 0).day]),
      actions: [
        DeskButton(tr('d_budget'), icon: Icons.edit_outlined, onTap: () => editBudgetDialog(context)),
        DeskButton(tr('d_operation'), primary: true, icon: Icons.add, shortcut: 'N', onTap: () => openTxnEditor(context)),
      ],
      children: [
        // Shared budget with own limits: whose budget the page shows.
        if (s.householdOn && s.household!.personalLimits)
          const Align(alignment: Alignment.centerLeft, child: SizedBox(width: 460, child: BudgetScopeBar())),
        if (m != null) _Kpis(m: m),
        SplitRow([
          (2, 560, _CumulativePanel(m: m)),
          (1, 330, const _CalendarPanel()),
        ]),
        SplitRow([
          (2, 560, const _CategoriesPanel()),
          (1, 330, _InsightsPanel(d: d)),
        ]),
        AutoGrid(minWidth: 300, children: const [_UpcomingPanel(), _GoalsPanel(), _IncomePanel()]),
      ],
    );
  }
}

class _Kpis extends StatelessWidget {
  final MonthStats m;
  const _Kpis({required this.m});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final d = context.watch<DeskController>();
    final base = s.baseCurrency;
    String money(num v) => formatMoney(v.round(), base);
    final hasBudget = m.budgetMinor > 0;
    final pct = hasBudget ? (m.spentMinor / m.budgetMinor * 100).round() : 0;
    final pace = (m.daysPassed / m.daysInMonth * 100).round();
    final now = DateTime.now();
    final holdings = d.profile.holdings.where((h) => h.counted).fold<int>(0, (t, h) => t + (s.toBaseAmount(h.signedMinor, h.currency, now) ?? 0));
    return AutoGrid(minWidth: 200, children: [
      Kpi(tr('d_spent_month'), money(m.spentMinor),
          note: hasBudget ? tr('d_spent_note', ['$pct%', money(m.budgetMinor), '$pace%']) : tr('d_no_budget')),
      Kpi(
        tr('d_per_day'),
        money(hasBudget ? m.perDayFromTomorrow : m.averagePerDay),
        accent: true,
        note: hasBudget
            ? tr('d_per_day_note', [money(m.remainingMinor), m.daysLeftAfterToday, money(m.spentTodayMinor)])
            : tr('d_avg_day'),
      ),
      Kpi(
        tr('d_forecast_eom'),
        money(m.forecastSpent),
        note: !hasBudget
            ? tr('d_at_pace')
            : m.forecastSpent <= m.budgetMinor
                ? tr('d_within', [money(m.budgetMinor - m.forecastSpent)])
                : tr('d_over_by', [money(m.forecastSpent - m.budgetMinor)]),
        valueColor: hasBudget && m.forecastSpent > m.budgetMinor ? warnOf(context) : null,
      ),
      Kpi(tr('d_all_money'), money(s.totalBalance + holdings),
          note: tr('d_in_accounts', [s.balances.length])),
      _RunwayKpi(),
    ]);
  }
}

class _RunwayKpi extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final d = context.watch<DeskController>();
    return Builder(
      builder: (context) {
        final RunwayResult? r = d.runway;
        String value = '…';
        String? note;
        Color? color;
        if (r != null) {
          if (r.runsOutOn == null) {
            value = tr('d_runway_long');
          } else {
            value = monthTitle(r.runsOutOn!);
            final months = (r.runsOutOn!.difference(DateTime.now()).inDays / 30.4).round();
            note = tr('d_runway_months', [months]);
            if (months < 6) color = warnOf(context);
          }
        }
        return Kpi(tr('d_lasts_until'), value,
            note: note == null ? tr('d_scenarios_link') : '$note · ${tr('d_scenarios_link')}',
            valueColor: color,
            onTap: () => d.go(DeskPages.forecast));
      },
    );
  }
}

class _CumulativePanel extends StatelessWidget {
  final MonthStats? m;
  const _CumulativePanel({required this.m});

  @override
  Widget build(BuildContext context) {
    final desk = context.watch<DeskController>();
    final d = desk.data;
    final s = context.watch<AppState>();
    final now = DateTime.now();
    final n = d.thisMonthDays.length;
    final today = now.day.clamp(1, n);
    final budget = (m?.budgetMinor ?? 0) / 100;
    double c = 0;
    final cum = <double?>[for (var i = 0; i < n; i++) i < today ? (c += d.thisMonthDays[i] / 100) : null];
    final spent = cum[today - 1] ?? 0;
    final avg = spent / today;
    final forecast = <double?>[for (var i = 0; i < n; i++) i < today - 1 ? null : spent + avg * (i - today + 1)];
    double p = 0;
    final prev = <double?>[for (var i = 0; i < n; i++) i < d.prevMonthDays.length ? (p += d.prevMonthDays[i] / 100) : null];
    String money(double v) => formatMoney((v * 100).round(), s.baseCurrency);
    return Panel(
      title: tr('d_cumulative'),
      subtitle: tr('d_chart_click_day'),
      child: DeskLineChart(
        height: 250,
        lines: [
          DLine(prev, const Color(0xFFABA597), tr('d_last_month'), width: 1.8),
          DLine(forecast, Ledger.accentOf(context), tr('d_forecast'), dashed: true),
          DLine(cum, Ledger.inkOf(context), tr('d_this_month'), width: 2.8, area: true),
        ],
        hLines: [if (budget > 0) (budget, warnColor, '${tr('d_budget')} ${money(budget)}')],
        xLabels: [for (var i = 1; i <= n; i++) '$i'],
        labelEvery: 5,
        format: money,
        xTitle: (i) => DateFormat.MMMMd(intlLocale).format(DateTime(now.year, now.month, i + 1)),
        onTap: (i) {
          if (i < today) desk.go(DeskPages.operations, filter: 'day:${DateFormat('yyyy-MM-dd').format(DateTime(now.year, now.month, i + 1))}');
        },
      ),
    );
  }
}

class _CalendarPanel extends StatelessWidget {
  const _CalendarPanel();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final d = context.watch<DeskController>().data;
    final now = DateTime.now();
    final first = DateTime(now.year, now.month);
    final n = DateTime(now.year, now.month + 1, 0).day;
    final limit = s.todayStats?.dailyLimit ?? 0;
    final lead = first.weekday - 1;
    final due = <int, List<String>>{};
    for (final r in s.recurring) {
      for (final o in r.occurrences(DateTime(now.year, now.month + 1, 0))) {
        if (o.month == now.month && o.year == now.year && o.day > now.day) {
          due.putIfAbsent(o.day, () => []).add(formatAmount(r.amountMinor, pattern: '#,##0'));
        }
      }
    }
    final within = d.thisMonthDays.take(now.day).where((v) => limit <= 0 || v <= limit).length;
    final weekdays = [for (var i = 0; i < 7; i++) DateFormat.E(intlLocale).format(DateTime(2024, 1, 1 + i))];
    return Panel(
      title: monthTitle(first),
      trailing: limit > 0 ? Text(tr('d_within_days', [within, now.day]), style: sans(context, size: 12.5, color: Ledger.mutedOf(context))) : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          for (final w in weekdays)
            Expanded(child: Text(w, textAlign: TextAlign.center, style: mono(size: 11, color: Ledger.mutedOf(context)))),
        ]),
        const SizedBox(height: 4),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          childAspectRatio: 1.05,
          children: [
            for (var i = 0; i < lead; i++) const SizedBox(),
            for (var day = 1; day <= n; day++) _dayCell(context, day, now.day, d.thisMonthDays[day - 1], limit, due[day]),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 14, runSpacing: 4, children: [
          _key(context, Ledger.withinOf(context), tr('d_cal_within')),
          _key(context, Ledger.overOf(context), tr('d_cal_over')),
          _key(context, null, tr('d_cal_ahead')),
        ]),
      ]),
    );
  }

  Widget _dayCell(BuildContext context, int day, int today, int spent, double limit, List<String>? due) {
    final past = day <= today;
    final over = limit > 0 && spent > limit;
    final now = DateTime.now();
    final date = DateTime(now.year, now.month, day);
    return Tooltip(
      message: past
          ? '${DateFormat.MMMMd(intlLocale).format(date)}: ${formatAmount(spent)} · ${tr('d_click_to_open')}'
          : (due?.join(', ') ?? ''),
      child: InkWell(
        borderRadius: BorderRadius.circular(5),
        onTap: past
            ? () => context.read<DeskController>().go(DeskPages.operations, filter: 'day:${DateFormat('yyyy-MM-dd').format(date)}')
            : null,
        child: AnimatedContainer(
        duration: motion(context, motionMedium),
        curve: motionCurve,
        padding: const EdgeInsets.fromLTRB(5, 3, 5, 3),
        decoration: BoxDecoration(
          color: past ? (over ? Ledger.overOf(context) : Ledger.withinOf(context)) : null,
          border: past
              ? (day == today ? Border.all(color: Ledger.accentOf(context), width: 2) : null)
              : Border.all(color: Ledger.ruleOf(context)),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('$day', style: mono(size: 10.5, color: Ledger.mutedOf(context))),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              past ? formatAmount(spent, pattern: '#,##0') : (due?.first ?? ''),
              style: mono(size: 11.5, weight: FontWeight.w500, color: past ? null : Ledger.mutedOf(context)),
            ),
          ),
        ]),
      ),
      ),
    );
  }

  Widget _key(BuildContext c, Color? color, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            border: color == null ? Border.all(color: Ledger.ruleOf(c)) : null,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: sans(c, size: 12, color: Ledger.mutedOf(c))),
      ]);
}

class _CategoriesPanel extends StatelessWidget {
  const _CategoriesPanel();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final desk = context.watch<DeskController>();
    final d = desk.data;
    final plan = desk.profile.categoryPlan;
    final now = DateTime.now();
    final n = DateTime(now.year, now.month + 1, 0).day;
    final pace = now.day / n;
    final ids = <int?>{
      ...d.spentByCategory.entries.where((e) => e.value[12] > 0 || e.value[11] > 0).map((e) => e.key),
      ...plan.keys,
    }.toList()
      ..sort((a, b) => (d.spentByCategory[b]?[12] ?? 0).compareTo(d.spentByCategory[a]?[12] ?? 0));
    String money(int v) => formatMoney(v, s.baseCurrency);
    return Panel(
      title: tr('d_categories_plan'),
      trailing: TextButton(onPressed: () => desk.go(DeskPages.forecast), child: Text(tr('d_edit_plan'))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TableHead([
          (tr('category'), 5, false),
          (tr('d_fact_plan'), 6, false),
          (tr('d_spent'), 3, true),
          (tr('d_plan'), 3, true),
          (tr('d_forecast'), 3, true),
          (tr('d_vs_last'), 3, true),
        ]),
        if (ids.isEmpty)
          Padding(padding: const EdgeInsets.all(16), child: Text(tr('d_nothing_yet'), style: sans(context, color: Ledger.mutedOf(context)))),
        for (final id in ids.take(14))
          () {
            final c = id == null ? null : s.categoryById[id];
            final spent = d.spentByCategory[id]?[12] ?? 0;
            final last = d.spentByCategory[id]?[11] ?? 0;
            final p = id == null ? 0 : plan[id] ?? 0;
            final fc = d.forecastOf(id, daysPassed: now.day, daysInMonth: n);
            final over = p > 0 && fc > p;
            final ratio = p > 0 ? spent / p : (s.todayStats?.spentMinor ?? 0) == 0 ? 0.0 : spent / s.todayStats!.spentMinor;
            final delta = last == 0 ? null : ((fc - last) / last * 100).round();
            return TableLine([
              (
                Row(children: [
                  Swatch(c == null ? Ledger.mutedOf(context) : Color(c.color)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(c == null ? tr('d_uncategorized') : s.categoryName(c), overflow: TextOverflow.ellipsis, style: sans(context, size: 13.5))),
                ]),
                5
              ),
              (
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Meter(ratio.toDouble(), marker: p > 0 ? pace : null, color: p > 0 && spent > p ? warnColor : (over ? goldColor : null)),
                ),
                6
              ),
              (numCell(context, money(spent)), 3),
              (numCell(context, p > 0 ? money(p) : '—', color: Ledger.mutedOf(context)), 3),
              (numCell(context, money(fc), color: over ? warnOf(context) : null, bold: over), 3),
              (numCell(context, delta == null ? '—' : '${delta > 0 ? '+' : ''}$delta%', color: Ledger.mutedOf(context)), 3),
            ], onTap: id == null ? null : () => desk.go(DeskPages.operations, filter: 'cat:$id'));
          }(),
        const SizedBox(height: 8),
        Text(tr('d_pace_hint', ['${(pace * 100).round()}%']), style: sans(context, size: 12, color: Ledger.mutedOf(context))),
      ]),
    );
  }
}

class _InsightsPanel extends StatelessWidget {
  final DeskController d;
  const _InsightsPanel({required this.d});

  @override
  Widget build(BuildContext context) {
    final list = d.data.insights.take(d.profile.hintsShown).toList();
    return Panel(
      title: tr('d_look_at'),
      subtitle: tr('d_look_at_sub', [d.profile.hintsShown]),
      trailing: TextButton(onPressed: () => d.go(DeskPages.settings), child: Text(tr('d_configure'))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(tr('d_all_calm'), style: sans(context, color: Ledger.mutedOf(context))),
          ),
        for (final i in list)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: Ledger.trackOf(context)))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: switch (i.tone) { 'bad' => warnColor, 'good' => Ledger.withinOf(context), _ => const Color(0xFFF2C14E) },
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Text(switch (i.tone) { 'bad' => '!', 'good' => '✓', _ => 'i' },
                    style: mono(size: 12, color: i.tone == 'bad' ? Colors.white : Ledger.ink)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(i.title, style: sans(context, size: 14, weight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text(i.body, style: sans(context, size: 13, color: Ledger.mutedOf(context))),
                  const SizedBox(height: 3),
                  Text(tr('d_rule_prefix', [i.rule]), style: mono(size: 11, color: Ledger.mutedOf(context))),
                  Row(children: [
                    if (i.page != null)
                      TextButton(onPressed: () => d.go(i.page!, filter: i.filter), child: Text(tr('d_open'))),
                    TextButton(
                      onPressed: () {
                        d.profile.hiddenHints.add(i.id);
                        d.saveProfile();
                      },
                      child: Text(tr('hide')),
                    ),
                  ]),
                ]),
              ),
            ]),
          ),
      ]),
    );
  }
}

class _UpcomingPanel extends StatelessWidget {
  const _UpcomingPanel();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final now = DateTime.now();
    final until = DateTime(now.year, now.month, now.day + 21);
    final items = <(DateTime, Recurring)>[
      for (final r in s.recurring.where((r) => r.kind == TxnKind.expense))
        for (final o in r.occurrences(until)) (o, r),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    return Panel(
      title: tr('d_upcoming'),
      trailing: TextButton(onPressed: () => context.read<DeskController>().go(DeskPages.forecast), child: Text(tr('d_all'))),
      child: Column(children: [
        if (items.isEmpty) Text(tr('d_no_upcoming'), style: sans(context, color: Ledger.mutedOf(context))),
        for (final (date, r) in items.take(6))
          LineItem('${DateFormat.MMMd(intlLocale).format(date)} · ${r.name}', '−${formatMoney(r.amountMinor, r.currency)}'),
      ]),
    );
  }
}

class _GoalsPanel extends StatelessWidget {
  const _GoalsPanel();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final now = DateTime.now();
    return Panel(
      title: tr('d_goals'),
      trailing: TextButton(onPressed: () => context.read<DeskController>().go(DeskPages.forecast), child: Text(tr('d_all'))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (s.goals.isEmpty) Text(tr('d_no_goals'), style: sans(context, color: Ledger.mutedOf(context))),
        for (final g in s.goals.take(4)) ...[
          Row(children: [
            Expanded(child: Text(g.name, style: sans(context, size: 13.5))),
            Text('${formatAmount(g.savedMinor, pattern: '#,##0')} / ${formatMoney(g.targetMinor, g.currency)}', style: mono(size: 12.5)),
          ]),
          const SizedBox(height: 4),
          Meter(g.progress, color: g.done ? Ledger.mint : null),
          Text(
            g.done
                ? tr('d_goal_done')
                : g.deadline == null
                    ? tr('d_goal_no_deadline')
                    : tr('d_goal_need', [formatMoney(g.monthlyNeed(now), g.currency), DateFormat.yMMMd(intlLocale).format(g.deadline!)]),
            style: sans(context, size: 12.5, color: Ledger.mutedOf(context)),
          ),
          const SizedBox(height: 12),
        ],
      ]),
    );
  }
}

class _IncomePanel extends StatelessWidget {
  const _IncomePanel();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final d = context.watch<DeskController>();
    final now = DateTime.now();
    final income = d.data.txns
        .where((t) => t.kind == TxnKind.income && !t.excluded && t.time.year == now.year && t.time.month == now.month)
        .toList()
      ..sort((a, b) => b.time.compareTo(a.time));
    final total = d.data.incomeByMonth[12];
    final spent = s.todayStats?.forecastSpent ?? 0;
    final expected = [
      for (final r in s.recurring.where((r) => r.kind == TxnKind.income))
        for (final o in r.occurrences(DateTime(now.year, now.month + 1, now.day))) (o, r),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    return Panel(
      title: tr('d_income_month'),
      trailing: TextButton(onPressed: () => d.go(DeskPages.income), child: Text(tr('d_all_income'))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Text('+${formatMoney(total, s.baseCurrency)}', style: mono(size: 22, weight: FontWeight.w600, color: Ledger.goodOf(context))),
          const SizedBox(width: 10),
          if (spent > 0)
            Flexible(
              child: Text(tr('d_covers', ['${(total / spent * 100).round()}%']),
                  style: sans(context, size: 12.5, color: Ledger.mutedOf(context))),
            ),
        ]),
        const SizedBox(height: 6),
        for (final t in income.take(4))
          LineItem(t.merchant ?? (t.categoryId == null ? tr('income_one') : s.categoryName(s.categoryById[t.categoryId]!)),
              '+${formatMoney(t.amountMinor, t.currency)}',
              sub: DateFormat.MMMd(intlLocale).format(t.time), color: Ledger.goodOf(context)),
        for (final (date, r) in expected.take(2))
          LineItem('${r.name} — ${tr('d_expected')}', '+${formatMoney(r.amountMinor, r.currency)}',
              sub: DateFormat.MMMd(intlLocale).format(date), color: Ledger.mutedOf(context)),
        if (income.isEmpty && expected.isEmpty) Text(tr('d_no_income_yet'), style: sans(context, color: Ledger.mutedOf(context))),
      ]),
    );
  }
}
