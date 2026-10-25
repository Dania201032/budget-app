import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../domain/currencies.dart';
import '../domain/money.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'ledger.dart';
import 'motion.dart';
import 'net_worth_screen.dart';
import 'settings_screen.dart';
import 'widgets.dart';

/// Accounts with balances, savings goals and what friends owe.
/// Whether the "New goal" button shows (it steps aside while the list scrolls down).
final _moneyFab = ValueNotifier(true);

class MoneyScreen extends StatelessWidget {
  const MoneyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final cur = state.baseCurrency;

    return Scaffold(
      appBar: AppBar(title: Text(tr('money_title'))),
      floatingActionButton: ScrollAwareFab(
        visible: _moneyFab,
        child: FloatingActionButton.extended(
          heroTag: 'money_add_goal',
          icon: const Icon(Icons.flag_outlined),
          label: Text(tr('add_goal')),
          onPressed: () => editGoal(context),
        ),
      ),
      body: hideFabOnScroll(_moneyFab, ListView(padding: const EdgeInsets.only(bottom: 96), children: [
        if (state.balances.isNotEmpty)
          Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Ledger.ruleOf(context)))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              LedgerCaption(tr('total_on_accounts')),
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: AnimatedMoney(state.totalBalance, cur, style: mono(size: 36, color: Ledger.accentOf(context))),
              ),
            ]),
          ),
        // Everything one has minus everything one owes.
        LedgerTile(
          tr('nw_title'),
          hint: tr('nw_tile_sub'),
          value: formatMoney(state.netWorth.total, cur),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const NetWorthScreen())),
        ),
        _Section(
          title: tr('accounts'),
          action: IconButton(
            icon: const Icon(Icons.add),
            tooltip: tr('new_account'),
            onPressed: () async {
              final r = await accountDialog(context, title: tr('new_account'), currency: cur);
              if (r != null) await state.addAccount(r.$1, r.$2);
            },
          ),
        ),
        for (final a in state.accounts) _AccountTile(account: a),
        _Section(title: tr('goals')),
        if (state.goals.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(tr('goals_hint'), style: theme.textTheme.bodySmall),
          ),
        for (final g in state.goals) _GoalCard(goal: g),
        _Section(title: tr('owed_title')),
        if (state.openDebts.isEmpty)
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(tr('nobody_owes')))
        else
          ListTile(
            leading: const Icon(Icons.call_split),
            title: Text(tr('owed_to_you', [formatMoney(state.owedToMeMinor, cur)])),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DebtsScreen())),
          ),
      ])),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget? action;
  const _Section({required this.title, this.action});

  @override
  Widget build(BuildContext context) =>
      LedgerSection(title, action: action, padding: const EdgeInsets.fromLTRB(16, 22, 16, 4));
}

class _AccountTile extends StatelessWidget {
  final Account account;
  const _AccountTile({required this.account});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final balance = state.balances[account.id];
    final name = state.accountName(account);

    Future<void> reconcile() async {
      final v = await _askBalance(context, tr('balance_dialog', [name]), account.currency,
          hint: balance == null ? null : formatAmount(balance));
      if (v != null) await state.setAccountBalance(account, v);
    }

    return ListTile(
      leading: Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(border: Border.all(color: Ledger.inkOf(context)), borderRadius: BorderRadius.circular(3)),
        child: Text(currencySymbol(account.currency), style: mono(size: 14)),
      ),
      title: Text(name),
      subtitle: Text(
        balance == null
            ? tr('balance_not_set')
            : state.isStale(account)
                ? tr('reconcile_due', [DateTime.now().difference(account.balanceAt!).inDays])
                : tr('reconciled_at', [DateFormat.yMMMd(intlLocale).format(account.balanceAt!)]),
        style: state.isStale(account) ? TextStyle(color: Ledger.badOf(context)) : null,
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (balance != null)
          Text(formatMoney(balance, account.currency), style: mono(size: 15, color: balance < 0 ? Ledger.badOf(context) : null)),
        PopupMenuButton<String>(
          onSelected: (v) async {
            if (v == 'edit') {
              final r = await accountDialog(context, title: tr('account'), name: name, currency: account.currency);
              if (r != null) await state.updateAccount(account, name: r.$1, currency: r.$2);
            } else if (v == 'hide') {
              await state.archiveAccount(account);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'edit', child: Text(tr('edit'))),
            PopupMenuItem(value: 'hide', child: Text(tr('hide'))),
          ],
        ),
      ]),
      onTap: reconcile,
    );
  }
}

/// The field starts empty (no "0.00" to erase); the current balance is shown as a hint.
Future<int?> _askBalance(BuildContext context, String title, String currency, {String? hint}) {
  final controller = TextEditingController();
  return showDialog<int>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(tr('balance_dialog_sub'), style: Theme.of(c).textTheme.bodySmall),
        TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          decoration: InputDecoration(hintText: hint, suffixText: currencySymbol(currency)),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('cancel'))),
        FilledButton(
          onPressed: () {
            final t = controller.text.trim();
            final neg = t.startsWith('-') || t.startsWith('−');
            final body = t.replaceFirst(RegExp(r'^[-−]'), '');
            // Nothing typed: nothing to save (an empty field must not become a zero balance).
            if (body.isEmpty) return;
            final v = body == '0' ? 0 : parseAmountToMinor(body);
            if (v != null) Navigator.pop(c, neg ? -v : v);
          },
          child: Text(tr('save')),
        ),
      ],
    ),
  );
}

class _GoalCard extends StatelessWidget {
  final Goal goal;
  const _GoalCard({required this.goal});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final theme = Theme.of(context);
    final now = DateTime.now();
    final monthly = goal.monthlyNeed(now);
    final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
    final cur = goal.currency;

    Future<void> move(bool add) async {
      final r = await _askGoalMove(context, state,
          title: tr(add ? 'put_aside_q' : 'take_out_q', [goal.name]), currency: cur, add: add, accountId: goal.accountId);
      if (r != null) await state.addToGoal(goal, add ? r.$1 : -r.$1, accountId: r.$2);
    }

    /// "Close a goal": what was bought with the savings, fully reaching the goal or not.
    Future<void> close() async {
      final r = await _askGoalPurchase(context, goal);
      if (r != null) await state.buyFromGoal(goal, r.$1, merchant: r.$2, close: r.$3);
    }

    Future<void> delete() async {
      final messenger = ScaffoldMessenger.of(context);
      await state.deleteGoal(goal);
      messenger.showSnackBar(SnackBar(
        content: Text(tr('goal_deleted', [goal.name])),
        action: SnackBarAction(label: tr('undo'), onPressed: () => state.restoreGoal(goal)),
      ));
    }

    return Dismissible(
      key: ValueKey('goal-${goal.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        decoration: BoxDecoration(color: theme.colorScheme.errorContainer, borderRadius: BorderRadius.circular(3)),
        child: Icon(Icons.delete_outline, color: theme.colorScheme.onErrorContainer),
      ),
      onDismissed: (_) => delete(),
      child: Card(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(3),
        onTap: () => editGoal(context, goal: goal),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(goal.name, style: theme.textTheme.titleMedium)),
              if (goal.deadline != null)
                Text(tr('goal_until', [DateFormat.yMMMd(intlLocale).format(goal.deadline!)]), style: theme.textTheme.bodySmall),
              PopupMenuButton<String>(
                tooltip: '',
                onSelected: (v) => switch (v) {
                  'edit' => editGoal(context, goal: goal),
                  'add' => move(true),
                  'take' => move(false),
                  'close' => close(),
                  _ => delete(),
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'edit', child: ListTile(leading: const Icon(Icons.edit_outlined), title: Text(tr('edit')))),
                  PopupMenuItem(value: 'add', child: ListTile(leading: const Icon(Icons.add), title: Text(tr('put_aside')))),
                  PopupMenuItem(value: 'take', child: ListTile(leading: const Icon(Icons.remove), title: Text(tr('take_out')))),
                  PopupMenuItem(value: 'close', child: ListTile(leading: const Icon(Icons.flag_outlined), title: Text(tr('goal_close')))),
                  PopupMenuItem(value: 'delete', child: ListTile(leading: const Icon(Icons.delete_outline), title: Text(tr('delete')))),
                ],
              ),
            ]),
            const SizedBox(height: 8),
            LedgerBar(value: goal.progress, height: 10),
            const SizedBox(height: 4),
            Text.rich(TextSpan(children: [
              TextSpan(text: formatMoney(goal.savedMinor, cur), style: mono(size: 14)),
              TextSpan(text: ' / ${formatMoney(goal.targetMinor, cur)}', style: mono(size: 14, color: Ledger.mutedOf(context))),
            ])),
            const SizedBox(height: 4),
            if (goal.done)
              Text(tr('goal_done'), style: theme.textTheme.bodyMedium?.copyWith(color: Ledger.goodOf(context)))
            else if (monthly > 0)
              Text(tr('goal_need', [formatMoney(monthly, cur), formatMoney((monthly / daysInMonth).ceil(), cur)]),
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            if (goal.reserve && monthly > 0 && state.budgetEnabled)
              Text(tr('goal_reserve_sub'), style: theme.textTheme.bodySmall),
            // Stacks the buttons when long labels don't fit side by side.
            OverflowBar(alignment: MainAxisAlignment.end, overflowAlignment: OverflowBarAlignment.end, children: [
              TextButton(onPressed: close, child: Text(tr('goal_close'))),
              TextButton(onPressed: () => move(false), child: Text(tr('take_out'))),
              FilledButton.tonal(onPressed: () => move(true), child: Text(tr('put_aside'))),
            ]),
          ]),
        ),
      ),
      ),
    );
  }
}

/// What the savings bought: amount (the savings by default), what it was, and whether the goal is
/// reached (closed) or only this amount is taken from it.
Future<(int, String, bool)?> _askGoalPurchase(BuildContext context, Goal goal) {
  final amount = TextEditingController(text: goal.savedMinor > 0 ? (goal.savedMinor / 100).toStringAsFixed(goal.savedMinor % 100 == 0 ? 0 : 2) : '');
  final what = TextEditingController(text: goal.name);
  var full = true;
  return showDialog<(int, String, bool)>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => AlertDialog(
        title: Text(tr('goal_close')),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
              controller: amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: tr('goal_spent'), suffixText: currencySymbol(goal.currency)),
            ),
            TextField(controller: what, decoration: InputDecoration(labelText: tr('goal_bought'))),
            const SizedBox(height: 8),
            RadioGroup<bool>(
              groupValue: full,
              onChanged: (v) => setState(() => full = v ?? true),
              child: Column(children: [
                RadioListTile<bool>(value: true, contentPadding: EdgeInsets.zero, title: Text(tr('goal_close_full')), subtitle: Text(tr('goal_close_full_sub'))),
                RadioListTile<bool>(value: false, contentPadding: EdgeInsets.zero, title: Text(tr('goal_close_part')), subtitle: Text(tr('goal_close_part_sub'))),
              ]),
            ),
            Text(tr('goal_no_account_hint'), style: Theme.of(c).textTheme.bodySmall),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('cancel'))),
          FilledButton(
            onPressed: () {
              final v = parseAmountToMinor(amount.text);
              if (v != null) Navigator.pop(c, (v, what.text, full));
            },
            child: Text(tr('ok')),
          ),
        ],
      ),
    ),
  );
}

/// Amount + optional account ("from" when putting aside, "to" when taking out).
Future<(int, int?)?> _askGoalMove(
  BuildContext context,
  AppState state, {
  required String title,
  required String currency,
  required bool add,
  int? accountId,
}) {
  final controller = TextEditingController();
  int? account = state.accountById.containsKey(accountId) ? accountId : null;
  return showDialog<(int, int?)>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(suffixText: currencySymbol(currency)),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int?>(
            initialValue: account,
            isExpanded: true,
            decoration: InputDecoration(labelText: add ? tr('from_account') : tr('to_account')),
            items: [
              DropdownMenuItem(value: null, child: Text(tr('no_account'))),
              for (final a in state.accounts) DropdownMenuItem(value: a.id, child: Text('${state.accountName(a)} (${a.currency})')),
            ],
            onChanged: (v) => setState(() => account = v),
          ),
          const SizedBox(height: 6),
          Text(tr('goal_move_hint'), style: Theme.of(c).textTheme.bodySmall),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('cancel'))),
          FilledButton(
            onPressed: () {
              final v = parseAmountToMinor(controller.text);
              if (v != null) Navigator.pop(c, (v, account));
            },
            child: Text(tr('ok')),
          ),
        ],
      ),
    ),
  );
}

/// Create or edit a goal.
Future<void> editGoal(BuildContext context, {Goal? goal}) => Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => _GoalEditor(goal: goal), fullscreenDialog: true),
    );

class _GoalEditor extends StatefulWidget {
  final Goal? goal;
  const _GoalEditor({this.goal});

  @override
  State<_GoalEditor> createState() => _GoalEditorState();
}

class _GoalEditorState extends State<_GoalEditor> {
  late final _name = TextEditingController(text: widget.goal?.name ?? '');
  late final _target = TextEditingController(text: _plain(widget.goal?.targetMinor));
  late final _saved = TextEditingController(text: _plain(widget.goal?.savedMinor));
  late DateTime? _deadline = widget.goal?.deadline;
  late bool _reserve = widget.goal?.reserve ?? true;
  late int? _accountId = widget.goal?.accountId;

  static String _plain(int? minor) => minor == null || minor == 0 ? '' : (minor / 100).toString().replaceAll(RegExp(r'\.0$'), '');

  @override
  void dispose() {
    _name.dispose();
    _target.dispose();
    _saved.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    final target = parseAmountToMinor(_target.text);
    final name = _name.text.trim();
    if (target == null || name.isEmpty) return;
    final saved = parseAmountToMinor(_saved.text) ?? 0;
    if (widget.goal == null) {
      await state.addGoal(
          name: name, targetMinor: target, savedMinor: saved, deadline: _deadline, reserve: _reserve, accountId: _accountId);
    } else {
      await state.updateGoal(widget.goal!,
          name: name, targetMinor: target, savedMinor: saved, deadline: _deadline, reserve: _reserve, accountId: _accountId);
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('delete_goal_q')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('delete'))),
        ],
      ),
    );
    if (ok == true && mounted) {
      await context.read<AppState>().deleteGoal(widget.goal!);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cur = widget.goal?.currency ?? state.baseCurrency;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.goal == null ? tr('add_goal') : tr('goal')),
        actions: [
          if (widget.goal != null) IconButton(icon: const Icon(Icons.delete_outline), onPressed: _delete),
          TextButton(onPressed: _save, child: Text(tr('save'))),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
          controller: _name,
          autofocus: widget.goal == null,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: tr('name'), border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _target,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: tr('goal_target'), suffixText: currencySymbol(cur), border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _saved,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: tr('goal_saved'), suffixText: currencySymbol(cur), border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.event),
          title: Text(tr('goal_deadline')),
          subtitle: Text(_deadline == null ? tr('goal_no_deadline') : DateFormat.yMMMMd(intlLocale).format(_deadline!)),
          trailing: _deadline == null
              ? null
              : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(() => _deadline = null)),
          onTap: () async {
            final now = DateTime.now();
            final d = await showDatePicker(
              context: context,
              initialDate: _deadline ?? DateTime(now.year, now.month + 3, now.day),
              firstDate: now,
              lastDate: DateTime(now.year + 30),
            );
            if (d != null) setState(() => _deadline = d);
          },
        ),
        const SizedBox(height: 4),
        DropdownButtonFormField<int?>(
          initialValue: state.accountById.containsKey(_accountId) ? _accountId : null,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: tr('goal_account'),
            helperText: tr('goal_account_sub'),
            border: const OutlineInputBorder(),
          ),
          items: [
            DropdownMenuItem(value: null, child: Text(tr('no_account'))),
            for (final a in state.accounts) DropdownMenuItem(value: a.id, child: Text('${state.accountName(a)} (${a.currency})')),
          ],
          onChanged: (v) => setState(() => _accountId = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _reserve,
          onChanged: (v) => setState(() => _reserve = v),
          title: Text(tr('goal_reserve')),
          subtitle: Text(tr('goal_reserve_sub')),
        ),
      ]),
    );
  }
}

/// What friends owe for split bills.
class DebtsScreen extends StatelessWidget {
  const DebtsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('owed_title'))),
      body: ListView(children: [
        Padding(padding: const EdgeInsets.all(16), child: Text(tr('debts_hint'), style: theme.textTheme.bodySmall)),
        if (state.openDebts.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(tr('nobody_owes'))),
        for (final d in state.openDebts)
          ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person_outline)),
            title: Text(d.person ?? tr('unnamed_friend')),
            subtitle: Text(DateFormat.yMMMd(intlLocale).format(d.createdAt)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(formatMoney(d.openMinor, d.currency), style: theme.textTheme.titleMedium),
              const SizedBox(width: 8),
              FilledButton.tonal(onPressed: () => state.markDebtReturned(d), child: Text(tr('mark_returned'))),
            ]),
          ),
      ]),
    );
  }
}
