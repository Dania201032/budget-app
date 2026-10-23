import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../domain/money.dart';
import '../domain/search.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'ledger.dart';
import 'txn_editor.dart';
import 'widgets.dart';

Future<void> openSearch(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SearchScreen()));

/// All operations, searchable by payee, comment, category or amount, filtered by direction,
/// period, categories and account, with the total of what was found.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

enum _Range { all, month, days30, year, custom }

class _SearchScreenState extends State<SearchScreen> {
  final _query = TextEditingController();
  TxnFilter _filter = const TxnFilter();
  _Range _range = _Range.all;
  List<Txn>? _all;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final txns = await context.read<AppState>().repo.txnsBetween(DateTime(2000), DateTime.now().add(const Duration(days: 3650)));
    if (mounted) setState(() => _all = txns);
  }

  Future<void> _edit(Txn t) async {
    await openTxnEditor(context, txn: t);
    await _load();
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showModalBottomSheet<_Range>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          for (final r in _Range.values)
            ListTile(
              title: Text(tr('search_range_${r.name}')),
              trailing: r == _range ? Icon(Icons.check, color: Ledger.accentOf(c)) : null,
              onTap: () => Navigator.pop(c, r),
            ),
        ]),
      ),
    );
    if (picked == null) return;
    DateTime? from, to;
    switch (picked) {
      case _Range.all:
        break;
      case _Range.month:
        from = DateTime(now.year, now.month);
        to = DateTime(now.year, now.month + 1);
      case _Range.days30:
        from = DateTime(now.year, now.month, now.day - 29);
        to = DateTime(now.year, now.month, now.day + 1);
      case _Range.year:
        from = DateTime(now.year);
        to = DateTime(now.year + 1);
      case _Range.custom:
        if (!mounted) return;
        final r = await showDateRangePicker(
          context: context,
          firstDate: DateTime(2000),
          lastDate: DateTime(now.year + 1),
          initialDateRange: _filter.from == null ? null : DateTimeRange(start: _filter.from!, end: _filter.to!.subtract(const Duration(days: 1))),
        );
        if (r == null) return;
        from = r.start;
        to = DateTime(r.end.year, r.end.month, r.end.day + 1);
    }
    setState(() {
      _range = picked;
      _filter = _filter.copyWith(from: () => from, to: () => to);
    });
  }

  Future<void> _pickCategories(AppState state) async {
    final chosen = {..._filter.categories};
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(c).size.height * 0.7),
            child: ListView(shrinkWrap: true, children: [
              for (final kind in [TxnKind.expense, TxnKind.income]) ...[
                LedgerSection(tr(kind == TxnKind.expense ? 'expenses' : 'income')),
                for (final cat in state.categoriesOf(kind))
                  CheckboxListTile(
                    value: chosen.contains(cat.id),
                    onChanged: (v) => set(() => v == true ? chosen.add(cat.id) : chosen.remove(cat.id)),
                    title: Text(state.categoryName(cat)),
                    secondary: CategoryAvatar(cat, size: 28),
                  ),
              ],
            ]),
          ),
        ),
      ),
    );
    setState(() => _filter = _filter.copyWith(categories: chosen));
  }

  Future<void> _pickAccount(AppState state) async {
    const any = -1;
    final id = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(title: Text(tr('search_any_account')), onTap: () => Navigator.pop(c, any)),
          for (final a in state.accounts)
            ListTile(
              title: Text(state.accountName(a)),
              trailing: a.id == _filter.accountId ? Icon(Icons.check, color: Ledger.accentOf(c)) : null,
              onTap: () => Navigator.pop(c, a.id),
            ),
        ]),
      ),
    );
    if (id == null) return;
    setState(() => _filter = _filter.copyWith(accountId: () => id == any ? null : id));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final all = _all;
    String categoryName(int? id) => id == null || state.categoryById[id] == null ? '' : state.categoryName(state.categoryById[id]!);
    final found = all == null ? const <Txn>[] : all.where((t) => matchesFilter(t, _filter, categoryName)).toList();

    // Totals in the base currency; transfers to myself and other excluded ones don't count.
    var spent = 0, income = 0;
    for (final t in found.where((t) => !t.excluded)) {
      final v = state.toBase(t) ?? 0;
      if (t.kind == TxnKind.expense) {
        spent += v;
      } else {
        income += v;
      }
    }

    final byDay = <DateTime, List<Txn>>{};
    for (final t in found.take(400)) {
      byDay.putIfAbsent(DateTime(t.time.year, t.time.month, t.time.day), () => []).add(t);
    }

    Widget chip(String label, bool active, VoidCallback onTap, {VoidCallback? onClear}) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: active && onClear != null
              ? InputChip(label: Text(label), selected: true, onPressed: onTap, onDeleted: onClear)
              : FilterChip(label: Text(label), selected: active, onSelected: (_) => onTap()),
        );

    final account = _filter.accountId == null ? null : state.accountById[_filter.accountId];
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _query,
          autofocus: true,
          decoration: InputDecoration(hintText: tr('search_hint'), border: InputBorder.none),
          onChanged: (v) => setState(() => _filter = _filter.copyWith(query: v)),
        ),
        actions: [
          if (_query.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () => setState(() {
                _query.clear();
                _filter = _filter.copyWith(query: '');
              }),
            ),
        ],
      ),
      body: Column(children: [
        // Wraps onto a second line rather than hiding filters off-screen (long German/Dutch labels).
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Wrap(runSpacing: 4, children: [
            chip(tr('expenses'), _filter.kind == TxnKind.expense,
                () => setState(() => _filter = _filter.copyWith(kind: () => _filter.kind == TxnKind.expense ? null : TxnKind.expense))),
            chip(tr('income'), _filter.kind == TxnKind.income,
                () => setState(() => _filter = _filter.copyWith(kind: () => _filter.kind == TxnKind.income ? null : TxnKind.income))),
            chip(
              _range == _Range.custom && _filter.from != null
                  ? '${DateFormat.yMMMd(intlLocale).format(_filter.from!)} – ${DateFormat.yMMMd(intlLocale).format(_filter.to!.subtract(const Duration(days: 1)))}'
                  : tr('search_range_${_range.name}'),
              _range != _Range.all,
              _pickRange,
              onClear: () => setState(() {
                _range = _Range.all;
                _filter = _filter.copyWith(from: () => null, to: () => null);
              }),
            ),
            chip(
              _filter.categories.isEmpty ? tr('search_categories') : tr('search_categories_n', [_filter.categories.length]),
              _filter.categories.isNotEmpty,
              () => _pickCategories(state),
              onClear: () => setState(() => _filter = _filter.copyWith(categories: const {})),
            ),
            chip(
              account == null ? tr('account') : state.accountName(account),
              account != null,
              () => _pickAccount(state),
              onClear: () => setState(() => _filter = _filter.copyWith(accountId: () => null)),
            ),
          ]),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Ledger.ruleOf(context)))),
          child: Text(
            all == null
                ? ''
                : tr('search_found', [found.length, formatMoney(spent, state.baseCurrency), formatMoney(income, state.baseCurrency)]),
            style: theme.textTheme.bodySmall?.copyWith(color: Ledger.mutedOf(context)),
          ),
        ),
        Expanded(
          child: all == null
              ? const Center(child: CircularProgressIndicator())
              : found.isEmpty
                  ? Center(child: Text(tr('search_nothing')))
                  : ListView(padding: const EdgeInsets.only(bottom: 24), children: [
                      for (final e in byDay.entries) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                          child: Text(dayHeader(e.key), style: theme.textTheme.titleSmall),
                        ),
                        for (final t in e.value) TxnTile(t, onTap: () => _edit(t)),
                      ],
                      if (found.length > 400)
                        Padding(padding: const EdgeInsets.all(16), child: Text(tr('search_more', [found.length - 400]))),
                    ]),
        ),
      ]),
    );
  }
}
