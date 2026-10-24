import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../domain/money.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../ui/ledger.dart';
import '../ui/settings_screen.dart' show pickCurrency;
import 'charts.dart';
import 'kit.dart';
import 'profile.dart';
import 'shell.dart';

const _palette = [Color(0xFF0E3B34), Color(0xFFC08A1E), Color(0xFF3E6A8A), Color(0xFF4F9E86), Color(0xFF7FD1AE), Color(0xFF9A958A)];

class IncomePage extends StatefulWidget {
  const IncomePage({super.key});
  @override
  State<IncomePage> createState() => _IncomePageState();
}

class _IncomePageState extends State<IncomePage> {
  final hidden = <int?>{};
  String invFilter = 'all';

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final desk = context.watch<DeskController>();
    final d = desk.data;
    final base = s.baseCurrency;
    String money(num v) => formatMoney(v.round(), base);
    final now = DateTime.now();
    final year = d.incomeByMonth.skip(1).fold<int>(0, (a, b) => a + b);
    final yearSpent = d.spentByMonth.skip(1).fold<int>(0, (a, b) => a + b);
    final regular = _regularMonthly(s);
    final expected = _expectedUntil(s, DateTime(now.year, 12, 31));

    // Income categories, biggest first; the fifth and later are folded into "other".
    final cats = d.incomeByCategory.keys.toList()
      ..sort((a, b) => d.incomeByCategory[b]!.skip(1).fold<int>(0, (x, y) => x + y).compareTo(d.incomeByCategory[a]!.skip(1).fold<int>(0, (x, y) => x + y)));
    final shownCats = cats.take(5).toList();

    return DeskPage(
      title: tr('d_nav_income'),
      subtitle: tr('d_income_sub', [cats.length, desk.profile.holdings.length]),
      actions: [
        DeskButton(tr('d_new_income'), primary: true, icon: Icons.add, shortcut: 'I', onTap: () => newIncome(context)),
      ],
      children: [
        AutoGrid(minWidth: 190, children: [
          Kpi(tr('d_income_this_month'), '+${money(d.incomeByMonth[12])}', accent: true),
          Kpi(tr('d_12_months'), money(year), note: tr('d_avg_month', [money(year / 12)])),
          Kpi(tr('d_regular_income'), money(regular), note: tr('d_regular_note')),
          Kpi(tr('d_covers_spending'), yearSpent == 0 ? '—' : '${(year / yearSpent * 100).round()}%',
              note: year >= yearSpent ? tr('d_saving', [money(year - yearSpent)]) : tr('d_from_savings', [money(yearSpent - year)])),
          Kpi(tr('d_expected_year_end'), '+${money(expected)}', note: tr('d_from_regular')),
        ]),
        Panel(
          title: tr('d_income_by_month'),
          subtitle: tr('d_chart_click_month'),
          trailing: Wrap(spacing: 4, children: [
            for (var i = 0; i < shownCats.length; i++)
              TextButton.icon(
                onPressed: () => setState(() => hidden.contains(shownCats[i]) ? hidden.remove(shownCats[i]) : hidden.add(shownCats[i])),
                icon: Swatch(hidden.contains(shownCats[i]) ? Ledger.trackOf(context) : _palette[i]),
                label: Text(_catName(s, shownCats[i]),
                    style: sans(context, size: 12.5, color: hidden.contains(shownCats[i]) ? Ledger.mutedOf(context) : null)),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 12, height: 12, decoration: BoxDecoration(color: warnColor.withValues(alpha: .2), border: Border.all(color: warnColor, width: 1.5), borderRadius: BorderRadius.circular(2))),
                const SizedBox(width: 6),
                Text(tr('d_expenses'), style: sans(context, size: 12.5)),
              ]),
            ),
          ]),
          child: _IncomeBars(d.months, [for (final c in shownCats) hidden.contains(c) ? null : d.incomeByCategory[c]], d.spentByMonth),
        ),
        _Sources(cats: cats),
        _Investments(filter: invFilter, onFilter: (v) => setState(() => invFilter = v)),
        SplitRow([
          (2, 520, const _Recent()),
          (1, 320, const _NotIncome()),
        ]),
      ],
    );
  }

  static String _catName(AppState s, int? id) =>
      id == null ? tr('d_uncategorized') : (s.categoryById[id] == null ? '—' : s.categoryName(s.categoryById[id]!));

  /// Regular incomes per month in base currency (weekly × 52/12, yearly ÷ 12).
  static int _regularMonthly(AppState s) {
    final now = DateTime.now();
    var sum = 0.0;
    for (final r in s.recurring.where((r) => r.kind == TxnKind.income)) {
      final v = s.toBaseAmount(r.amountMinor, r.currency, now) ?? 0;
      sum += switch (r.every) { Every.week => v * 52 / 12, Every.month => v.toDouble(), Every.year => v / 12 };
    }
    return sum.round();
  }

  static int _expectedUntil(AppState s, DateTime until) {
    var sum = 0;
    for (final r in s.recurring.where((r) => r.kind == TxnKind.income)) {
      for (final o in r.occurrences(until)) {
        sum += s.toBaseAmount(r.amountMinor, r.currency, o) ?? 0;
      }
    }
    return sum;
  }
}

class _IncomeBars extends StatelessWidget {
  final List<DateTime> months;
  final List<List<int>?> series;
  final List<int> spent;
  const _IncomeBars(this.months, this.series, this.spent);

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppState>();
    final desk = context.read<DeskController>();
    String money(num v) => formatMoney((v * 100).round(), s.baseCurrency);
    double income(int i) => series.fold<int>(0, (a, l) => a + (l?[i] ?? 0)) / 100;
    return DeskBarChart(
      height: 260,
      rodWidth: 13,
      xLabels: [for (var i = 1; i < 13; i++) DateFormat.MMM(intlLocale).format(months[i])],
      groups: [
        for (var i = 1; i < 13; i++)
          [
            DRod([
              for (var k = 0; k < series.length; k++)
                if ((series[k]?[i] ?? 0) > 0) (series[k]![i] / 100, _palette[k % _palette.length]),
            ]),
            DRod([(spent[i] / 100, warnColor)], outline: warnColor),
          ],
      ],
      tooltip: (g) {
        final i = g + 1;
        final inc = income(i), out = spent[i] / 100;
        return '${DateFormat.yMMMM(intlLocale).format(months[i])}\n'
            '${tr('d_incomes')}: +${money(inc)}\n${tr('d_expenses')}: −${money(out)}\n'
            '${tr('d_difference')}: ${inc >= out ? '+' : '−'}${money((inc - out).abs())}';
      },
      onTap: (g) => desk.go(DeskPages.operations, filter: 'month:${DateFormat('yyyy-MM').format(months[g + 1])}:income'),
    );
  }
}

class _Sources extends StatelessWidget {
  final List<int?> cats;
  const _Sources({required this.cats});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final d = context.watch<DeskController>().data;
    final now = DateTime.now();
    return Panel(
      title: tr('d_sources'),
      subtitle: tr('d_sources_sub'),
      child: Column(children: [
        TableHead([
          (tr('d_source'), 5, false),
          (tr('d_how_comes'), 4, false),
          (tr('account'), 3, false),
          (tr('d_12_months'), 3, true),
          (tr('d_last'), 4, true),
          (tr('d_next'), 4, true),
        ]),
        if (cats.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(tr('d_no_income_yet'))),
        for (final id in cats)
          () {
            final list = d.txns.where((t) => t.kind == TxnKind.income && !t.excluded && t.categoryId == id).toList()
              ..sort((a, b) => b.time.compareTo(a.time));
            final total = d.incomeByCategory[id]!.skip(1).fold<int>(0, (a, b) => a + b);
            final monthsWith = d.incomeByCategory[id]!.skip(1).where((v) => v > 0).length;
            final rec = s.recurring.where((r) => r.kind == TxnKind.income && r.categoryId == id).firstOrNull;
            final last = list.firstOrNull;
            final acc = last?.accountId == null ? null : s.accountById[last!.accountId];
            return TableLine([
              (textCell(context, _IncomePageState._catName(s, id), bold: true), 5),
              (
                Text(rec != null
                    ? tr('d_every_${rec.every.name}')
                    : monthsWith >= 6
                        ? tr('d_most_months')
                        : tr('d_now_and_then'),
                    style: sans(context, size: 13, color: Ledger.mutedOf(context))),
                4
              ),
              (Text(acc == null ? '—' : '${s.accountName(acc)} · ${acc.currency}', style: sans(context, size: 13)), 3),
              (numCell(context, formatMoney(total, s.baseCurrency), bold: true), 3),
              (numCell(context, last == null ? '—' : '${DateFormat.MMMd(intlLocale).format(last.time)} · ${formatMoney(last.amountMinor, last.currency)}', size: 12.5), 4),
              (
                numCell(
                    context,
                    rec == null || rec.next.isBefore(now)
                        ? '—'
                        : '${DateFormat.MMMd(intlLocale).format(rec.next)} · ${formatMoney(rec.amountMinor, rec.currency)}',
                    size: 12.5,
                    color: Ledger.mutedOf(context)),
                4
              ),
            ]);
          }(),
      ]),
    );
  }
}

class _Investments extends StatelessWidget {
  final String filter;
  final ValueChanged<String> onFilter;
  const _Investments({required this.filter, required this.onFilter});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final desk = context.watch<DeskController>();
    final p = desk.profile;
    final now = DateTime.now();
    final base = s.baseCurrency;
    int toBase(int v, String c) => s.toBaseAmount(v, c, now) ?? 0;
    final all = p.holdings;
    final list = all.where((h) => filter == 'all' || _group(h.type) == filter).toList();
    final total = all.fold<int>(0, (a, h) => a + toBase(h.amountMinor, h.currency));
    final received = all.fold<int>(0, (a, h) => a + toBase(h.receivedMinor, h.currency));
    final passive = all.fold<double>(0, (a, h) => a + toBase(h.monthlyIncome.round(), h.currency));
    final avgSpent = desk.data.spentByMonth.skip(1).fold<int>(0, (a, b) => a + b) / 12;
    final counted = desk.countedHoldings();
    final events = <(DateTime, String, String, bool)>[
      for (final h in all)
        if (h.nextPayment != null && !h.nextPayment!.isBefore(DateTime(now.year, now.month, now.day)))
          (h.nextPayment!, h.name, '+${formatMoney(h.monthlyIncome.round() * _monthsPerPayout(h.payout), h.currency)}', false),
      for (final h in all)
        if (h.maturity != null && h.maturity!.isAfter(now)) (h.maturity!, tr('d_matures', [h.name]), formatMoney(h.amountMinor, h.currency), true),
    ]..sort((a, b) => a.$1.compareTo(b.$1));

    return Panel(
      borderColor: Ledger.inkOf(context),
      title: tr('d_investments'),
      subtitle: tr('d_investments_sub'),
      trailing: Wrap(spacing: 8, children: [
        DeskButton(tr('d_add_investment'), primary: true, icon: Icons.add, onTap: () => _edit(context, desk)),
      ]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AutoGrid(minWidth: 170, spacing: 12, children: [
          Kpi(tr('d_worth_now'), formatMoney(total, base)),
          Kpi(tr('d_income_this_year'), '+${formatMoney(received, base)}', valueColor: Ledger.goodOf(context), note: tr('d_inv_income_kinds')),
          Kpi(tr('d_passive'), formatMoney(passive.round(), base),
              note: avgSpent == 0 ? tr('d_per_month') : tr('d_passive_note', ['${(passive / avgSpent * 100).round()}%'])),
          Kpi(tr('d_in_all_money'), counted == 0 ? tr('d_not_counted') : '+${formatMoney(counted, base)}',
              note: counted == 0 ? tr('d_turn_on_below') : tr('d_counted_note')),
        ]),
        const SizedBox(height: 14),
        Choice(
          options: [
            ('all', '${tr('d_all')} · ${all.length}'),
            ('cash', tr('d_inv_deposits')),
            ('bonds', tr('d_inv_bonds')),
            ('stocks', tr('d_inv_stocks')),
          ],
          value: filter,
          onChanged: onFilter,
        ),
        const SizedBox(height: 10),
        TableHead([
          (tr('d_investment'), 5, false),
          (tr('d_type'), 3, false),
          (tr('d_now'), 3, true),
          (tr('d_yield'), 4, false),
          (tr('d_this_year'), 3, true),
          (tr('d_next'), 3, true),
          (tr('d_count_in_all'), 2, true),
        ]),
        if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(tr('d_no_investments'), style: sans(context, color: Ledger.mutedOf(context))),
          ),
        for (final h in list)
          TableLine([
            (textCell(context, h.name, sub: h.where, bold: true), 5),
            (Align(alignment: Alignment.centerLeft, child: tagPlain(context, tr('d_type_${h.type}'))), 3),
            (
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                numCell(context, formatMoney(h.amountMinor, h.currency), bold: true),
                if (h.currency != base) numCell(context, '≈ ${formatMoney(toBase(h.amountMinor, h.currency), base)}', size: 11.5, color: Ledger.mutedOf(context)),
              ]),
              3
            ),
            (textCell(context, '${NumberFormat('#,##0.##', intlLocale).format(h.ratePct)}%', sub: tr('d_payout_${h.payout}')), 4),
            (numCell(context, h.receivedMinor == 0 ? '—' : '+${formatMoney(h.receivedMinor, h.currency)}', color: Ledger.goodOf(context)), 3),
            (numCell(context, h.nextPayment == null ? '—' : DateFormat.MMMd(intlLocale).format(h.nextPayment!), size: 12.5), 3),
            (
              Align(
                alignment: Alignment.centerRight,
                child: Toggle(h.counted, semantics: tr('d_count_in_all'), onChanged: (v) {
                  final i = p.holdings.indexOf(h);
                  p.holdings[i] = h.copyWith(counted: v);
                  desk.saveProfile();
                }),
              ),
              2
            ),
          ], onTap: () => _edit(context, desk, h)),
        if (events.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(tr('d_inv_events'), style: sans(context, size: 13, weight: FontWeight.w600)),
          for (final (date, what, sum, big) in events.take(6))
            LineItem('${DateFormat.yMMMd(intlLocale).format(date)} · $what', sum, color: big ? null : Ledger.goodOf(context)),
        ],
        const SizedBox(height: 10),
        Text(tr('d_inv_growth_note'), style: sans(context, size: 12.5, color: Ledger.mutedOf(context))),
      ]),
    );
  }

  static String _group(String type) => switch (type) {
        'deposit' || 'savings' || 'fund_cash' => 'cash',
        'bonds' => 'bonds',
        _ => 'stocks',
      };

  static int _monthsPerPayout(String p) => switch (p) { 'quarterly' => 3, 'twice' => 6, 'yearly' => 12, 'daily' => 1, _ => 1 };

  static Future<void> _edit(BuildContext context, DeskController desk, [Holding? h]) async {
    final r = await showDialog<(Holding?, bool)>(context: context, builder: (_) => _HoldingDialog(h, desk.state.baseCurrency));
    if (r == null) return;
    final (result, delete) = r;
    if (delete && h != null) {
      desk.profile.holdings.removeWhere((x) => x.id == h.id);
    } else if (result != null) {
      final i = desk.profile.holdings.indexWhere((x) => x.id == result.id);
      if (i >= 0) {
        desk.profile.holdings[i] = result;
      } else {
        desk.profile.holdings.add(result);
      }
    }
    await desk.saveProfile();
  }
}

class _HoldingDialog extends StatefulWidget {
  final Holding? h;
  final String base;
  const _HoldingDialog(this.h, this.base);
  @override
  State<_HoldingDialog> createState() => _HoldingDialogState();
}

class _HoldingDialogState extends State<_HoldingDialog> {
  late String type = widget.h?.type ?? 'deposit';
  late String payout = widget.h?.payout ?? 'monthly';
  late String currency = widget.h?.currency ?? widget.base;
  late bool counted = widget.h?.counted ?? false;
  late DateTime? next = widget.h?.nextPayment;
  late DateTime? maturity = widget.h?.maturity;
  late final name = TextEditingController(text: widget.h?.name ?? '');
  late final where = TextEditingController(text: widget.h?.where ?? '');
  late final amount = TextEditingController(text: widget.h == null ? '' : formatAmount(widget.h!.amountMinor, pattern: '0.##'));
  late final rate = TextEditingController(text: widget.h == null ? '' : '${widget.h!.ratePct}');
  late final received = TextEditingController(text: widget.h == null ? '' : formatAmount(widget.h!.receivedMinor, pattern: '0.##'));

  @override
  Widget build(BuildContext context) {
    Future<DateTime?> pick(DateTime? initial) => showDatePicker(
          context: context,
          initialDate: initial ?? DateTime.now(),
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
        );
    return AlertDialog(
      title: Text(widget.h == null ? tr('d_add_investment') : widget.h!.name),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Choice(
              options: [for (final t in ['deposit', 'savings', 'bonds', 'stocks', 'fund', 'other']) (t, tr('d_type_$t'))],
              value: type,
              onChanged: (v) => setState(() => type = v),
              dense: true,
            ),
            const SizedBox(height: 12),
            FieldBox(tr('name'), name, numeric: false),
            const SizedBox(height: 10),
            FieldBox(tr('d_where'), where, numeric: false, hint: tr('d_where_hint')),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: FieldBox(tr('d_amount_now'), amount, suffix: currency)),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () async {
                  final c = await pickCurrency(context, selected: currency);
                  if (c != null) setState(() => currency = c);
                },
                child: Text(currency),
              ),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: FieldBox(tr('d_rate_year'), rate, suffix: '%')),
              const SizedBox(width: 10),
              Expanded(child: FieldBox(tr('d_received_year'), received, suffix: currency)),
            ]),
            const SizedBox(height: 12),
            Text(tr('d_payouts'), style: sans(context, size: 12, color: Ledger.mutedOf(context))),
            const SizedBox(height: 6),
            Choice(
              options: [for (final x in ['monthly', 'quarterly', 'twice', 'yearly', 'daily', 'none']) (x, tr('d_payout_$x'))],
              value: payout,
              onChanged: (v) => setState(() => payout = v),
              dense: true,
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 10, runSpacing: 8, children: [
              OutlinedButton(
                onPressed: () async {
                  final d = await pick(next);
                  if (d != null) setState(() => next = d);
                },
                child: Text(next == null ? tr('d_next_payment') : '${tr('d_next_payment')}: ${DateFormat.yMMMd(intlLocale).format(next!)}'),
              ),
              OutlinedButton(
                onPressed: () async {
                  final d = await pick(maturity);
                  if (d != null) setState(() => maturity = d);
                },
                child: Text(maturity == null ? tr('d_maturity') : '${tr('d_maturity')}: ${DateFormat.yMMMd(intlLocale).format(maturity!)}'),
              ),
            ]),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: counted,
              onChanged: (v) => setState(() => counted = v),
              title: Text(tr('d_count_in_all')),
              subtitle: Text(tr('d_count_in_all_sub')),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.backspace_outlined, size: 16),
          label: Text(tr('d_clear_all')),
          onPressed: () => setState(() {
            for (final c in [name, where, amount, rate, received]) {
              c.clear();
            }
            next = null;
            maturity = null;
          }),
        ),
        if (widget.h != null) TextButton(onPressed: () => Navigator.pop(context, (null, true)), child: Text(tr('delete'))),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('cancel'))),
        FilledButton(
          onPressed: () {
            final a = parseNum(amount.text);
            if (name.text.trim().isEmpty || a == null) return;
            Navigator.pop(
              context,
              (
                Holding(
                  id: widget.h?.id ?? '${DateTime.now().microsecondsSinceEpoch}',
                  type: type,
                  name: name.text.trim(),
                  where: where.text.trim(),
                  currency: currency,
                  amountMinor: (a * 100).round(),
                  ratePct: parseNum(rate.text) ?? 0,
                  payout: payout,
                  receivedMinor: ((parseNum(received.text) ?? 0) * 100).round(),
                  nextPayment: next,
                  maturity: maturity,
                  counted: counted,
                ),
                false
              ),
            );
          },
          child: Text(tr('save')),
        ),
      ],
    );
  }
}

class _Recent extends StatelessWidget {
  const _Recent();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final d = context.watch<DeskController>().data;
    final list = d.txns.where((t) => t.kind == TxnKind.income).toList()..sort((a, b) => b.time.compareTo(a.time));
    return Panel(
      title: tr('d_receipts'),
      trailing: TextButton(onPressed: () => context.read<DeskController>().go(DeskPages.operations, filter: 'income'), child: Text(tr('d_in_operations'))),
      child: Column(children: [
        if (list.isEmpty) Text(tr('d_no_income_yet'), style: sans(context, color: Ledger.mutedOf(context))),
        for (final t in list.take(8))
          TableLine([
            (Text(DateFormat.MMMd(intlLocale).format(t.time), style: mono(size: 12.5, color: Ledger.mutedOf(context))), 2),
            (textCell(context, t.merchant ?? _IncomePageState._catName(s, t.categoryId), sub: t.accountId == null ? null : s.accountName(s.accountById[t.accountId]!)), 6),
            (
              Text(t.ownTransfer ? tr('d_not_income_own') : t.excluded ? tr('d_not_income_debt') : tr('d_counted'),
                  style: sans(context, size: 12.5, color: t.excluded ? Ledger.mutedOf(context) : Ledger.goodOf(context))),
              4
            ),
            (numCell(context, '+${formatMoney(t.amountMinor, t.currency)}', color: t.excluded ? Ledger.mutedOf(context) : Ledger.goodOf(context)), 3),
          ]),
      ]),
    );
  }
}

class _NotIncome extends StatelessWidget {
  const _NotIncome();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final d = context.watch<DeskController>().data;
    var own = 0, debts = 0;
    for (final t in d.txns.where((t) => t.kind == TxnKind.income && t.excluded)) {
      final v = s.toBase(t.copyWith(excluded: false)) ?? 0;
      if (t.ownTransfer) {
        own += v;
      } else {
        debts += v;
      }
    }
    return Panel(
      title: tr('d_not_income'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        LineItem(tr('d_not_income_debt'), formatMoney(debts, s.baseCurrency)),
        LineItem(tr('d_not_income_own'), formatMoney(own, s.baseCurrency)),
        const SizedBox(height: 6),
        Text(tr('d_not_income_note'), style: sans(context, size: 12.5, color: Ledger.mutedOf(context))),
      ]),
    );
  }
}
