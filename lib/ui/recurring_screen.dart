import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../domain/currencies.dart';
import '../domain/money.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'ledger.dart';
import 'widgets.dart';

/// "In 2 days", "today", "3 days ago".
String dueIn(DateTime d) {
  final now = DateTime.now();
  final days = DateTime(d.year, d.month, d.day).difference(DateTime(now.year, now.month, now.day)).inDays;
  if (days == 0) return tr('due_today');
  if (days == 1) return tr('due_tomorrow');
  if (days < 0) return tr('due_overdue', [-days]);
  return tr('due_in', [days]);
}

/// Regular payments and incomes: rent, subscriptions, a stipend.
class RecurringScreen extends StatelessWidget {
  const RecurringScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('recurring'))),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'recurring_add',
        icon: const Icon(Icons.add),
        label: Text(tr('recurring_add')),
        onPressed: () => editRecurring(context),
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(tr('recurring_hint'), style: theme.textTheme.bodySmall?.copyWith(color: Ledger.mutedOf(context))),
        ),
        if (state.recurring.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(tr('recurring_empty'))),
        for (final r in state.recurring)
          ListTile(
            leading: CategoryAvatar(r.categoryId == null ? null : state.categoryById[r.categoryId], size: 36),
            title: Text(r.name),
            subtitle: Text('${tr('every_${r.every.name}')} · ${dueIn(r.next)}'),
            trailing: Text(
              formatMoney(r.kind == TxnKind.income ? r.amountMinor : -r.amountMinor, r.currency, signed: true),
              style: mono(size: 15, color: r.kind == TxnKind.income ? Ledger.goodOf(context) : null),
            ),
            onTap: () => editRecurring(context, r),
          ),
      ]),
    );
  }
}

Future<void> editRecurring(BuildContext context, [Recurring? r]) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => _RecurringEditor(r), fullscreenDialog: true));

class _RecurringEditor extends StatefulWidget {
  final Recurring? r;
  const _RecurringEditor(this.r);

  @override
  State<_RecurringEditor> createState() => _RecurringEditorState();
}

class _RecurringEditorState extends State<_RecurringEditor> {
  late final _name = TextEditingController(text: widget.r?.name ?? '');
  late final _amount = TextEditingController(text: widget.r == null ? '' : formatAmount(widget.r!.amountMinor, pattern: '0.##'));
  late TxnKind _kind = widget.r?.kind ?? TxnKind.expense;
  late Every _every = widget.r?.every ?? Every.month;
  late DateTime _next = widget.r?.next ?? _tomorrow();
  late int? _categoryId = widget.r?.categoryId;
  late int? _accountId = widget.r?.accountId;
  late bool _remind = widget.r?.remind ?? true;

  static DateTime _tomorrow() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day + 1);
  }

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    final amount = parseAmountToMinor(_amount.text);
    if (_name.text.trim().isEmpty || amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('recurring_fill'))));
      return;
    }
    final account = _accountId == null ? null : state.accountById[_accountId];
    final base = widget.r ??
        Recurring(
          name: '', amountMinor: 0, currency: state.baseCurrency, kind: _kind, every: _every, day: _next.day, next: _next);
    await state.saveRecurring(base.copyWith(
      name: _name.text.trim(),
      amountMinor: amount,
      currency: account?.currency ?? base.currency,
      kind: _kind,
      categoryId: () => _categoryId,
      accountId: () => _accountId,
      every: _every,
      day: _next.day,
      next: _next,
      remind: _remind,
    ));
    // Reminders need the permission to notify.
    if (_remind) await state.capture.requestPostNotifications();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    await context.read<AppState>().deleteRecurring(widget.r!);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final account = _accountId == null ? null : state.accountById[_accountId];
    final currency = account?.currency ?? widget.r?.currency ?? state.baseCurrency;
    final categories = state.categoriesOf(_kind);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.r == null ? tr('recurring_add') : tr('recurring')),
        actions: [
          if (widget.r != null) IconButton(tooltip: tr('delete'), icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        SegmentedButton<TxnKind>(
          segments: [
            ButtonSegment(value: TxnKind.expense, label: segmentLabel(tr('expense'))),
            ButtonSegment(value: TxnKind.income, label: segmentLabel(tr('income'))),
          ],
          selected: {_kind},
          onSelectionChanged: (s) => setState(() {
            _kind = s.first;
            _categoryId = null;
          }),
        ),
        const SizedBox(height: 12),
        TextField(controller: _name, decoration: InputDecoration(labelText: tr('recurring_name'))),
        TextField(
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: tr('amount'), suffixText: currencySymbol(currency)),
        ),
        const SizedBox(height: 16),
        SegmentedButton<Every>(
          segments: [for (final e in Every.values) ButtonSegment(value: e, label: segmentLabel(tr('every_${e.name}')))],
          selected: {_every},
          onSelectionChanged: (s) => setState(() => _every = s.first),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tr('recurring_next')),
          trailing: Text(DateFormat.yMMMd(intlLocale).format(_next), style: mono(size: 14)),
          onTap: () async {
            final d = await showDatePicker(
              context: context,
              initialDate: _next,
              firstDate: DateTime(2020),
              lastDate: DateTime(DateTime.now().year + 5),
            );
            if (d != null) setState(() => _next = d);
          },
        ),
        DropdownButtonFormField<int?>(
          isExpanded: true,
          initialValue: categories.any((c) => c.id == _categoryId) ? _categoryId : null,
          decoration: InputDecoration(labelText: tr('category')),
          items: [
            DropdownMenuItem(value: null, child: Text(tr('no_category'))),
            for (final c in categories) DropdownMenuItem(value: c.id, child: Text(state.categoryName(c))),
          ],
          onChanged: (v) => setState(() => _categoryId = v),
        ),
        DropdownButtonFormField<int?>(
          isExpanded: true,
          initialValue: _accountId,
          decoration: InputDecoration(labelText: tr('account')),
          items: [
            DropdownMenuItem(value: null, child: Text(tr('no_account'))),
            for (final a in state.accounts) DropdownMenuItem(value: a.id, child: Text(state.accountName(a))),
          ],
          onChanged: (v) => setState(() => _accountId = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _remind,
          onChanged: (v) => setState(() => _remind = v),
          title: Text(tr('recurring_remind')),
          subtitle: Text(tr('recurring_remind_sub')),
        ),
        const SizedBox(height: 16),
        FilledButton(onPressed: _save, child: Text(tr('save'))),
      ]),
    );
  }
}
