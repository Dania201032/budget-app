import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../domain/budget_math.dart';
import '../domain/currencies.dart';
import '../domain/money.dart';
import '../domain/periods.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'ledger.dart';
import 'motion.dart';
import 'money_screen.dart';
import 'overview_screen.dart';
import 'recurring_screen.dart';
import 'review_screen.dart';
import 'settings_screen.dart';
import 'search_screen.dart';
import 'txn_editor.dart';
import 'widgets.dart';

/// Whether the "Add" button shows (it steps aside while the list scrolls down).
final _homeFab = ValueNotifier(true);

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final stats = state.homeStats;
    if (stats == null) return const Center(child: CircularProgressIndicator());
    final period = state.homePeriod;
    final showCalendar = period.type == PeriodType.month || period.type == PeriodType.week;

    final byDay = <DateTime, List<Txn>>{};
    for (final t in state.homeTxns) {
      byDay.putIfAbsent(DateTime(t.time.year, t.time.month, t.time.day), () => []).add(t);
    }
    final items = <Widget>[
      if (!state.captureStatus.allOn) const _CaptureSetupBanner(),
      if (state.reviewQueue.isNotEmpty) _ReviewBanner(count: state.reviewQueue.length),
      if (state.staleAccounts.isNotEmpty && !state.staleHintHidden) _StaleBanner(accounts: state.staleAccounts),
      if (state.recurringSoon.isNotEmpty) _SoonBlock(items: state.recurringSoon),
      if (state.owedToMeMinor > 0) _DebtsBanner(amount: state.owedToMeMinor, currency: state.baseCurrency),
      if (state.budgetEnabled && stats.isCurrent && state.todayStats != null)
        _TodayBlock(stats: state.todayStats!, reserve: state.goalReserve(DateTime.now()), currency: state.baseCurrency),
      _PeriodSummary(stats: stats, currency: state.baseCurrency, budgetOn: state.budgetEnabled),
      if (showCalendar) ...[
        LedgerSection(tr('by_days'), padding: const EdgeInsets.fromLTRB(16, 22, 16, 10)),
        PeriodCalendar(state: state, stats: stats, txns: state.homeTxns, showHint: false),
      ],
      if (state.homeTxns.isEmpty) Padding(padding: const EdgeInsets.all(32), child: Center(child: Text(tr('no_ops')))),
      for (final entry in byDay.entries) ...[
        _DayHeader(day: entry.key, txns: entry.value),
        for (final t in entry.value) TxnTile(t, onTap: () => openTxnEditor(context, txn: t)),
      ],
    ];

    return Scaffold(
      appBar: AppBar(
        title: PeriodSwitcher(period: period, onChanged: state.setHomePeriod),
        bottom: periodTypeBar(period.type, state.setHomePeriodType),
        actions: [IconButton(tooltip: tr('search'), icon: const Icon(Icons.search), onPressed: () => openSearch(context))],
      ),
      floatingActionButton: ScrollAwareFab(
        visible: _homeFab,
        child: FloatingActionButton.extended(
          heroTag: 'home_add',
          onPressed: () => openTxnEditor(context),
          icon: const Icon(Icons.add),
          label: Text(tr('add')),
        ),
      ),
      body: hideFabOnScroll(
        _homeFab,
        SwipeToChange(
          onPrevious: () => state.setHomePeriod(period.shift(-1)),
          onNext: () => state.setHomePeriod(period.shift(1)),
          child: RefreshIndicator(
            onRefresh: state.refresh,
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: items.length,
              itemBuilder: (_, i) => items[i],
            ),
          ),
        ),
      ),
    );
  }
}

/// "You can still spend today" as one big figure, with the day's limit and spending beside it.
class _TodayBlock extends StatelessWidget {
  final MonthStats stats;
  final int reserve;
  final String currency;
  const _TodayBlock({required this.stats, required this.reserve, required this.currency});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final left = stats.todayLeft.round();
    final over = left < 0;
    final muted = Ledger.mutedOf(context);
    final small = theme.textTheme.bodySmall?.copyWith(color: muted);

    Widget mini(String label, String value) => Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: small),
            const SizedBox(width: 10),
            Text(value, style: mono(size: 12.5)),
          ]),
        );

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Ledger.ruleOf(context)))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        LedgerCaption(over ? tr('today_over') : tr('today_left')),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: AnimatedValue(
                value: left.toDouble(),
                builder: (context, v) => Text(
                  formatMoney(v.round().abs(), currency),
                  style: mono(size: 42, color: over ? Ledger.badOf(context) : Ledger.accentOf(context), height: 1.05),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            mini(tr('day_limit_short'), formatMoney(stats.todayAllowance.round(), currency)),
            mini(tr('spent_short'), formatMoney(stats.spentTodayMinor, currency)),
          ]),
        ]),
        const SizedBox(height: 10),
        // How the day's limit is counted; a tap switches between the two ways.
        InkWell(
          onTap: () => chooseDailyLimitMode(context),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  tr(stats.fixedDaily ? 'today_formula_fixed' : 'today_formula',
                      [formatMoney(stats.todayAllowance.round(), currency), formatMoney(stats.spentTodayMinor, currency)]),
                  style: small,
                ),
                Text(
                  stats.fixedDaily
                      ? tr('even_daily_limit', [formatMoney(stats.evenAllowance.round(), currency)])
                      : tr('usual_daily_limit', [formatMoney(stats.dailyLimit.round(), currency)]),
                  style: small,
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 2),
              child: Icon(Icons.swap_horiz, size: 18, color: muted, semanticLabel: tr('daily_limit_mode')),
            ),
          ]),
        ),
        if (reserve > 0) Text(tr('goal_reserve_note', [formatMoney(reserve, currency)]), style: small),
      ]),
    );
  }
}

/// The period's figures as ledger lines.
class _PeriodSummary extends StatelessWidget {
  final PeriodStats stats;
  final String currency;
  final bool budgetOn;
  const _PeriodSummary({required this.stats, required this.currency, required this.budgetOn});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String m(num v) => formatMoney(v.round(), currency);
    final current = stats.isCurrent && stats.period.type != PeriodType.day;
    final daysLeftAfterToday = stats.daysTotal - stats.daysPassed;
    Color? bad(bool isBad) => isBad ? Ledger.badOf(context) : null;
    final muted = Ledger.mutedOf(context);

    if (!budgetOn) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          LedgerCaption(tr('spent')),
          const SizedBox(height: 2),
          AnimatedMoney(stats.spentMinor, currency, style: mono(size: 30)),
          const SizedBox(height: 8),
          LedgerRow(tr('income'), m(stats.incomeMinor), valueColor: Ledger.goodOf(context)),
          LedgerRow(tr('net'), m(stats.incomeMinor - stats.spentMinor), valueColor: bad(stats.incomeMinor < stats.spentMinor)),
          if (current) ...[
            LedgerRow(tr('avg_per_day'), m(stats.averagePerDay)),
            LedgerRow(tr('forecast_spent'), m(stats.forecastSpent)),
          ],
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: Text(tr('budget_off_card_sub'), style: theme.textTheme.bodySmall?.copyWith(color: muted))),
            TextButton(onPressed: () => editBudgetDialog(context), child: Text(tr('turn_on'))),
          ]),
        ]),
      );
    }

    final progress = stats.budgetMinor == 0 ? 0.0 : (stats.spentMinor / stats.budgetMinor).clamp(0.0, 1.0);
    final pace = stats.daysTotal == 0 ? 0.0 : stats.budgetMinor * stats.daysPassed / stats.daysTotal - stats.spentMinor;
    final elapsed = current && stats.daysTotal > 0 ? stats.daysPassed / stats.daysTotal : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: LedgerCaption(tr('spent'))),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: tr('edit_budget'),
            icon: Icon(Icons.edit_outlined, size: 18, color: muted),
            onPressed: () => editBudgetDialog(context),
          ),
        ]),
        Text.rich(TextSpan(children: [
          TextSpan(text: m(stats.spentMinor), style: mono(size: 24)),
          TextSpan(text: '  ${tr('spent_of', [m(stats.budgetMinor)])}', style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
        ])),
        const SizedBox(height: 6),
        LedgerBar(value: progress, tick: elapsed, color: stats.spentMinor > stats.budgetMinor ? Ledger.badOf(context) : null),
        const SizedBox(height: 4),
        LedgerRow(tr('budget_left'), m(stats.remainingMinor), valueColor: bad(stats.remainingMinor < 0), bold: true),
        if (current) ...[
          if (daysLeftAfterToday > 0)
            LedgerRow(tr('per_day_from_tomorrow'), m(stats.remainingMinor / daysLeftAfterToday),
                valueColor: bad(stats.remainingMinor < 0)),
          LedgerRow(tr('pace'), '${pace >= 0 ? '+' : ''}${m(pace)}', valueColor: Ledger.signOf(context, pace)),
          LedgerRow(tr('avg_per_day'), m(stats.averagePerDay)),
          LedgerRow(tr('forecast_left'), m(stats.forecastRemainder), valueColor: bad(stats.forecastRemainder < 0)),
        ],
        if (stats.incomeMinor > 0) LedgerRow(tr('income'), m(stats.incomeMinor), valueColor: Ledger.goodOf(context)),
      ]),
    );
  }
}

class _DayHeader extends StatelessWidget {
  final DateTime day;
  final List<Txn> txns;
  const _DayHeader({required this.day, required this.txns});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final spent = txns
        .where((t) => t.kind == TxnKind.expense && !t.excluded)
        .fold<int>(0, (s, t) => s + (state.toBase(t) ?? 0));
    return LedgerSection(
      dayHeader(day),
      trailing: spent > 0 ? formatMoney(-spent, state.baseCurrency) : null,
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 0),
    );
  }
}

/// A notice row: tinted box with a hairline border.
class _Notice extends StatelessWidget {
  final Color? color;
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  /// "Later": a close button instead of the arrow.
  final VoidCallback? onClose;
  const _Notice({this.color, required this.icon, required this.title, this.subtitle, required this.onTap, this.onClose});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Material(
        color: color ?? Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3), side: BorderSide(color: Ledger.ruleOf(context))),
        child: ListTile(
        leading: Icon(icon, color: Ledger.inkOf(context)),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: subtitle == null ? null : Text(subtitle!),
        trailing: onClose == null
            ? const Icon(Icons.chevron_right)
            : IconButton(icon: const Icon(Icons.close), tooltip: tr('later'), onPressed: onClose),
        onTap: onTap,
        ),
      ),
    );
  }
}

class _ReviewBanner extends StatelessWidget {
  final int count;
  const _ReviewBanner({required this.count});

  @override
  Widget build(BuildContext context) => _Notice(
        color: Ledger.overOf(context),
        icon: Icons.bolt,
        title: tr('review_banner', [count]),
        subtitle: tr('tap_to_review'),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ReviewScreen())),
      );
}

class _DebtsBanner extends StatelessWidget {
  final int amount;
  final String currency;
  const _DebtsBanner({required this.amount, required this.currency});

  @override
  Widget build(BuildContext context) => _Notice(
        color: Ledger.withinOf(context),
        icon: Icons.call_split,
        title: tr('owed_to_you', [formatMoney(amount, currency)]),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DebtsScreen())),
      );
}

class _CaptureSetupBanner extends StatelessWidget {
  const _CaptureSetupBanner();

  @override
  Widget build(BuildContext context) => _Notice(
        icon: Icons.auto_awesome,
        title: tr('capture_banner'),
        subtitle: tr('capture_banner_sub'),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CaptureSetupScreen())),
      );
}

Future<void> editBudgetDialog(BuildContext context) async {
  final state = context.read<AppState>();
  final now = DateTime.now();
  final current = state.rawMonthBudget(now);
  final v = await askAmount(
    context,
    title: tr('budget_dialog'),
    initial: current == 0 ? '' : (current / 100).toStringAsFixed(0),
    suffix: currencySymbol(state.baseCurrency),
  );
  if (v != null && v > 0) await state.setBudget(v);
}

/// The day's limit: what is left of the budget ÷ the days left (by default), or the same
/// budget ÷ days in the month every day.
Future<void> chooseDailyLimitMode(BuildContext context) {
  final state = context.read<AppState>();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(tr('daily_limit_mode'), style: Theme.of(sheet).textTheme.titleMedium),
        ),
        RadioGroup<bool>(
          groupValue: state.fixedDailyLimit,
          onChanged: (v) {
            Navigator.of(sheet).pop();
            if (v != null && v != state.fixedDailyLimit) state.setFixedDailyLimit(v);
          },
          child: Column(children: [
            RadioListTile<bool>(
              value: false,
              title: Text(tr('daily_limit_even')),
              subtitle: Text(tr('daily_limit_even_sub')),
            ),
            RadioListTile<bool>(
              value: true,
              title: Text(tr('daily_limit_fixed')),
              subtitle: Text(tr('daily_limit_fixed_sub')),
            ),
          ]),
        ),
        const SizedBox(height: 12),
      ]),
    ),
  );
}

/// Balances not checked for two weeks: cash and unnotified operations make them drift.
class _StaleBanner extends StatelessWidget {
  final List<Account> accounts;
  const _StaleBanner({required this.accounts});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    return _Notice(
      icon: Icons.account_balance_wallet_outlined,
      title: tr('stale_title'),
      subtitle: tr('stale_sub', [accounts.map(state.accountName).join(', ')]),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MoneyScreen())),
      onClose: state.hideStaleHint,
    );
  }
}

/// Regular payments and incomes due within a week (or overdue): record or skip in one tap.
class _SoonBlock extends StatelessWidget {
  final List<Recurring> items;
  const _SoonBlock({required this.items});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final theme = Theme.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LedgerSection(tr('soon'), padding: const EdgeInsets.fromLTRB(16, 18, 16, 4)),
      for (final r in items)
        ListTile(
          contentPadding: const EdgeInsets.only(left: 16, right: 4),
          title: Text(r.name),
          subtitle: Text(
            '${dueIn(r.next)} · ${formatMoney(r.kind == TxnKind.income ? r.amountMinor : -r.amountMinor, r.currency, signed: true)}',
            style: r.next.isBefore(today) ? TextStyle(color: Ledger.badOf(context)) : null,
          ),
          onTap: () => editRecurring(context, r),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            TextButton(onPressed: () => state.recordRecurring(r), child: Text(tr('recurring_record'))),
            IconButton(
              tooltip: tr('recurring_skip'),
              icon: Icon(Icons.redo, color: theme.colorScheme.outline),
              onPressed: () => state.skipRecurring(r),
            ),
          ]),
        ),
    ]);
  }
}
