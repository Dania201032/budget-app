import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../domain/currencies.dart';
import '../domain/money.dart';
import '../domain/runway.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'ledger.dart';

/// Every input of the "how long will the money last" forecast, saved as you change it.
class RunwaySettingsScreen extends StatelessWidget {
  const RunwaySettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final c = state.runwayConfig;
    final cur = state.baseCurrency;
    void save(RunwayConfig n) => state.saveRunwayConfig(n);

    Widget section(String title, {String? subtitle}) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: theme.textTheme.titleMedium),
            if (subtitle != null) Text(subtitle, style: theme.textTheme.bodySmall),
          ]),
        );

    Future<int?> amount(String title, int current) async {
      final controller = TextEditingController(text: current == 0 ? '' : (current / 100).toStringAsFixed(0));
      return showDialog<int>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(suffixText: currencySymbol(cur)),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('cancel'))),
            FilledButton(
              onPressed: () => Navigator.pop(d, controller.text.trim().isEmpty ? 0 : parseAmountToMinor(controller.text)),
              child: Text(tr('save')),
            ),
          ],
        ),
      );
    }

    final selected = c.accountIds ?? state.balances.keys.toSet();

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('runway_settings')),
        actions: [
          // An icon: the long title of this screen needs the room (“Prognose-Einstellungen”).
          IconButton(
            tooltip: tr('reset_defaults'),
            icon: const Icon(Icons.restart_alt),
            onPressed: () => save(const RunwayConfig()),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        // --- Money now ---
        section(tr('rs_money'), subtitle: tr('rs_money_total', [formatMoney(state.runwayStart(c), cur)])),
        for (final a in state.accounts)
          CheckboxListTile(
            value: selected.contains(a.id) && state.balances.containsKey(a.id),
            title: Text(state.accountName(a)),
            subtitle: Text(state.balances.containsKey(a.id)
                ? formatMoney(state.balances[a.id]!, a.currency)
                : tr('balance_not_set')),
            onChanged: state.balances.containsKey(a.id)
                ? (v) {
                    final s = {...selected};
                    v == true ? s.add(a.id) : s.remove(a.id);
                    save(c.copyWith(accountIds: () => s));
                  }
                : null,
          ),
        SwitchListTile(
          value: c.includeGoalSavings,
          title: Text(tr('rs_include_goals')),
          subtitle: Text(tr('rs_include_goals_sub')),
          onChanged: (v) => save(c.copyWith(includeGoalSavings: v)),
        ),
        ListTile(
          title: Text(tr('rs_extra')),
          subtitle: Text(tr('rs_extra_sub')),
          trailing: Text(formatMoney(c.extraMinor, cur)),
          onTap: () async {
            final v = await amount(tr('rs_extra'), c.extraMinor);
            if (v != null) save(c.copyWith(extraMinor: v));
          },
        ),

        // --- Spending ---
        section(tr('rs_spend')),
        RadioGroup<SpendMode>(
          groupValue: c.spendMode,
          onChanged: (m) => save(c.copyWith(spendMode: m)),
          child: Column(children: [
            RadioListTile(value: SpendMode.average, title: Text(tr('rs_spend_average'))),
            RadioListTile(value: SpendMode.budget, title: Text(tr('rs_spend_budget')), enabled: state.budgetEnabled),
            RadioListTile(
              value: SpendMode.custom,
              title: Text(tr('rs_spend_custom')),
              subtitle: c.spendMode == SpendMode.custom ? Text(formatMoney(c.customSpendPerMonthMinor, cur)) : null,
            ),
          ]),
        ),
        if (c.spendMode == SpendMode.custom)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () async {
                final v = await amount(tr('rs_spend_custom'), c.customSpendPerMonthMinor);
                if (v != null) save(c.copyWith(customSpendPerMonthMinor: v));
              },
              child: Text(tr('edit')),
            ),
          ),
        if (c.spendMode == SpendMode.average || c.incomeMode == IncomeMode.average) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(tr('rs_window'), style: theme.textTheme.bodyMedium),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(spacing: 8, children: [
              for (final d in [14, 30, 60, 90, 180])
                ChoiceChip(
                  label: Text(tr('rs_days', [d])),
                  selected: c.averageDays == d,
                  onSelected: (_) => save(c.copyWith(averageDays: d)),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(tr('rs_excluded'), style: theme.textTheme.bodyMedium),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final cat in state.categoriesOf(TxnKind.expense))
                FilterChip(
                  label: Text(state.categoryName(cat)),
                  selected: c.excludedCategories.contains(cat.id),
                  onSelected: (v) {
                    final s = {...c.excludedCategories};
                    v ? s.add(cat.id) : s.remove(cat.id);
                    save(c.copyWith(excludedCategories: s));
                  },
                ),
            ]),
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            c.adjustPercent == 0
                ? tr('runway_adjust_none')
                : tr(c.adjustPercent < 0 ? 'runway_adjust_less' : 'runway_adjust_more', [c.adjustPercent.abs()]),
          ),
        ),
        Slider(
          value: c.adjustPercent.toDouble(),
          min: -50,
          max: 50,
          divisions: 20,
          label: '${c.adjustPercent > 0 ? '+' : ''}${c.adjustPercent}%',
          onChanged: (v) => save(c.copyWith(adjustPercent: v.round())),
        ),

        // --- Income ---
        section(tr('rs_income')),
        RadioGroup<IncomeMode>(
          groupValue: c.incomeMode,
          onChanged: (m) => save(c.copyWith(incomeMode: m)),
          child: Column(children: [
            RadioListTile(value: IncomeMode.none, title: Text(tr('rs_income_none'))),
            RadioListTile(value: IncomeMode.average, title: Text(tr('rs_income_average'))),
            RadioListTile(
              value: IncomeMode.custom,
              title: Text(tr('rs_income_custom')),
              subtitle: c.incomeMode == IncomeMode.custom ? Text(formatMoney(c.customIncomePerMonthMinor, cur)) : null,
            ),
          ]),
        ),
        if (c.incomeMode == IncomeMode.custom)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () async {
                final v = await amount(tr('rs_income_custom'), c.customIncomePerMonthMinor);
                if (v != null) save(c.copyWith(customIncomePerMonthMinor: v));
              },
              child: Text(tr('edit')),
            ),
          ),

        // --- Reserve ---
        section(tr('runway_reserve')),
        ListTile(
          title: Text(tr('rs_reserve_sub')),
          trailing: Text(formatMoney(c.reserveMinor, cur)),
          onTap: () async {
            final v = await amount(tr('runway_reserve'), c.reserveMinor);
            if (v != null) save(c.copyWith(reserveMinor: v));
          },
        ),

        // --- Planned one-offs ---
        section(tr('rs_planned'), subtitle: tr('rs_planned_sub')),
        SwitchListTile(
          value: c.useRecurring,
          title: Text(tr('rs_recurring')),
          subtitle: Text(tr('rs_recurring_sub', [context.watch<AppState>().recurring.length])),
          onChanged: (v) => save(c.copyWith(useRecurring: v)),
        ),
        for (var i = 0; i < c.planned.length; i++)
          ListTile(
            leading: Icon(c.planned[i].amountMinor >= 0 ? Icons.arrow_downward : Icons.arrow_upward,
                color: c.planned[i].amountMinor >= 0 ? Colors.green.shade600 : null),
            title: Text(c.planned[i].name),
            subtitle: Text(DateFormat.yMMMd(intlLocale).format(c.planned[i].date)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(formatMoney(c.planned[i].amountMinor, cur, signed: true)),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => save(c.copyWith(planned: [...c.planned]..removeAt(i))),
              ),
            ]),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.add),
            label: Text(tr('rs_add_planned')),
            onPressed: () async {
              final item = await _plannedDialog(context, cur);
              if (item != null) save(c.copyWith(planned: [...c.planned, item]..sort((a, b) => a.date.compareTo(b.date))));
            },
          ),
        ),

        // --- Chart & target ---
        section(tr('rs_chart')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: 8, children: [
            for (final m in [3, 6, 12, 24, 60])
              ChoiceChip(
                label: Text(tr('rs_months', [m])),
                selected: c.horizonMonths == m,
                onSelected: (_) => save(c.copyWith(horizonMonths: m)),
              ),
          ]),
        ),
        ListTile(
          leading: const Icon(Icons.flag_outlined),
          title: Text(tr('rs_target')),
          subtitle: Text(c.targetDate == null ? tr('rs_target_none') : DateFormat.yMMMMd(intlLocale).format(c.targetDate!)),
          trailing: c.targetDate == null
              ? null
              : IconButton(icon: const Icon(Icons.clear), onPressed: () => save(c.copyWith(targetDate: () => null))),
          onTap: () async {
            final now = DateTime.now();
            final d = await showDatePicker(
              context: context,
              initialDate: c.targetDate ?? DateTime(now.year, now.month + 6, now.day),
              firstDate: now,
              lastDate: DateTime(now.year + 30),
            );
            if (d != null) save(c.copyWith(targetDate: () => d));
          },
        ),
      ]),
    );
  }
}

Future<PlannedItem?> _plannedDialog(BuildContext context, String currency) {
  final name = TextEditingController();
  final amount = TextEditingController();
  var income = false;
  var date = DateTime.now().add(const Duration(days: 30));
  return showDialog<PlannedItem>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => AlertDialog(
        title: Text(tr('rs_add_planned')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: false, label: segmentLabel(tr('expense'))),
              ButtonSegment(value: true, label: segmentLabel(tr('income_one'))),
            ],
            selected: {income},
            onSelectionChanged: (s) => setState(() => income = s.first),
          ),
          TextField(controller: name, decoration: InputDecoration(labelText: tr('name'))),
          TextField(
            controller: amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: tr('col_amount'), suffixText: currencySymbol(currency)),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event),
            title: Text(DateFormat.yMMMMd(intlLocale).format(date)),
            onTap: () async {
              final d = await showDatePicker(
                context: c,
                initialDate: date,
                firstDate: DateTime.now(),
                lastDate: DateTime(DateTime.now().year + 30),
              );
              if (d != null) setState(() => date = d);
            },
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('cancel'))),
          FilledButton(
            onPressed: () {
              final v = parseAmountToMinor(amount.text);
              if (v == null || name.text.trim().isEmpty) return;
              Navigator.pop(c, PlannedItem(name: name.text.trim(), amountMinor: income ? v : -v, date: date));
            },
            child: Text(tr('save')),
          ),
        ],
      ),
    ),
  );
}
