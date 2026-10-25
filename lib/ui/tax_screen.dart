import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../domain/money.dart';
import '../domain/tax_tags.dart';
import '../io/export.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'ledger.dart';
import 'receipt_view.dart';
import 'txn_editor.dart';

/// Settings → Tax marks: the year's spending that may lower the tax, by mark, with the receipts;
/// the categories' marks; a spreadsheet for the tax return or an adviser.
class TaxScreen extends StatefulWidget {
  const TaxScreen({super.key});
  @override
  State<TaxScreen> createState() => _TaxScreenState();
}

class _TaxScreenState extends State<TaxScreen> {
  int _year = DateTime.now().year;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final muted = Ledger.mutedOf(context);
    final cur = state.baseCurrency;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('tax_title')),
        actions: [IconButton(tooltip: tr('tax_export'), icon: const Icon(Icons.ios_share), onPressed: () => _export(state))],
      ),
      body: FutureBuilder<Map<String, List<Txn>>>(
        future: state.taxReport(_year),
        builder: (context, snap) {
          final report = snap.data;
          if (report == null) return const Center(child: CircularProgressIndicator());
          int sum(List<Txn> l) => l.fold(0, (a, t) => a + (state.toBase(t) ?? 0));
          return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
            Row(children: [
              IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => setState(() => _year--)),
              Expanded(child: Text('$_year', textAlign: TextAlign.center, style: theme.textTheme.titleMedium)),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: _year < DateTime.now().year ? () => setState(() => _year++) : null,
              ),
            ]),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(tr('tax_intro'), style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            ),
            if (report.isEmpty)
              Padding(padding: const EdgeInsets.all(16), child: Text(tr('tax_empty'))),
            for (final tag in taxTagKeys)
              if (report[tag] case final list?) ...[
                LedgerSection('${tr('tax_$tag')} · ${formatMoney(sum(list), cur)}'),
                for (final t in list)
                  LedgerTile(
                    t.merchant ?? (t.categoryId == null ? '—' : state.categoryName(state.categoryById[t.categoryId]!)),
                    hint: DateFormat.yMMMd(intlLocale).format(t.time),
                    value: formatMoney(t.amountMinor, t.currency),
                    trailing: t.receipt == null
                        ? null
                        : IconButton(icon: const Icon(Icons.receipt_long, size: 18), onPressed: () => showReceipt(context, t.receipt!)),
                    onTap: () => openTxnEditor(context, txn: t),
                  ),
              ],
            LedgerSection(tr('tax_categories')),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text(tr('tax_categories_sub'), style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            ),
            for (final c in state.categoriesOf(TxnKind.expense))
              LedgerTile(
                state.categoryName(c),
                value: switch (state.categoryTaxTag(c.id)) { null => '—', final t => tr('tax_$t') },
                onTap: () => _chooseForCategory(state, c),
              ),
          ]);
        },
      ),
    );
  }

  Future<void> _chooseForCategory(AppState state, Category c) async {
    const none = '';
    final v = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (s) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(state.categoryName(c), style: Theme.of(s).textTheme.titleMedium),
          ),
          for (final t in taxTagKeys)
            ListTile(
              title: Text(tr('tax_$t')),
              trailing: state.categoryTaxTag(c.id) == t ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(s, t),
            ),
          ListTile(title: Text(tr('tax_mark_none')), onTap: () => Navigator.pop(s, none)),
        ]),
      ),
    );
    if (v == null) return;
    await state.setCategoryTaxTag(c, v == none ? null : v);
  }

  Future<void> _export(AppState state) async {
    final report = await state.taxReport(_year);
    final date = DateFormat('yyyy-MM-dd');
    final rows = <List<Object?>>[
      [tr('col_date'), tr('tax_mark'), tr('category'), tr('payee'), tr('col_amount'), tr('currency'),
        tr('col_amount_in', [state.baseCurrency]), tr('rc_title')],
      for (final tag in taxTagKeys)
        for (final t in report[tag] ?? const <Txn>[])
          [
            date.format(t.time),
            tr('tax_$tag'),
            t.categoryId == null ? '' : state.categoryName(state.categoryById[t.categoryId]!),
            t.merchant ?? '',
            t.amountMinor / 100,
            t.currency,
            switch (state.toBase(t)) { null => null, final v => v / 100 },
            t.receipt == null ? '' : tr('rc_yes'),
          ],
    ];
    await shareExport(rows: rows, format: ExportFormat.xlsx, fileBaseName: 'tax_$_year');
  }
}
