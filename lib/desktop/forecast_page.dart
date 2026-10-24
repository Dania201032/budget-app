import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../domain/money.dart';
import '../domain/periods.dart';
import '../domain/runway.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../ui/ledger.dart';
import '../ui/money_screen.dart' show editGoal;
import '../ui/recurring_screen.dart' show editRecurring;
import '../ui/runway_settings_screen.dart';
import 'charts.dart';
import 'kit.dart';
import 'profile.dart';
import 'shell.dart';

class ForecastPage extends StatefulWidget {
  const ForecastPage({super.key});
  @override
  State<ForecastPage> createState() => _ForecastPageState();
}

class _ForecastPageState extends State<ForecastPage> {
  int horizon = 18;
  int targetMonths = 6;
  Object? _key;
  RunwayResult? withSc, without, target;
  Map<String, int?> impact = {};

  Future<void> _compute(DeskController desk, Object key) async {
    _key = key;
    final s = desk.state;
    RunwayConfig cfg(RunwayConfig c) => c.copyWith(horizonMonths: horizon);
    final a = await s.computeRunwayFor(cfg(desk.runwayConfig(withScenarios: true)));
    final b = await s.computeRunwayFor(cfg(desk.runwayConfig()));
    final now = DateTime.now();
    final t = await s.computeRunwayFor(cfg(desk.runwayConfig(withScenarios: true))
        .copyWith(targetDate: () => DateTime(now.year, now.month + targetMonths, now.day)));
    final enabled = {for (final sc in desk.profile.scenarios.where((x) => x.enabled)) sc.id};
    final imp = <String, int?>{};
    for (final sc in desk.profile.scenarios) {
      final flipped = sc.enabled ? ({...enabled}..remove(sc.id)) : {...enabled, sc.id};
      final r = await s.computeRunwayFor(cfg(desk.runwayConfig(withScenarios: true, only: flipped)));
      imp[sc.id] = _monthsBetween(a.runsOutOn, r.runsOutOn);
    }
    if (!mounted || _key != key) return;
    setState(() {
      withSc = a;
      without = b;
      target = t;
      impact = imp;
    });
  }

  /// Months gained (+) or lost (−) when the run-out date moves from [a] to [b]; null = beyond the horizon both times.
  int? _monthsBetween(DateTime? a, DateTime? b) {
    if (a == null && b == null) return null;
    final far = DateTime.now().add(Duration(days: horizon * 31));
    return (((b ?? far).difference(a ?? far).inDays) / 30.4).round();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final desk = context.watch<DeskController>();
    final key = (desk.data, horizon, targetMonths, [for (final sc in desk.profile.scenarios) '${sc.id}${sc.enabled}${sc.amountMinor}'].join(), s.runwayConfig);
    if (_key != key) _compute(desk, key);
    final base = s.baseCurrency;
    String money(num v) => formatMoney(v.round(), base);
    final r = withSc;
    final reserve = s.runwayConfig.reserveMinor;
    final now = DateTime.now();
    int? at(RunwayResult? x, DateTime d) => x?.projection.where((p) => !p.day.isBefore(d)).firstOrNull?.balanceMinor;
    final yearOn = at(r, DateTime(now.year + 1, now.month, now.day));
    final yearOnPlan = at(without, DateTime(now.year + 1, now.month, now.day));

    return DeskPage(
      title: tr('d_nav_forecast'),
      subtitle: r == null
          ? null
          : tr('d_forecast_sub', [money(r.spendPerDay * 30.4), money(r.incomePerDay * 30.4)]),
      actions: [
        Seg(options: [(6, tr('d_6m')), (12, tr('d_1y')), (18, tr('d_18m'))], value: horizon, onChanged: (v) => setState(() => horizon = v)),
        DeskButton(tr('d_assumptions'), onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RunwaySettingsScreen()))),
      ],
      children: [
        SplitRow([
          (
            2,
            600,
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                AutoGrid(minWidth: 160, children: [
                  _big(context, tr('d_lasts_until'), r == null ? '…' : (r.runsOutOn == null ? tr('d_runway_long') : monthTitle(r.runsOutOn!)),
                      r?.runsOutOn == null ? tr('d_whole_horizon') : tr('d_then_minus'),
                      warn: r?.runsOutOn != null && r!.runsOutOn!.difference(now).inDays < 200),
                  _big(context, tr('d_reserve'), money(reserve), reserve == 0 ? tr('d_reserve_none') : tr('d_reserve_note')),
                  _big(context, tr('d_in_a_year'), yearOn == null ? '—' : money(yearOn),
                      yearOn == null || yearOnPlan == null ? '' : tr(yearOn >= yearOnPlan ? 'd_more_than_plan' : 'd_less_than_plan', [money((yearOn - yearOnPlan).abs())])),
                ]),
                const SizedBox(height: 12),
                Wrap(spacing: 16, runSpacing: 4, children: [
                  _legend(context, Ledger.inkOf(context), tr('d_with_scenarios')),
                  _legend(context, const Color(0xFFABA597), tr('d_as_planned'), dashed: true),
                  if (reserve > 0) _legend(context, warnColor, tr('d_reserve'), dashed: true),
                ]),
                const SizedBox(height: 8),
                if (r == null || r.projection.isEmpty)
                  const SizedBox(height: 280, child: Center(child: CircularProgressIndicator()))
                else
                  _balanceChart(context, r, without, reserve, money),
              ]),
            ),
          ),
          (1, 340, _Scenarios(impact: impact)),
        ]),
        SplitRow([
          (1, 340, _CanSpend(result: target, months: targetMonths, onMonths: (v) => setState(() => targetMonths = v))),
          (2, 560, const _Plan()),
        ]),
        AutoGrid(minWidth: 320, children: const [_Goals(), _Recurring(), _Method()]),
      ],
    );
  }

  /// Weekly samples of both projections on one interactive line chart.
  Widget _balanceChart(BuildContext context, RunwayResult r, RunwayResult? plan, int reserve, String Function(num) money) {
    final start = r.projection.first.day, end = r.projection.last.day;
    final days = <DateTime>[for (var d = start; !d.isAfter(end); d = d.add(const Duration(days: 7))) d];
    double? at(List<RunwayPoint> pts, DateTime d) =>
        ((pts.where((p) => !p.day.isBefore(d)).firstOrNull ?? (pts.isEmpty ? null : pts.last))?.balanceMinor ?? 0) / 100;
    final runsOut = r.runsOutOn;
    return DeskLineChart(
      height: 280,
      lines: [
        if (plan != null) DLine([for (final d in days) at(plan.projection, d)], const Color(0xFFABA597), tr('d_as_planned'), dashed: true, width: 2),
        DLine([for (final d in days) at(r.projection, d)], Ledger.inkOf(context), tr('d_with_scenarios'), area: true, width: 2.6),
      ],
      xLabels: [for (final d in days) DateFormat.MMM(intlLocale).format(d)],
      labelEvery: math.max(1, days.length ~/ 6),
      xTitle: (i) {
        final d = days[i];
        final note = runsOut != null && !d.isBefore(runsOut) ? '  · ${tr('d_reserve')} ↓' : '';
        return '${DateFormat.yMMMd(intlLocale).format(d)}$note';
      },
      format: (v) => money(v * 100),
      hLines: [if (reserve > 0) (reserve / 100, warnColor, tr('d_reserve'))],
    );
  }

  Widget _big(BuildContext c, String label, String value, String note, {bool warn = false}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: sans(c, size: 12.5, color: Ledger.mutedOf(c))),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: mono(size: 24, weight: FontWeight.w600, color: warn ? warnOf(c) : null)),
          ),
          Text(note, style: sans(c, size: 12, color: Ledger.mutedOf(c))),
        ],
      );

  Widget _legend(BuildContext c, Color color, String label, {bool dashed = false}) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 16, height: dashed ? 2 : 3, color: color),
        const SizedBox(width: 6),
        Text(label, style: sans(c, size: 12.5)),
      ]);
}

class _Scenarios extends StatelessWidget {
  final Map<String, int?> impact;
  const _Scenarios({required this.impact});

  @override
  Widget build(BuildContext context) {
    final desk = context.watch<DeskController>();
    final list = desk.profile.scenarios;
    return Panel(
      title: tr('d_what_if'),
      trailing: TextButton(onPressed: () => _edit(context, desk), child: Text(tr('d_new'))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (list.isEmpty) ...[
          Text(tr('d_no_scenarios'), style: sans(context, size: 13, color: Ledger.mutedOf(context))),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final (key, sign, monthly) in [('d_tpl_trip', -1, false), ('d_tpl_extra', 1, true), ('d_tpl_purchase', -1, false), ('d_tpl_cut', 1, true)])
              Pill(tr(key), dashed: true, onTap: () => _edit(context, desk, template: (tr(key), sign, monthly))),
          ]),
        ],
        for (final sc in list)
          InkWell(
            onTap: () {
              final i = list.indexOf(sc);
              list[i] = sc.toggled();
              desk.saveProfile(refold: false);
            },
            onLongPress: () => _edit(context, desk, sc: sc),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(border: Border(top: BorderSide(color: Ledger.trackOf(context)))),
              child: Row(children: [
                Toggle(sc.enabled, onChanged: (_) {
                  final i = list.indexOf(sc);
                  list[i] = sc.toggled();
                  desk.saveProfile(refold: false);
                }),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(sc.name, style: sans(context, size: 14, weight: FontWeight.w500)),
                    Text(
                      '${formatMoney(sc.amountMinor, desk.state.baseCurrency, signed: true)} · '
                      '${sc.monthly ? tr('d_monthly_from', [DateFormat.yMMM(intlLocale).format(sc.from)]) : DateFormat.yMMMd(intlLocale).format(sc.from)}',
                      style: sans(context, size: 12.5, color: Ledger.mutedOf(context)),
                    ),
                  ]),
                ),
                () {
                  final m = impact[sc.id];
                  return Text(m == null ? '±0' : '${m > 0 ? '+' : m < 0 ? '−' : '±'}${m.abs()} ${tr('d_mo')}',
                      style: mono(size: 12.5, weight: FontWeight.w600, color: (m ?? 0) > 0 ? Ledger.goodOf(context) : (m ?? 0) < 0 ? warnOf(context) : Ledger.mutedOf(context)));
                }(),
                IconButton(tooltip: tr('d_edit'), icon: const Icon(Icons.edit_outlined, size: 18), onPressed: () => _edit(context, desk, sc: sc)),
              ]),
            ),
          ),
        const SizedBox(height: 8),
        Text(tr('d_impact_note'), style: sans(context, size: 12, color: Ledger.mutedOf(context))),
      ]),
    );
  }

  static Future<void> _edit(BuildContext context, DeskController desk, {Scenario? sc, (String, int, bool)? template}) async {
    final r = await showDialog<(Scenario?, bool)>(
      context: context,
      builder: (_) => _ScenarioDialog(sc: sc, template: template, currency: desk.state.baseCurrency),
    );
    if (r == null) return;
    final (result, delete) = r;
    final list = desk.profile.scenarios;
    if (delete && sc != null) {
      list.removeWhere((x) => x.id == sc.id);
    } else if (result != null) {
      final i = list.indexWhere((x) => x.id == result.id);
      i >= 0 ? list[i] = result : list.add(result);
    }
    await desk.saveProfile(refold: false);
  }
}

class _ScenarioDialog extends StatefulWidget {
  final Scenario? sc;
  final (String, int, bool)? template;
  final String currency;
  const _ScenarioDialog({this.sc, this.template, required this.currency});
  @override
  State<_ScenarioDialog> createState() => _ScenarioDialogState();
}

class _ScenarioDialogState extends State<_ScenarioDialog> {
  late final name = TextEditingController(text: widget.sc?.name ?? widget.template?.$1 ?? '');
  late final amount = TextEditingController(text: widget.sc == null ? '' : formatAmount(widget.sc!.amountMinor.abs(), pattern: '0.##'));
  late final months = TextEditingController(text: widget.sc == null || widget.sc!.months == 0 ? '' : '${widget.sc!.months}');
  late bool income = (widget.sc?.amountMinor ?? widget.template?.$2 ?? -1) > 0;
  late bool monthly = widget.sc?.monthly ?? widget.template?.$3 ?? false;
  late DateTime from = widget.sc?.from ?? DateTime(DateTime.now().year, DateTime.now().month + 1, 1);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.sc == null ? tr('d_new_scenario') : widget.sc!.name),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          FieldBox(tr('name'), name, numeric: false),
          const SizedBox(height: 10),
          Choice(options: [(false, tr('d_sc_expense')), (true, tr('d_sc_income'))], value: income, onChanged: (v) => setState(() => income = v)),
          const SizedBox(height: 10),
          FieldBox(tr('col_amount'), amount, suffix: widget.currency),
          const SizedBox(height: 10),
          Choice(options: [(false, tr('d_sc_once')), (true, tr('d_sc_monthly'))], value: monthly, onChanged: (v) => setState(() => monthly = v)),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: () async {
              final d = await showDatePicker(context: context, initialDate: from, firstDate: DateTime(2020), lastDate: DateTime(2100));
              if (d != null) setState(() => from = d);
            },
            child: Text('${monthly ? tr('d_sc_from') : tr('d_sc_when')}: ${DateFormat.yMMMd(intlLocale).format(from)}'),
          ),
          if (monthly) ...[const SizedBox(height: 10), FieldBox(tr('d_sc_months'), months, hint: tr('d_sc_months_hint'))],
        ]),
      ),
      actions: [
        if (widget.sc != null) TextButton(onPressed: () => Navigator.pop(context, (null, true)), child: Text(tr('delete'))),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('cancel'))),
        FilledButton(
          onPressed: () {
            final a = parseNum(amount.text);
            if (a == null || name.text.trim().isEmpty) return;
            Navigator.pop(context, (
              Scenario(
                id: widget.sc?.id ?? '${DateTime.now().microsecondsSinceEpoch}',
                name: name.text.trim(),
                amountMinor: (a * 100).round() * (income ? 1 : -1),
                monthly: monthly,
                from: from,
                months: int.tryParse(months.text.trim()) ?? 0,
                enabled: widget.sc?.enabled ?? true,
              ),
              false
            ));
          },
          child: Text(tr('save')),
        ),
      ],
    );
  }
}

class _CanSpend extends StatelessWidget {
  final RunwayResult? result;
  final int months;
  final ValueChanged<int> onMonths;
  const _CanSpend({required this.result, required this.months, required this.onMonths});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final perDay = result?.allowedPerDayForTarget;
    final perMonth = perDay == null ? null : perDay * 30.4;
    final now = DateTime.now();
    final until = DateTime(now.year, now.month + months, now.day);
    final current = (result?.spendPerDay ?? 0) * 30.4;
    return Panel(
      color: Ledger.emerald,
      borderColor: Ledger.emerald,
      title: tr('d_can_spend'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final m in [3, 6, 12])
            ChoiceChip(
              label: Text(tr('d_until', [DateFormat.yMMM(intlLocale).format(DateTime(now.year, now.month + m, now.day))])),
              selected: m == months,
              onSelected: (_) => onMonths(m),
            ),
        ]),
        const SizedBox(height: 12),
        Text(perMonth == null ? '…' : formatMoney(perMonth.round(), s.baseCurrency),
            style: mono(size: 32, weight: FontWeight.w600, color: Ledger.paper)),
        Text(tr('d_per_month_day', [perDay == null ? '…' : formatMoney(perDay.round(), s.baseCurrency)]),
            style: sans(context, size: 13, color: const Color(0xFFCFE6DC))),
        const SizedBox(height: 10),
        if (perMonth != null)
          Text(
            perMonth < current
                ? tr('d_can_spend_less', [DateFormat.yMMMd(intlLocale).format(until), formatMoney((current - perMonth).round(), s.baseCurrency)])
                : tr('d_can_spend_ok', [DateFormat.yMMMd(intlLocale).format(until)]),
            style: sans(context, size: 13, color: const Color(0xFFCFE6DC), height: 1.45),
          ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Ledger.mint, foregroundColor: Ledger.emerald),
            onPressed: perMonth == null ? null : () => s.setBudget(perMonth.round()),
            child: Text(tr('d_make_budget')),
          ),
        ),
      ]),
    );
  }
}

class _Plan extends StatefulWidget {
  const _Plan();
  @override
  State<_Plan> createState() => _PlanState();
}

class _PlanState extends State<_Plan> {
  final ctrl = <int, TextEditingController>{};

  @override
  void dispose() {
    for (final c in ctrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final desk = context.watch<DeskController>();
    final d = desk.data;
    final plan = desk.profile.categoryPlan;
    final cats = s.categoriesOf(TxnKind.expense);
    String money(int v) => formatMoney(v, s.baseCurrency);
    for (final c in cats) {
      ctrl.putIfAbsent(c.id, () => TextEditingController(text: plan[c.id] == null ? '' : formatAmount(plan[c.id]!, pattern: '0')));
    }
    final total = cats.fold<int>(0, (a, c) => a + (((parseNum(ctrl[c.id]!.text) ?? 0) * 100).round()));
    final now = DateTime.now();
    final next = DateTime(now.year, now.month + 1);
    // Usual month per category: the average of the last three months that had spending in it,
    // plus this month's pace once a third of it has passed.
    final passed = now.day, daysIn = DateTime(now.year, now.month + 1, 0).day;
    int typical(int id) {
      final list = d.spentByCategory[id];
      if (list == null) return 0;
      final v = [list[9], list[10], list[11], if (passed >= 10) d.forecastOf(id, daysPassed: passed, daysInMonth: daysIn)].where((x) => x > 0).toList();
      return v.isEmpty ? 0 : v.reduce((a, b) => a + b) ~/ v.length;
    }

    final usual = {for (final c in cats) c.id: typical(c.id)};
    final usualTotal = usual.values.fold<int>(0, (a, b) => a + b);
    final budget = s.monthBudget(next) > 0 ? s.monthBudget(next) : s.monthBudget(now);
    int nice(num v) {
      final step = v >= 1000000 ? 100000 : v >= 100000 ? 10000 : v >= 10000 ? 1000 : 100;
      return (v / step).round() * step;
    }

    // Null = not enough history for this category: the user fills it in.
    int? suggested(int id) {
      final u = usual[id] ?? 0;
      if (u == 0) return null;
      return nice(budget > 0 ? u * budget / usualTotal : u);
    }

    final how = usualTotal == 0
        ? tr('d_suggest_none')
        : budget > 0
            ? tr('d_suggest_budget', [money(budget), money(usualTotal)])
            : tr('d_suggest_no_budget');
    return Panel(
      title: tr('d_plan_title', [monthTitle(next)]),
      trailing: Text(tr('d_plan_total', [money(total)]), style: mono(size: 13, weight: FontWeight.w600)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TableHead([
          (tr('category'), 5, false),
          (tr('d_typical_month'), 3, true),
          (tr('d_last_month'), 3, true),
          (tr('d_suggest'), 3, true),
          (tr('d_plan'), 3, true),
        ]),
        for (final c in cats)
          TableLine([
            (Row(children: [Swatch(Color(c.color)), const SizedBox(width: 8), Expanded(child: Text(s.categoryName(c), style: sans(context, size: 13.5)))]), 5),
            (numCell(context, usual[c.id] == 0 ? '—' : money(usual[c.id]!), color: Ledger.mutedOf(context)), 3),
            (numCell(context, money(d.spentByCategory[c.id]?[11] ?? 0), color: Ledger.mutedOf(context)), 3),
            (numCell(context, suggested(c.id) == null ? '—' : money(suggested(c.id)!), color: suggested(c.id) == null ? Ledger.mutedOf(context) : null), 3),
            (
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: TextField(
                  controller: ctrl[c.id],
                  textAlign: TextAlign.right,
                  style: mono(size: 13.5),
                  decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              3
            ),
          ], padding: 4),
        const SizedBox(height: 10),
        Text(how, style: sans(context, size: 12.5, color: usualTotal == 0 ? warnOf(context) : Ledger.mutedOf(context))),
        const SizedBox(height: 10),
        Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
          DeskButton(tr('d_like_last'), onTap: () => setState(() {
                for (final c in cats) {
                  ctrl[c.id]!.text = formatAmount(d.spentByCategory[c.id]?[11] ?? 0, pattern: '0');
                }
              })),
          DeskButton(tr('d_take_suggested'), onTap: () {
            if (usualTotal == 0) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('d_suggest_none'))));
              return;
            }
            setState(() {
              for (final c in cats) {
                final v = suggested(c.id);
                // Keep what the user typed where there is nothing to suggest.
                if (v != null) ctrl[c.id]!.text = formatAmount(v, pattern: '0');
              }
            });
          }),
          DeskButton(tr('d_save_plan'), onTap: () => _save(desk, cats, budget: false)),
          DeskButton(tr('d_plan_as_budget'), primary: true, onTap: () => _save(desk, cats, budget: true)),
        ]),
      ]),
    );
  }

  Future<void> _save(DeskController desk, List<Category> cats, {required bool budget}) async {
    final plan = desk.profile.categoryPlan..clear();
    var total = 0;
    for (final c in cats) {
      final v = ((parseNum(ctrl[c.id]!.text) ?? 0) * 100).round();
      if (v > 0) {
        plan[c.id] = v;
        total += v;
      }
    }
    await desk.saveProfile();
    if (budget && total > 0) await desk.state.setBudget(total);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('d_saved'))));
  }
}

class _Goals extends StatelessWidget {
  const _Goals();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final now = DateTime.now();
    return Panel(
      title: tr('d_goals'),
      trailing: TextButton(onPressed: () => editGoal(context), child: Text(tr('d_new_goal'))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (s.goals.isEmpty) Text(tr('d_no_goals'), style: sans(context, color: Ledger.mutedOf(context))),
        for (final g in s.goals)
          InkWell(
            onTap: () => editGoal(context, goal: g),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: Text(g.name, style: sans(context, size: 14, weight: FontWeight.w500))),
                  Text('${(g.progress * 100).round()}%', style: mono(size: 13)),
                ]),
                const SizedBox(height: 4),
                Meter(g.progress, color: g.done ? Ledger.mint : null),
                Text(
                  '${formatMoney(g.savedMinor, g.currency)} / ${formatMoney(g.targetMinor, g.currency)}'
                  '${g.deadline == null || g.done ? '' : ' · ${tr('d_goal_need', [formatMoney(g.monthlyNeed(now), g.currency), DateFormat.yMMMd(intlLocale).format(g.deadline!)])}'}',
                  style: sans(context, size: 12.5, color: Ledger.mutedOf(context)),
                ),
              ]),
            ),
          ),
      ]),
    );
  }
}

class _Recurring extends StatelessWidget {
  const _Recurring();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final now = DateTime.now();
    var yearly = 0;
    for (final r in s.recurring.where((r) => r.kind == TxnKind.expense)) {
      final v = s.toBaseAmount(r.amountMinor, r.currency, now) ?? 0;
      yearly += switch (r.every) { Every.week => v * 52, Every.month => v * 12, Every.year => v };
    }
    return Panel(
      title: tr('d_regular'),
      trailing: Text(tr('d_per_year', [formatMoney(yearly, s.baseCurrency)]), style: mono(size: 12.5, color: Ledger.mutedOf(context))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final r in s.recurring)
          InkWell(
            onTap: () => editRecurring(context, r),
            child: LineItem(
              r.name,
              '${r.kind == TxnKind.income ? '+' : '−'}${formatMoney(r.amountMinor, r.currency)}',
              sub: '${tr('d_every_${r.every.name}')} · ${DateFormat.MMMd(intlLocale).format(r.next)}',
              color: r.kind == TxnKind.income ? Ledger.goodOf(context) : null,
            ),
          ),
        if (s.recurring.isEmpty) Text(tr('d_no_regular'), style: sans(context, color: Ledger.mutedOf(context))),
        Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: () => editRecurring(context), child: Text(tr('d_add_regular')))),
      ]),
    );
  }
}

class _Method extends StatelessWidget {
  const _Method();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final c = s.runwayConfig;
    return Panel(
      title: tr('d_how_forecast'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(tr('d_how_forecast_body'), style: sans(context, size: 13, color: Ledger.mutedOf(context), height: 1.5)),
        const SizedBox(height: 10),
        LineItem(tr('d_spend_basis'), switch (c.spendMode) {
          SpendMode.average => tr('d_avg_days', [c.averageDays]),
          SpendMode.budget => tr('d_budget'),
          SpendMode.custom => formatMoney(c.customSpendPerMonthMinor, s.baseCurrency),
        }),
        LineItem(tr('d_income_basis'), switch (c.incomeMode) {
          IncomeMode.none => tr('d_none'),
          IncomeMode.average => tr('d_avg_days', [c.averageDays]),
          IncomeMode.custom => formatMoney(c.customIncomePerMonthMinor, s.baseCurrency),
        }),
        LineItem(tr('d_adjust'), '${c.adjustPercent > 0 ? '+' : ''}${c.adjustPercent}%'),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RunwaySettingsScreen())),
            child: Text(tr('d_change_assumptions')),
          ),
        ),
      ]),
    );
  }
}
