import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../domain/currencies.dart';
import '../domain/money.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../ui/ledger.dart';
import '../ui/settings_screen.dart' show pickCurrency;
import 'kit.dart';
import 'shell.dart';

const _series = [Color(0xFF0E3B34), Color(0xFFC08A1E), Color(0xFF3E6A8A), Color(0xFF8C7B5E), Color(0xFFC2577A), Color(0xFF9A958A)];

class AnalyticsPage extends StatefulWidget {
  const AnalyticsPage({super.key});
  @override
  State<AnalyticsPage> createState() => _AnalyticsPageState();
}

class _AnalyticsPageState extends State<AnalyticsPage> {
  int months = 12;
  String? currency;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final desk = context.watch<DeskController>();
    final d = desk.data;
    final base = s.baseCurrency;
    final cur = currency != null && desk.profile.displayCurrencies.contains(currency) ? currency! : base;
    final now = DateTime.now();
    // Amounts are kept in the base currency and shown in the chosen one at today's rate.
    int conv(num v) => cur == base ? v.round() : (s.rates.convert(v.round(), base, cur, now) ?? v.round());
    String money(num v) => formatMoney(conv(v), cur);
    String compact(num v) => NumberFormat.compact(locale: intlLocale).format(conv(v) / 100);
    final from = 13 - months;
    final idx = [for (var i = from; i < 13; i++) i];
    final spent = idx.fold<int>(0, (a, i) => a + d.spentByMonth[i]);
    final income = idx.fold<int>(0, (a, i) => a + d.incomeByMonth[i]);

    // Daily totals of the period for the median and the record day.
    final byDay = <DateTime, int>{};
    for (final t in d.txns) {
      if (t.excluded || t.kind.name != 'expense' || d.monthIndex(t.time) < from) continue;
      final k = DateTime(t.time.year, t.time.month, t.time.day);
      byDay[k] = (byDay[k] ?? 0) + (s.toBase(t) ?? 0);
    }
    final days = DateTime(now.year, now.month, now.day).difference(d.months[from]).inDays + 1;
    final sortedDays = byDay.values.toList()..sort();
    final median = sortedDays.isEmpty ? 0 : sortedDays[sortedDays.length ~/ 2];
    final record = byDay.entries.fold<MapEntry<DateTime, int>?>(null, (a, e) => a == null || e.value > a.value ? e : a);
    final byAccount = <int?, int>{};
    for (final t in d.txns) {
      if (t.excluded || t.kind.name != 'expense' || d.monthIndex(t.time) < from) continue;
      byAccount[t.accountId] = (byAccount[t.accountId] ?? 0) + (s.toBase(t) ?? 0);
    }
    final topAccount = byAccount.entries.fold<MapEntry<int?, int>?>(null, (a, e) => a == null || e.value > a.value ? e : a);

    // The five biggest categories of the period; the rest is "other".
    final catTotals = {
      for (final e in d.spentByCategory.entries) e.key: idx.fold<int>(0, (a, i) => a + e.value[i]),
    };
    final top = (catTotals.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(5).map((e) => e.key).toList();
    String catName(int? id) => id == null ? tr('d_uncategorized') : (s.categoryById[id] == null ? '—' : s.categoryName(s.categoryById[id]!));

    return DeskPage(
      title: tr('d_nav_analytics'),
      subtitle: tr('d_analytics_sub', [DateFormat.yMMM(intlLocale).format(d.months[from]), DateFormat.yMMM(intlLocale).format(now)]),
      actions: [
        Seg(options: [(3, tr('d_3m')), (6, tr('d_6m')), (12, tr('d_12m'))], value: months, onChanged: (v) => setState(() => months = v)),
        Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final c in desk.profile.displayCurrencies)
            Pill(
              '${currencySymbol(c)} $c',
              selected: c == cur,
              onTap: () => setState(() => currency = c),
              trailing: c == base
                  ? null
                  : InkWell(
                      onTap: () {
                        desk.profile.displayCurrencies.remove(c);
                        desk.saveProfile(refold: false);
                        if (currency == c) setState(() => currency = base);
                      },
                      child: Icon(Icons.close, size: 14, color: c == cur ? Ledger.paper : Ledger.mutedOf(context)),
                    ),
            ),
          Pill(tr('d_add_currency'), dashed: true, onTap: () async {
            final c = await pickCurrency(context);
            if (c == null || desk.profile.displayCurrencies.contains(c)) return;
            desk.profile.displayCurrencies.add(c);
            await desk.saveProfile(refold: false);
            setState(() => currency = c);
          }),
        ]),
      ],
      children: [
        AutoGrid(minWidth: 170, spacing: 12, children: [
          Kpi(tr('d_spent_period'), money(spent), note: tr('d_avg_month', [money(spent / months)])),
          Kpi(tr('d_income_period'), money(income), note: spent == 0 ? null : tr('d_covers', ['${(income / spent * 100).round()}%'])),
          Kpi(tr('d_avg_day'), money(days <= 0 ? 0 : spent / days), note: tr('d_median', [money(median)])),
          Kpi(tr('d_record_day'), record == null ? '—' : money(record.value),
              note: record == null ? null : DateFormat.yMMMMd(intlLocale).format(record.key)),
          Kpi(tr('d_main_account'), topAccount == null || spent == 0 ? '—' : '${(topAccount.value / spent * 100).round()}%',
              note: topAccount?.key == null ? null : s.accountName(s.accountById[topAccount!.key]!)),
        ]),
        Panel(
          title: tr('d_by_month'),
          trailing: Wrap(spacing: 12, runSpacing: 4, children: [
            for (var i = 0; i < top.length; i++) _legend(context, _series[i], catName(top[i])),
            _legend(context, _series.last, tr('d_other')),
            _legend(context, Ledger.inkOf(context), tr('d_incomes'), line: true),
          ]),
          child: _MonthBars(
            months: [for (final i in idx) d.months[i]],
            parts: [
              for (final i in idx)
                [
                  for (final id in top) d.spentByCategory[id]![i],
                  d.spentByMonth[i] - top.fold<int>(0, (a, id) => a + d.spentByCategory[id]![i]),
                ],
            ],
            income: [for (final i in idx) d.incomeByMonth[i]],
            label: compact,
          ),
        ),
        SplitRow([
          (1, 420, _Changes(catName: catName, money: money)),
          (1, 420, _Heat(d.heat, money)),
        ]),
        Panel(
          title: tr('d_cat_trends'),
          subtitle: tr('d_cat_trends_sub'),
          child: AutoGrid(minWidth: 220, spacing: 12, children: [
            for (final e in (catTotals.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(12))
              _Spark(name: catName(e.key), values: d.spentByCategory[e.key]!.sublist(1), money: money),
          ]),
        ),
        SplitRow([
          (2, 560, _Payees(money: money, catName: catName)),
          (1, 320, const _Fx()),
        ]),
      ],
    );
  }

  Widget _legend(BuildContext c, Color color, String label, {bool line = false}) => Row(mainAxisSize: MainAxisSize.min, children: [
        line ? Container(width: 14, height: 2, color: color) : Swatch(color, size: 11),
        const SizedBox(width: 6),
        Text(label, style: sans(c, size: 12.5)),
      ]);
}

class _MonthBars extends StatelessWidget {
  final List<DateTime> months;
  final List<List<int>> parts;
  final List<int> income;
  final String Function(num) label;
  const _MonthBars({required this.months, required this.parts, required this.income, required this.label});

  @override
  Widget build(BuildContext context) {
    final totals = [for (final p in parts) p.fold<int>(0, (a, b) => a + b)];
    final maxV = [...totals, ...income, 1].reduce(math.max).toDouble();
    const h = 220.0;
    return SizedBox(
      height: h + 64,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (var i = 0; i < months.length; i++)
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
              SizedBox(
                height: h,
                child: Stack(alignment: Alignment.bottomCenter, children: [
                  FractionallySizedBox(
                    widthFactor: .5,
                    child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                      for (var k = parts[i].length - 1; k >= 0; k--)
                        if (parts[i][k] > 0) Container(height: (parts[i][k] / maxV * h).clamp(1, h), color: _series[k.clamp(0, _series.length - 1)]),
                    ]),
                  ),
                  Positioned(bottom: income[i] / maxV * h, left: 8, right: 8, child: Container(height: 2, color: Ledger.inkOf(context))),
                ]),
              ),
              const SizedBox(height: 6),
              Text(DateFormat.MMM(intlLocale).format(months[i]), style: mono(size: 11, color: Ledger.mutedOf(context))),
              Text(label(totals[i]), style: mono(size: 11, weight: FontWeight.w500)),
            ]),
          ),
      ]),
    );
  }
}

class _Changes extends StatelessWidget {
  final String Function(int?) catName;
  final String Function(num) money;
  const _Changes({required this.catName, required this.money});

  @override
  Widget build(BuildContext context) {
    final d = context.watch<DeskController>().data;
    final now = DateTime.now();
    final n = DateTime(now.year, now.month + 1, 0).day;
    final rows = <(int?, int)>[
      for (final e in d.spentByCategory.entries) (e.key, d.forecastOf(e.key, daysPassed: now.day, daysInMonth: n) - e.value[11]),
    ]..removeWhere((r) => r.$2.abs() < 100);
    rows.sort((a, b) => b.$2.compareTo(a.$2));
    final maxAbs = rows.fold<int>(1, (a, r) => math.max(a, r.$2.abs()));
    final last = d.spentByMonth[11];
    final fc = d.thisMonthDays.isEmpty ? 0 : (d.spentByMonth[12] / now.day * n).round();
    return Panel(
      title: tr('d_changes'),
      trailing: Text('${money(last)} → ${money(fc)}', style: mono(size: 12.5, color: Ledger.mutedOf(context))),
      child: Column(children: [
        if (rows.isEmpty) Text(tr('d_nothing_yet'), style: sans(context, color: Ledger.mutedOf(context))),
        for (final (id, v) in rows.take(10))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Expanded(flex: 3, child: Text(catName(id), overflow: TextOverflow.ellipsis, style: sans(context, size: 13.5))),
              Expanded(
                flex: 5,
                child: SizedBox(
                  height: 16,
                  child: LayoutBuilder(builder: (context, c) {
                    final half = c.maxWidth / 2;
                    final w = v.abs() / maxAbs * half;
                    return Stack(children: [
                      Positioned(left: half, top: 0, bottom: 0, child: Container(width: 1, color: Ledger.inkOf(context))),
                      Positioned(
                        left: v > 0 ? half : half - w,
                        top: 3,
                        bottom: 3,
                        child: Container(width: w, color: v > 0 ? warnColor : const Color(0xFF4F9E86)),
                      ),
                    ]);
                  }),
                ),
              ),
              SizedBox(
                width: 84,
                child: Text('${v > 0 ? '+' : '−'}${money(v.abs())}',
                    textAlign: TextAlign.right, style: mono(size: 12.5, color: v > 0 ? warnOf(context) : Ledger.goodOf(context))),
              ),
            ]),
          ),
        const SizedBox(height: 6),
        Text(tr('d_changes_note'), style: sans(context, size: 12, color: Ledger.mutedOf(context))),
      ]),
    );
  }
}

class _Heat extends StatelessWidget {
  final List<List<int>> heat;
  final String Function(num) money;
  const _Heat(this.heat, this.money);

  @override
  Widget build(BuildContext context) {
    final maxV = heat.expand((r) => r).fold<int>(1, math.max);
    final shades = [Ledger.trackOf(context), const Color(0xFFCDE8DB), const Color(0xFF8FCBB0), const Color(0xFF4F9E86), Ledger.emerald];
    var best = (0, 0, 0);
    for (var w = 0; w < 7; w++) {
      for (var b = 0; b < 12; b++) {
        if (heat[w][b] > best.$3) best = (w, b, heat[w][b]);
      }
    }
    final names = [for (var i = 0; i < 7; i++) DateFormat.E(intlLocale).format(DateTime(2024, 1, 1 + i))];
    return Panel(
      title: tr('d_when_spend'),
      subtitle: tr('d_when_spend_sub'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const SizedBox(width: 34),
          for (var b = 0; b < 12; b++)
            Expanded(child: Text(b % 3 == 0 ? '${b * 2}' : '', style: mono(size: 10.5, color: Ledger.mutedOf(context)))),
        ]),
        for (var w = 0; w < 7; w++)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Row(children: [
              SizedBox(width: 34, child: Text(names[w], style: mono(size: 11, color: Ledger.mutedOf(context)))),
              for (var b = 0; b < 12; b++)
                Expanded(
                  child: Tooltip(
                    message: '${names[w]} ${b * 2}–${b * 2 + 2}: ${money(heat[w][b])}',
                    child: Container(
                      height: 22,
                      margin: const EdgeInsets.only(right: 3),
                      decoration: BoxDecoration(
                        color: shades[heat[w][b] == 0 ? 0 : (heat[w][b] / maxV * 4).ceil().clamp(1, 4)],
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
        const SizedBox(height: 10),
        if (best.$3 > 0)
          Text(tr('d_peak', [names[best.$1], best.$2 * 2, best.$2 * 2 + 2, money(best.$3)]), style: sans(context, size: 13)),
      ]),
    );
  }
}

class _Spark extends StatelessWidget {
  final String name;
  final List<int> values;
  final String Function(num) money;
  const _Spark({required this.name, required this.values, required this.money});

  @override
  Widget build(BuildContext context) {
    final recent = values.skip(9).fold<int>(0, (a, b) => a + b) / 3;
    final prior = values.skip(6).take(3).fold<int>(0, (a, b) => a + b) / 3;
    final t = prior == 0 ? 0 : ((recent - prior) / prior * 100).round();
    final up = t > 5;
    final avg = values.fold<int>(0, (a, b) => a + b) / values.length;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(border: Border.all(color: Ledger.trackOf(context)), borderRadius: BorderRadius.circular(6)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(name, overflow: TextOverflow.ellipsis, style: sans(context, size: 13.5, weight: FontWeight.w500))),
          Text('${t > 0 ? '+' : ''}$t%',
              style: mono(size: 12.5, weight: FontWeight.w600, color: up ? warnOf(context) : t < -5 ? Ledger.goodOf(context) : Ledger.mutedOf(context))),
        ]),
        const SizedBox(height: 6),
        SizedBox(height: 44, child: CustomPaint(painter: _SparkPainter(values, up ? warnColor : Ledger.inkOf(context)))),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(child: Text(tr('d_avg_short', [money(avg)]), style: sans(context, size: 12, color: Ledger.mutedOf(context)))),
          Text(money(values.last), style: mono(size: 12)),
        ]),
      ]),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final List<int> v;
  final Color color;
  _SparkPainter(this.v, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    if (v.isEmpty) return;
    final maxV = math.max(1, v.reduce(math.max)) * 1.1;
    final p = Path();
    for (var i = 0; i < v.length; i++) {
      final pt = Offset(i / math.max(1, v.length - 1) * size.width, size.height - v[i] / maxV * size.height);
      i == 0 ? p.moveTo(pt.dx, pt.dy) : p.lineTo(pt.dx, pt.dy);
    }
    final area = Path.from(p)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(area, Paint()..color = color.withValues(alpha: .08));
    canvas.drawPath(p, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..color = color);
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) => old.v != v || old.color != color;
}

class _Payees extends StatelessWidget {
  final String Function(num) money;
  final String Function(int?) catName;
  const _Payees({required this.money, required this.catName});

  @override
  Widget build(BuildContext context) {
    final d = context.watch<DeskController>().data;
    final total = d.payees.fold<int>(0, (a, p) => a + p.sum);
    return Panel(
      title: tr('d_where_spend'),
      subtitle: tr('d_last_6m'),
      child: Column(children: [
        TableHead([
          (tr('payee'), 5, false),
          (tr('d_count'), 2, true),
          (tr('d_avg_check'), 3, true),
          (tr('d_total'), 3, true),
          (tr('d_share'), 4, false),
          (tr('d_trend'), 2, true),
        ]),
        if (d.payees.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(tr('d_nothing_yet'))),
        for (final p in d.payees.take(10))
          () {
            final share = total == 0 ? 0.0 : p.sum / total;
            final t = p.earlier == 0 ? null : ((p.recent - p.earlier) / p.earlier * 100).round();
            return TableLine([
              (textCell(context, p.name, sub: catName(p.categoryId)), 5),
              (numCell(context, '${p.count}'), 2),
              (numCell(context, money(p.sum / p.count)), 3),
              (numCell(context, money(p.sum), bold: true), 3),
              (
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Row(children: [
                    Expanded(child: Meter(math.min(1, share * 4), height: 6)),
                    SizedBox(width: 38, child: Text('${(share * 100).round()}%', textAlign: TextAlign.right, style: mono(size: 11.5, color: Ledger.mutedOf(context)))),
                  ]),
                ),
                4
              ),
              (numCell(context, t == null ? '—' : '${t > 0 ? '+' : ''}$t%', color: (t ?? 0) > 10 ? warnOf(context) : Ledger.mutedOf(context)), 2),
            ]);
          }(),
      ]),
    );
  }
}

class _Fx extends StatelessWidget {
  const _Fx();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final now = DateTime.now();
    final base = s.baseCurrency;
    final foreign = <String, int>{};
    for (final a in s.accounts) {
      final b = s.balances[a.id];
      if (a.currency == base || b == null) continue;
      foreign[a.currency] = (foreign[a.currency] ?? 0) + b;
    }
    return Panel(
      title: tr('d_fx_title'),
      subtitle: tr('d_fx_sub', [base]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (foreign.isEmpty) Text(tr('d_fx_none'), style: sans(context, color: Ledger.mutedOf(context))),
        for (final e in foreign.entries)
          () {
            final monthAgo = DateTime(now.year, now.month - 1, now.day);
            final nowV = s.rates.toBase(e.value, e.key, now);
            final thenV = s.rates.toBase(e.value, e.key, monthAgo);
            final hist = [
              for (var i = 11; i >= 0; i--) s.rates.convert(10000, base, e.key, DateTime(now.year, now.month - i, 15)),
            ].whereType<int>().toList();
            return Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('${currencySymbol(e.key)} ${e.key}', style: sans(context, size: 14, weight: FontWeight.w600)),
                if (hist.length > 1) SizedBox(height: 50, child: CustomPaint(painter: _SparkPainter(hist, Ledger.inkOf(context)))),
                LineItem(tr('d_fx_balance'), formatMoney(e.value, e.key)),
                if (thenV != null) LineItem(tr('d_fx_then'), formatMoney(thenV, base)),
                if (nowV != null) LineItem(tr('d_fx_now'), formatMoney(nowV, base)),
                if (nowV != null && thenV != null)
                  LineItem(tr('d_fx_diff'), formatMoney(nowV - thenV, base, signed: true),
                      bold: true, color: nowV < thenV ? warnOf(context) : Ledger.goodOf(context)),
              ]),
            );
          }(),
        Text(tr('d_fx_note'), style: sans(context, size: 12, color: Ledger.mutedOf(context))),
      ]),
    );
  }
}
