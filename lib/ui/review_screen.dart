import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../domain/money.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'txn_editor.dart';
import 'widgets.dart';

/// Auto-captured payments without a category: one tap assigns a category and teaches the merchant rule.
class ReviewScreen extends StatelessWidget {
  const ReviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final queue = state.reviewQueue;
    return Scaffold(
      appBar: AppBar(title: Text(tr('review_title'))),
      body: queue.isEmpty
          ? Center(child: Text(tr('all_done')))
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: queue.length,
              separatorBuilder: (_, _) => const Divider(height: 24),
              itemBuilder: (context, i) => _ReviewItem(queue[i]),
            ),
    );
  }
}

class _ReviewItem extends StatelessWidget {
  final Txn txn;
  const _ReviewItem(this.txn);

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final theme = Theme.of(context);
    final categories = state.categoriesOf(txn.kind);
    final sign = txn.kind == TxnKind.income ? txn.amountMinor : -txn.amountMinor;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(txn.merchant ?? tr('unknown_payee'), style: theme.textTheme.titleMedium),
              Text(
                '${DateFormat.MMMd(intlLocale).format(txn.time)}, ${DateFormat.Hm(intlLocale).format(txn.time)} · ${txn.source.split(':').first}',
                style: theme.textTheme.bodySmall,
              ),
            ]),
          ),
          if (txn.amountMinor != 0)
            Text(formatMoney(sign, txn.currency, signed: true), style: theme.textTheme.titleLarge),
          IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => openTxnEditor(context, txn: txn)),
        ]),
        if (txn.amountMinor == 0) _AmountField(txn),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final c in categories)
            ChoiceChip(
              avatar: Icon(categoryIcons[c.icon] ?? Icons.label, size: 18, color: Color(c.color)),
              label: Text(state.categoryName(c)),
              selected: txn.categoryId == c.id,
              onSelected: (_) => state.categorize(txn, c),
            ),
        ]),
        if (txn.amountMinor == 0 && txn.categoryId != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(tr('cat_chosen_enter_amount'),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
          ),
      ]),
    );
  }
}

/// WeChat transfers come without an amount: type it here.
class _AmountField extends StatefulWidget {
  final Txn txn;
  const _AmountField(this.txn);

  @override
  State<_AmountField> createState() => _AmountFieldState();
}

class _AmountFieldState extends State<_AmountField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final v = parseAmountToMinor(_controller.text);
    if (v == null) return;
    await context.read<AppState>().setAmount(widget.txn, v);
  }

  @override
  Widget build(BuildContext context) {
    final income = widget.txn.kind == TxnKind.income;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: _controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              labelText: income ? tr('how_much_in') : tr('how_much_out'),
              suffixText: '¥',
            ),
            onSubmitted: (_) => _save(),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(onPressed: _save, child: Text(tr('ok'))),
        IconButton(
          tooltip: tr('dont_record'),
          icon: const Icon(Icons.delete_outline),
          onPressed: () => context.read<AppState>().deleteTxn(widget.txn),
        ),
      ]),
    );
  }
}
