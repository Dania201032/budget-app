import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../domain/currencies.dart';
import '../domain/holding.dart';
import '../domain/money.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'ledger.dart';
import 'motion.dart';
import 'settings_screen.dart' show pickCurrency;

/// Money → Net worth: everything one has minus everything one owes, how it went month by month,
/// and the investments, property and loans that live outside the accounts.
class NetWorthScreen extends StatelessWidget {
  const NetWorthScreen({super.key});

  static const holdingTypes = ['deposit', 'savings', 'bonds', 'stocks', 'fund', 'property', 'loan', 'other'];

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final nw = state.netWorth;
    final cur = state.baseCurrency;
    final theme = Theme.of(context);
    final muted = Ledger.mutedOf(context);
    final history = state.netWorthHistory.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    final prev = history.length >= 2 ? history[history.length - 2].value : null;

    Widget line(String label, int v, {bool minus = false}) => v == 0
        ? const SizedBox.shrink()
        : LedgerTile(label, value: '${minus ? '−' : ''}${formatMoney(v, cur)}', valueColor: minus ? Ledger.badOf(context) : null);

    return Scaffold(
      appBar: AppBar(title: Text(tr('nw_title'))),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: Text(tr('nw_add')),
        onPressed: () => editHolding(context),
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            LedgerCaption(tr('nw_total')),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: AnimatedMoney(nw.total, cur, style: mono(size: 36, color: Ledger.accentOf(context))),
            ),
            if (prev != null)
              Text(
                tr('nw_change', [formatMoney(nw.total - prev, cur, signed: true)]),
                style: theme.textTheme.bodySmall?.copyWith(color: nw.total >= prev ? Ledger.goodOf(context) : Ledger.badOf(context)),
              ),
          ]),
        ),
        if (history.length >= 2) Padding(padding: const EdgeInsets.fromLTRB(8, 12, 16, 4), child: _HistoryChart(history)),
        LedgerSection(tr('nw_have')),
        line(tr('nw_accounts'), nw.accounts),
        line(tr('nw_goals'), nw.goals),
        line(tr('nw_investments'), nw.investments),
        line(tr('nw_property'), nw.property),
        line(tr('nw_owed_to_me'), nw.owedToMe),
        if (nw.debts > 0) ...[
          LedgerSection(tr('nw_owe')),
          line(tr('nw_cards'), nw.cards, minus: true),
          line(tr('nw_loans'), nw.loans, minus: true),
        ],
        LedgerSection(tr('nw_outside')),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text(tr('nw_outside_sub'), style: theme.textTheme.bodySmall?.copyWith(color: muted)),
        ),
        for (final h in [...state.holdings]..sort((a, b) => a.type.compareTo(b.type)))
          LedgerTile(
            h.name.isEmpty ? _capital(tr('d_type_${h.type}')) : h.name,
            hint: [tr('d_type_${h.type}'), if (h.ratePct != 0) '${NumberFormat('#,##0.##', intlLocale).format(h.ratePct)} %'].join(' · '),
            value: '${h.isLoan ? '−' : ''}${formatMoney(h.amountMinor, h.currency)}',
            valueColor: h.isLoan ? Ledger.badOf(context) : null,
            onTap: () => editHolding(context, h),
          ),
      ]),
    );
  }
}

String _capital(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// The net worth at the end of each recorded month: one line, the latest month labelled.
class _HistoryChart extends StatelessWidget {
  final List<MapEntry<String, int>> history;
  const _HistoryChart(this.history);

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final ink = Ledger.accentOf(context);
    final muted = Ledger.mutedOf(context);
    final points = [for (var i = 0; i < history.length; i++) FlSpot(i.toDouble(), history[i].value / 100)];
    String month(int i) {
      final p = history[i].key.split('-');
      return DateFormat('LLL', intlLocale).format(DateTime(int.parse(p[0]), int.parse(p[1])));
    }

    return SizedBox(
      height: 150,
      child: LineChart(LineChartData(
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: const AxisTitles(),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 20,
              interval: 1,
              getTitlesWidget: (v, m) {
                final i = v.round();
                if (i < 0 || i >= history.length || (history.length > 6 && i % 2 != history.length % 2 - 1 && i != history.length - 1)) {
                  return const SizedBox.shrink();
                }
                return Text(month(i), style: TextStyle(fontSize: 11, color: muted));
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => Ledger.inkOf(context),
            getTooltipItems: (spots) => [
              for (final s in spots)
                LineTooltipItem('${month(s.x.round())}  ${formatMoney((s.y * 100).round(), state.baseCurrency)}',
                    TextStyle(color: Theme.of(context).colorScheme.surface, fontSize: 12)),
            ],
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: points,
            isCurved: false,
            color: ink,
            barWidth: 2,
            dotData: FlDotData(checkToShowDot: (s, _) => s.x == points.last.x),
          ),
        ],
      )),
    );
  }
}

/// Adds or edits an investment, property or loan.
Future<void> editHolding(BuildContext context, [Holding? h]) async {
  final state = context.read<AppState>();
  var type = h?.type ?? 'deposit';
  var currency = h?.currency ?? state.baseCurrency;
  final name = TextEditingController(text: h?.name ?? '');
  final amount = TextEditingController(text: h == null ? '' : (h.amountMinor / 100).toStringAsFixed(h.amountMinor % 100 == 0 ? 0 : 2));
  final rate = TextEditingController(text: h == null || h.ratePct == 0 ? '' : '${h.ratePct}');
  final r = await showDialog<String>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => AlertDialog(
        title: Text(h == null ? tr('nw_add') : tr('edit')),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            DropdownButtonFormField<String>(
              initialValue: type,
              isExpanded: true,
              decoration: InputDecoration(labelText: tr('nw_kind')),
              items: [for (final t in NetWorthScreen.holdingTypes) DropdownMenuItem(value: t, child: Text(tr('d_type_$t')))],
              onChanged: (v) => setState(() => type = v ?? type),
            ),
            TextField(controller: name, decoration: InputDecoration(labelText: tr('name'))),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: amount,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: tr(type == 'loan' ? 'nw_owed_amount' : 'nw_amount')),
                ),
              ),
              TextButton(
                onPressed: () async {
                  final code = await pickCurrency(c, selected: currency);
                  if (code != null) setState(() => currency = code);
                },
                child: Text('${currencySymbol(currency)} $currency'),
              ),
            ]),
            TextField(
              controller: rate,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: tr(type == 'loan' ? 'nw_rate_loan' : 'nw_rate'), suffixText: '%'),
            ),
          ]),
        ),
        actions: [
          if (h != null) TextButton(onPressed: () => Navigator.pop(c, 'delete'), child: Text(tr('delete'))),
          TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, 'save'), child: Text(tr('save'))),
        ],
      ),
    ),
  );
  if (r == 'delete' && h != null) return state.deleteHolding(h);
  if (r != 'save') return;
  final minor = parseAmountToMinor(amount.text);
  if (minor == null) return;
  await state.saveHolding(Holding(
    id: h?.id ?? '${DateTime.now().microsecondsSinceEpoch}',
    type: type,
    name: name.text.trim(),
    where: h?.where ?? '',
    currency: currency,
    amountMinor: minor,
    ratePct: double.tryParse(rate.text.replaceAll(',', '.')) ?? 0,
    payout: h?.payout ?? (type == 'property' ? 'none' : 'monthly'),
    receivedMinor: h?.receivedMinor ?? 0,
    nextPayment: h?.nextPayment,
    maturity: h?.maturity,
    counted: h?.counted ?? true,
  ));
}
