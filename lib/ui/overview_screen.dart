import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../domain/money.dart';
import '../domain/periods.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'ledger.dart';
import 'search_screen.dart';
import 'txn_editor.dart';
import 'widgets.dart';

part 'overview_breakdown.dart';

/// Day / week / month / year breakdown. Swipe left/right to move between periods.
class OverviewScreen extends StatelessWidget {
  const OverviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final stats = state.periodStats;
    final theme = Theme.of(context);
    if (stats == null) return const Center(child: CircularProgressIndicator());
    final period = state.period;
    final currency = state.baseCurrency;
    final entries = stats.spentByCategory.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    return Scaffold(
      appBar: AppBar(
        title: PeriodSwitcher(period: period, onChanged: state.setPeriod),
        bottom: periodTypeBar(period.type, state.setPeriodType),
        actions: [IconButton(tooltip: tr('search'), icon: const Icon(Icons.search), onPressed: () => openSearch(context))],
      ),
      body: SwipeToChange(
        onPrevious: () => state.setPeriod(period.shift(-1)),
        onNext: () => state.setPeriod(period.shift(1)),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            _TotalsCard(stats: stats, currency: currency, budgetOn: state.budgetEnabled),
            if (stats.unconvertedCount > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(tr('unconverted', [stats.unconvertedCount]),
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
              ),
            LedgerSection(tr('by_category'), trailing: formatAmount(stats.spentMinor, pattern: '#,##0.00'), padding: const EdgeInsets.fromLTRB(16, 8, 16, 4)),
            if (entries.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(tr('no_expenses'))),
            for (final e in entries)
              _CategoryRow(
                category: e.key == null ? null : state.categoryById[e.key],
                amount: e.value,
                share: stats.spentMinor == 0 ? 0 : e.value / stats.spentMinor,
                currency: currency,
              ),
            if (period.type == PeriodType.day) ...[
              LedgerSection(tr('operations'), padding: const EdgeInsets.fromLTRB(16, 24, 16, 4)),
              if (state.periodTxns.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(tr('no_ops'))),
              for (final t in state.periodTxns) TxnTile(t, onTap: () => openTxnEditor(context, txn: t)),
            ] else ...[
              LedgerSection(period.type == PeriodType.year ? tr('by_months') : tr('by_days'),
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 10)),
              _BreakdownViews(state: state),
            ],
          ],
        ),
      ),
    );
  }
}

class _TotalsCard extends StatelessWidget {
  final PeriodStats stats;
  final String currency;
  final bool budgetOn;
  const _TotalsCard({required this.stats, required this.currency, required this.budgetOn});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final over = stats.spentMinor > stats.budgetMinor;
    final ratio = stats.budgetMinor == 0 ? 0.0 : stats.spentMinor / stats.budgetMinor;
    final progress = ratio.clamp(0.0, 1.0);
    // 99.6 % is not "100 %": under the budget the share rounds down; over it, the real figure.
    final share = ratio >= 1 ? (ratio * 100).round() : (ratio * 100).floor();
    final elapsed = stats.isCurrent && stats.daysTotal > 0 ? stats.daysPassed / stats.daysTotal : null;
    final small = theme.textTheme.bodySmall?.copyWith(color: Ledger.mutedOf(context));

    Widget figure(String label, int value, {Color? color, double size = 17}) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            LedgerCaption(label),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(formatAmount(value, pattern: '#,##0.00'), style: mono(size: size, color: color)),
            ),
          ]),
        );

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Ledger.ruleOf(context)))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (budgetOn) ...[
          Row(children: [
            figure(tr('expenses'), stats.spentMinor),
            figure(tr('budget'), stats.budgetMinor),
            figure(tr('left'), stats.remainingMinor,
                color: stats.remainingMinor < 0 ? Ledger.badOf(context) : Ledger.accentOf(context)),
          ]),
          const SizedBox(height: 8),
          LedgerBar(value: progress, tick: elapsed, color: over ? Ledger.badOf(context) : null),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(
                child: Text(tr('spent_share', [share]),
                    style: over ? small?.copyWith(color: Ledger.badOf(context)) : small)),
            if (elapsed != null)
              Flexible(
                child: Text('│ ${tr('elapsed_share', [(elapsed * 100).round()])}',
                    style: small, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
          ]),
          const SizedBox(height: 10),
          Container(height: 1, color: Ledger.ruleOf(context)),
          const SizedBox(height: 10),
        ],
        Row(children: [
          if (!budgetOn) figure(tr('expenses'), stats.spentMinor),
          figure(tr('income'), stats.incomeMinor, color: Ledger.goodOf(context), size: 15),
          figure(tr('net'), stats.incomeMinor - stats.spentMinor, size: 15),
        ]),
      ]),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  final Category? category;
  final int amount;
  final double share;
  final String currency;
  const _CategoryRow({required this.category, required this.amount, required this.share, required this.currency});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<AppState>();
    final color = category == null ? theme.colorScheme.outline : Color(category!.color);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Ledger.ruleOf(context)))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 10, height: 10, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(category == null ? tr('no_category') : state.categoryName(category!), overflow: TextOverflow.ellipsis),
          ),
          Text(formatAmount(amount, pattern: '#,##0.00'), style: mono(size: 14)),
          SizedBox(
            width: 44,
            child: Text('${(share * 100).round()}%',
                textAlign: TextAlign.end, style: mono(size: 12, weight: FontWeight.w400, color: theme.colorScheme.outline)),
          ),
        ]),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 20, right: 44),
          child: LedgerBar(value: share, color: color, height: 3),
        ),
      ]),
    );
  }
}

/// Categories × days (week, month) or × months (year), like the user's spreadsheet.
class _BreakdownGrid extends StatelessWidget {
  final AppState state;
  const _BreakdownGrid({required this.state});

  @override
  Widget build(BuildContext context) {
    final stats = state.periodStats!;
    final period = stats.period;
    final theme = Theme.of(context);
    final buckets = period.buckets;
    final now = DateTime.now();
    final isYear = period.type == PeriodType.year;
    final budgetOn = state.budgetEnabled;

    final rowKeys = [
      for (final c in state.categoriesOf(TxnKind.expense))
        if (stats.grid.containsKey(c.id)) c.id,
      if (stats.grid.containsKey(null)) null,
    ];

    String cell(int v) => v == 0 ? '' : formatAmount(v);
    final cellWidth = period.type == PeriodType.week ? 76.0 : 64.0;
    final rule = Ledger.ruleOf(context);
    final small = mono(size: 12, weight: FontWeight.w400, color: theme.colorScheme.onSurface);
    final bold = small.copyWith(fontWeight: FontWeight.w600);
    // The first column fits its longest label ("Остаток нарастающим итогом", long category names).
    final firstLabels = [
      for (final key in rowKeys) key == null ? tr('no_category') : state.categoryName(state.categoryById[key]!),
      tr(isYear ? 'grid_budget' : 'grid_limit'),
      tr(isYear ? 'grid_month_left' : 'grid_day_left'),
      tr('grid_running'),
    ];
    double textWidth(String s, TextStyle style) => (TextPainter(
          text: TextSpan(text: s, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout())
            .width;
    final firstWidth = math.max(
          textWidth(tr(isYear ? 'grid_month_total' : 'grid_day_total'), bold),
          firstLabels.map((s) => textWidth(s, small)).fold(0.0, math.max),
        ).clamp(122.0, 230.0) +
        20;
    final head = mono(size: 10.5, weight: FontWeight.w500, color: theme.colorScheme.surface, spacing: 0.4);
    Color signColor(num v) => Ledger.signOf(context, v);

    Widget box(String text, {double? width, TextStyle? style, Color? color, bool left = false}) => Container(
          width: width ?? cellWidth,
          height: 32,
          alignment: left ? Alignment.centerLeft : Alignment.centerRight,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: color,
            border: Border(right: BorderSide(color: rule), bottom: BorderSide(color: rule)),
          ),
          child: Text(text, style: style ?? small, maxLines: 1, overflow: TextOverflow.ellipsis),
        );
    final ink = Ledger.inkOf(context);

    // Leftover per bucket and running total, only for buckets that have started.
    final dayLeft = <int?>[];
    final running = <int?>[];
    var acc = 0;
    for (var i = 0; i < buckets.length; i++) {
      if (buckets[i].isAfter(now)) {
        dayLeft.add(null);
        running.add(null);
        continue;
      }
      final left = stats.budgetByBucket[i] - stats.spentByBucket[i];
      acc += left;
      dayLeft.add(left);
      running.add(acc);
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          box(tr('grid_category').toUpperCase(), width: firstWidth, style: head, color: ink, left: true),
          for (final b in buckets) box(period.bucketLabel(b), style: head, color: ink),
          box(tr('grid_total').toUpperCase(), style: head, color: ink),
        ]),
        for (final key in rowKeys)
          Row(children: [
            box(key == null ? tr('no_category') : state.categoryName(state.categoryById[key]!), width: firstWidth, left: true),
            for (var i = 0; i < buckets.length; i++) box(cell(stats.grid[key]![i])),
            box(cell(stats.grid[key]!.fold(0, (a, b) => a + b)), style: bold),
          ]),
        const Divider(height: 1),
        Row(children: [
          box(isYear ? tr('grid_month_total') : tr('grid_day_total'), width: firstWidth, style: bold, left: true),
          for (var i = 0; i < buckets.length; i++)
            box(cell(stats.spentByBucket[i]),
                style: bold,
                color: !budgetOn || buckets[i].isAfter(now)
                    ? null
                    : stats.spentByBucket[i] > stats.budgetByBucket[i]
                        ? Ledger.overOf(context)
                        : Ledger.withinOf(context)),
          box(cell(stats.spentMinor), style: bold),
        ]),
        if (budgetOn) ...[
          Row(children: [
            box(isYear ? tr('grid_budget') : tr('grid_limit'), width: firstWidth, left: true),
            for (var i = 0; i < buckets.length; i++) box(cell(stats.budgetByBucket[i])),
            box(cell(stats.budgetMinor)),
          ]),
          Row(children: [
            box(isYear ? tr('grid_month_left') : tr('grid_day_left'), width: firstWidth, left: true),
            for (final v in dayLeft)
              box(v == null ? '' : formatAmount(v, pattern: '#,##0'), style: small.copyWith(color: signColor(v ?? 0))),
            box(formatAmount(stats.remainingMinor, pattern: '#,##0'), style: bold.copyWith(color: signColor(stats.remainingMinor))),
          ]),
          Row(children: [
            box(tr('grid_running'), width: firstWidth, left: true),
            for (final r in running)
              box(r == null ? '' : formatAmount(r, pattern: '#,##0'), style: small.copyWith(color: signColor(r ?? 0))),
            box(''),
          ]),
        ],
      ]),
    );
  }
}
