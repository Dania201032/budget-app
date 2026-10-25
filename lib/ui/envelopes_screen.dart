import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../domain/currencies.dart';
import '../domain/envelopes.dart';
import '../domain/money.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'ledger.dart';
import '../premium/premium.dart';
import 'plus_screen.dart';

/// Envelope budgeting: each category's money for the month, what is left after carrying the past
/// months, and moving money between envelopes.
class EnvelopesScreen extends StatefulWidget {
  const EnvelopesScreen({super.key});
  @override
  State<EnvelopesScreen> createState() => _EnvelopesScreenState();
}

class _EnvelopesScreenState extends State<EnvelopesScreen> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final muted = Ledger.mutedOf(context);
    final cur = state.baseCurrency;

    if (!state.envelopes.on) {
      return Scaffold(
        appBar: AppBar(title: Text(tr('env_title'))),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Text(tr('env_intro')),
          const SizedBox(height: 8),
          Text(tr('env_intro_sub'), style: theme.textTheme.bodySmall?.copyWith(color: muted)),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () async {
              if (await requirePlus(context, PlusFeature.envelopes)) await state.setEnvelopesOn(true);
            },
            child: Text(tr('env_turn_on')),
          ),
        ]),
      );
    }

    final start = state.envelopes.start;
    final first = start == null ? _month : DateTime(int.parse(start.split('-')[0]), int.parse(start.split('-')[1]));
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('env_title')),
        actions: [
          IconButton(tooltip: tr('env_move'), icon: const Icon(Icons.swap_horiz), onPressed: () => _move(context, state)),
          PopupMenuButton<String>(
            onSelected: (_) => state.setEnvelopesOn(false),
            itemBuilder: (_) => [PopupMenuItem(value: 'off', child: Text(tr('env_turn_off')))],
          ),
        ],
      ),
      body: FutureBuilder<List<Envelope>>(
        future: state.envelopesFor(_month),
        builder: (context, snap) {
          final list = snap.data;
          if (list == null) return const Center(child: CircularProgressIndicator());
          final toAssign = state.envelopesToAssign(_month, list);
          final over = list.where((e) => e.available < 0).length;
          return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
            Row(children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: _month.isAfter(first) ? () => setState(() => _month = DateTime(_month.year, _month.month - 1)) : null,
              ),
              Expanded(
                child: Text(DateFormat.yMMMM(intlLocale).format(_month), textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: _month.isBefore(DateTime(now.year, now.month)) ? () => setState(() => _month = DateTime(_month.year, _month.month + 1)) : null,
              ),
            ]),
            if (state.budgetEnabled)
              LedgerTile(
                tr('env_to_assign'),
                hint: tr('env_to_assign_sub', [formatMoney(state.commonBudget(_month), cur)]),
                value: formatMoney(toAssign, cur),
                valueColor: toAssign < 0 ? Ledger.badOf(context) : Ledger.goodOf(context),
              ),
            if (over > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(tr('env_over', [over]), style: theme.textTheme.bodySmall?.copyWith(color: Ledger.badOf(context))),
              ),
            LedgerSection(tr('env_envelopes')),
            for (final e in list) _EnvelopeTile(e, month: _month),
          ]);
        },
      ),
    );
  }

  Future<void> _move(BuildContext context, AppState state) async {
    if (!await requirePlus(context, PlusFeature.envelopes) || !context.mounted) return;
    final cats = state.categoriesOf(TxnKind.expense);
    if (cats.length < 2) return;
    var from = cats.first, to = cats[1];
    final amount = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setState) => AlertDialog(
          title: Text(tr('env_move')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<Category>(
              initialValue: from,
              isExpanded: true,
              decoration: InputDecoration(labelText: tr('env_from')),
              items: [for (final x in cats) DropdownMenuItem(value: x, child: Text(state.categoryName(x)))],
              onChanged: (v) => setState(() => from = v ?? from),
            ),
            DropdownButtonFormField<Category>(
              initialValue: to,
              isExpanded: true,
              decoration: InputDecoration(labelText: tr('env_to')),
              items: [for (final x in cats) DropdownMenuItem(value: x, child: Text(state.categoryName(x)))],
              onChanged: (v) => setState(() => to = v ?? to),
            ),
            TextField(
              controller: amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: tr('amount'), suffixText: currencySymbol(state.baseCurrency)),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('env_move_do'))),
          ],
        ),
      ),
    );
    final v = parseAmountToMinor(amount.text);
    if (ok == true && v != null && from.id != to.id) await state.moveEnvelope(from, to, _month, v);
  }
}

class _EnvelopeTile extends StatelessWidget {
  final Envelope e;
  final DateTime month;
  const _EnvelopeTile(this.e, {required this.month});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = state.categoryById[e.categoryId];
    if (c == null) return const SizedBox.shrink();
    final cur = state.baseCurrency;
    final theme = Theme.of(context);
    final muted = Ledger.mutedOf(context);
    // Spent against what the envelope held this month (its carry included).
    final held = e.available + e.spent;
    return InkWell(
      onTap: () => _edit(context, state, c),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Ledger.ruleOf(context)))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 8, height: 8, color: Color(c.color)),
            const SizedBox(width: 8),
            Expanded(child: Text(state.categoryName(c), overflow: TextOverflow.ellipsis)),
            Text(formatMoney(e.available, cur),
                style: mono(size: 15, color: e.available < 0 ? Ledger.badOf(context) : (e.available == 0 ? muted : null))),
          ]),
          const SizedBox(height: 6),
          LedgerBar(
            value: held <= 0 ? (e.spent > 0 ? 1 : 0) : (e.spent / held).clamp(0, 1).toDouble(),
            height: 6,
            color: e.available < 0 ? Ledger.badOf(context) : null,
          ),
          const SizedBox(height: 4),
          Text(
            tr('env_line', [formatMoney(e.allocated, cur), formatMoney(e.spent, cur)]),
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ]),
      ),
    );
  }

  Future<void> _edit(BuildContext context, AppState state, Category c) async {
    if (!await requirePlus(context, PlusFeature.envelopes) || !context.mounted) return;
    var everyMonth = false;
    final ctrl = TextEditingController(text: e.allocated == 0 ? '' : (e.allocated / 100).toStringAsFixed(e.allocated % 100 == 0 ? 0 : 2));
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setState) => AlertDialog(
          title: Text(state.categoryName(c)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: tr('env_put_in'), suffixText: currencySymbol(state.baseCurrency)),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: everyMonth,
              title: Text(tr('env_every_month')),
              onChanged: (v) => setState(() => everyMonth = v ?? false),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('save'))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final v = ctrl.text.trim().isEmpty ? 0 : parseAmountToMinor(ctrl.text);
    if (v != null) await state.setEnvelope(c, month, v, everyMonth: everyMonth);
  }
}
