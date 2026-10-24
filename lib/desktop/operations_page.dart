import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../domain/money.dart';
import '../domain/periods.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../ui/data_screens.dart' show SheetImportScreen;
import '../ui/ledger.dart';
import '../ui/goal_spend.dart';
import '../ui/split_sheet.dart';
import '../ui/statement_import_screen.dart';
import '../ui/txn_editor.dart';
import '../ui/widgets.dart' show PersonBadge;
import 'kit.dart';
import 'shell.dart';

class OperationsPage extends StatefulWidget {
  const OperationsPage({super.key});
  @override
  State<OperationsPage> createState() => _OperationsPageState();
}

class _OperationsPageState extends State<OperationsPage> {
  Period period = Period.containing(PeriodType.month, DateTime.now());
  String view = 'all';
  int? categoryFilter;
  int? accountFilter;
  String? currencyFilter;

  /// One day (opened from the calendar or a chart on the Summary).
  DateTime? dayFilter;
  String query = '';
  int? selected;
  final checked = <int>{};
  List<Txn> txns = [];
  Object? _loadedFor;
  final _focus = FocusNode();
  final _note = TextEditingController();
  int? _noteFor;

  @override
  void initState() {
    super.initState();
    final f = context.read<DeskController>().takeOpsFilter();
    if (f == 'review' || f == 'income' || f == 'expense') view = f!;
    if (f != null && f.startsWith('cat:')) categoryFilter = int.tryParse(f.substring(4));
    if (f != null && f.startsWith('day:')) {
      dayFilter = DateTime.tryParse(f.substring(4));
      if (dayFilter != null) period = Period.containing(PeriodType.month, dayFilter!);
    }
    if (f != null && f.startsWith('month:')) {
      final parts = f.substring(6).split(':');
      final m = DateTime.tryParse('${parts.first}-01');
      if (m != null) period = Period.containing(PeriodType.month, m);
      if (parts.length > 1) view = parts[1];
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load(AppState s, Object key) async {
    _loadedFor = key;
    final list = view == 'review' ? s.reviewQueue : (await s.repo.txnsBetween(period.start, period.end)).where(s.inBudgetScope).toList();
    if (!mounted || _loadedFor != key) return;
    setState(() => txns = list);
  }

  List<Txn> _visible(AppState s) {
    final q = query.trim().toLowerCase();
    final amountQ = RegExp(r'^[<>]?\s*\d').hasMatch(q);
    return txns.where((t) {
      if (categoryFilter != null && t.categoryId != categoryFilter) return false;
      if (accountFilter != null && t.accountId != accountFilter) return false;
      if (currencyFilter != null && t.currency != currencyFilter) return false;
      final day = dayFilter;
      if (day != null && (t.time.year != day.year || t.time.month != day.month || t.time.day != day.day)) return false;
      switch (view) {
        case 'expense':
          if (t.kind != TxnKind.expense) return false;
        case 'large':
          if ((s.toBase(t) ?? 0) < _largeThreshold(s)) return false;
        case 'split':
          if (!t.isSplit) return false;
        case 'own':
          if (!t.ownTransfer) return false;
        case 'income':
          if (t.kind != TxnKind.income) return false;
      }
      if (q.isEmpty) return true;
      if (amountQ) {
        final v = parseNum(q.replaceAll(RegExp(r'[<>]'), '')) ?? 0;
        final a = t.amountMinor / 100;
        return q.startsWith('>') ? a > v : q.startsWith('<') ? a < v : (a - v).abs() < .01;
      }
      final hay = [t.merchant, t.note, if (t.categoryId != null) s.categoryById[t.categoryId]?.name].whereType<String>().join(' ').toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  /// "Large": ten daily limits, or 200 in the base currency without a budget.
  int _largeThreshold(AppState s) {
    final l = s.todayStats?.dailyLimit ?? 0;
    return l > 0 ? (l * 3).round() : 20000;
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final desk = context.watch<DeskController>();
    final key = (period.start, view, desk.data, s.reviewQueue.length);
    if (_loadedFor != key) _load(s, key);
    final visible = _visible(s);
    final sel = visible.where((t) => t.id == selected).firstOrNull ?? (visible.isEmpty ? null : visible.first);
    final spent = visible.where((t) => t.kind == TxnKind.expense && !t.excluded).fold<int>(0, (a, t) => a + (s.toBase(t) ?? 0));
    final income = visible.where((t) => t.kind == TxnKind.income && !t.excluded).fold<int>(0, (a, t) => a + (s.toBase(t) ?? 0));

    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (node, e) => _onKey(e, visible, sel, s),
      child: DeskPage(
        title: tr('d_nav_operations'),
        subtitle: tr('d_ops_sub', [
          view == 'review' ? tr('d_review') : period.label(),
          visible.length,
          formatMoney(-spent, s.baseCurrency),
          formatMoney(income, s.baseCurrency, signed: true),
        ]),
        actions: [
          if (view != 'review')
            Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(tooltip: tr('d_prev'), onPressed: () => setState(() {
                    period = period.shift(-1);
                    dayFilter = null;
                  }), icon: const Icon(Icons.chevron_left)),
              Text(period.label(), style: sans(context, size: 14, weight: FontWeight.w500)),
              IconButton(tooltip: tr('d_next'), onPressed: () => setState(() {
                    period = period.shift(1);
                    dayFilter = null;
                  }), icon: const Icon(Icons.chevron_right)),
            ]),
          DeskButton(tr('stmt_title'), icon: Icons.upload_file_outlined,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const StatementImportScreen()))),
          DeskButton(tr('d_import'), icon: Icons.upload_outlined,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SheetImportScreen()))),
          DeskButton(tr('d_export_excel'), onTap: () => desk.go(DeskPages.excel)),
          DeskButton(tr('d_operation'), primary: true, icon: Icons.add, shortcut: 'N', onTap: () => openTxnEditor(context)),
        ],
        children: [
          _Filters(
            view: view,
            reviewCount: s.reviewQueue.length,
            onView: (v) => setState(() {
              view = v;
              checked.clear();
            }),
            query: query,
            onQuery: (v) => setState(() => query = v),
            category: categoryFilter,
            onCategory: (v) => setState(() => categoryFilter = v),
            account: accountFilter,
            onAccount: (v) => setState(() => accountFilter = v),
            currency: currencyFilter,
            currencies: {for (final t in txns) t.currency, for (final a in s.accounts) a.currency}.toList()..sort(),
            onCurrency: (v) => setState(() => currencyFilter = v),
            day: dayFilter,
            onClearDay: () => setState(() => dayFilter = null),
          ),
          SplitRow([
            (5, 640, _Table(
              txns: visible,
              selected: sel?.id,
              checked: checked,
              compact: desk.profile.compact,
              onSelect: (t) => setState(() => selected = t.id),
              onCheck: (t, v) => setState(() => v ? checked.add(t.id!) : checked.remove(t.id)),
              bulk: checked.isEmpty ? null : _bulkBar(context, s, visible),
            )),
            (2, 320, sel == null ? Panel(child: Text(tr('d_nothing_found'))) : _details(context, s, sel)),
          ]),
          Wrap(spacing: 18, runSpacing: 6, children: [
            for (final (k, label) in [('J K', tr('d_k_move')), ('X', tr('d_k_check')), ('Enter', tr('d_k_confirm')), ('E', tr('d_k_edit')), ('Del', tr('delete'))])
              Row(mainAxisSize: MainAxisSize.min, children: [KeyCap(k), const SizedBox(width: 6), Text(label, style: sans(context, size: 12.5, color: Ledger.mutedOf(context)))]),
          ]),
        ],
      ),
    );
  }

  KeyEventResult _onKey(KeyEvent e, List<Txn> visible, Txn? sel, AppState s) {
    if (e is! KeyDownEvent || visible.isEmpty) return KeyEventResult.ignored;
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx != null && ctx.findAncestorWidgetOfExactType<EditableText>() != null) return KeyEventResult.ignored;
    final i = sel == null ? 0 : visible.indexOf(sel);
    switch (e.logicalKey) {
      case LogicalKeyboardKey.keyJ || LogicalKeyboardKey.arrowDown:
        setState(() => selected = visible[(i + 1).clamp(0, visible.length - 1)].id);
      case LogicalKeyboardKey.keyK || LogicalKeyboardKey.arrowUp:
        setState(() => selected = visible[(i - 1).clamp(0, visible.length - 1)].id);
      case LogicalKeyboardKey.keyX:
        if (sel?.id != null) setState(() => checked.contains(sel!.id) ? checked.remove(sel.id) : checked.add(sel.id!));
      case LogicalKeyboardKey.enter:
        if (sel != null && sel.needsReview && sel.categoryId != null) s.saveTxn(sel.copyWith(needsReview: false));
      case LogicalKeyboardKey.keyE:
        if (sel != null) openTxnEditor(context, txn: sel);
      case LogicalKeyboardKey.delete:
        if (sel != null) _delete(context, s, [sel]);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Future<void> _delete(BuildContext context, AppState s, List<Txn> list) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        content: Text(tr('d_delete_n', [list.length])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('cancel'))),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('delete'))),
        ],
      ),
    );
    if (ok != true) return;
    for (final t in list) {
      await s.deleteTxn(t);
    }
    setState(checked.clear);
  }

  Widget _bulkBar(BuildContext context, AppState s, List<Txn> visible) {
    final list = visible.where((t) => checked.contains(t.id)).toList();
    final sum = list.fold<int>(0, (a, t) => a + (s.toBase(t) ?? 0));
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: Ledger.ink, borderRadius: BorderRadius.circular(8)),
      child: Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(tr('d_checked_n', [list.length, formatMoney(sum, s.baseCurrency)]), style: mono(size: 13, color: Ledger.paper)),
        DeskButton(tr('category'), small: true, color: Ledger.paper, onTap: () async {
          final c = await _pickCategory(context, s, list.first.kind);
          if (c == null) return;
          for (final t in list) {
            await s.saveTxn(t.copyWith(categoryId: () => c.id, kind: c.kind, needsReview: false));
          }
          setState(checked.clear);
        }),
        DeskButton(tr('d_confirm_all'), small: true, color: Ledger.mint, onTap: () async {
          for (final t in list.where((t) => t.categoryId != null)) {
            await s.saveTxn(t.copyWith(needsReview: false));
          }
          setState(checked.clear);
        }),
        DeskButton(tr('delete'), small: true, color: const Color(0xFFF2A69D), onTap: () => _delete(context, s, list)),
        TextButton(onPressed: () => setState(checked.clear), child: Text(tr('cancel'), style: const TextStyle(color: Ledger.paper))),
      ]),
    );
  }

  Widget _details(BuildContext context, AppState s, Txn t) {
    if (_noteFor != t.id) {
      _noteFor = t.id;
      _note.text = t.note ?? '';
    }
    final desk = context.read<DeskController>();
    final payee = t.merchant == null ? null : desk.data.payees.where((p) => p.name == t.merchant).firstOrNull;
    final cats = t.kind == TxnKind.expense ? s.frequentExpenseCategories(9) : s.categoriesOf(TxnKind.income);
    final acc = t.accountId == null ? null : s.accountById[t.accountId];
    final sign = t.kind == TxnKind.income ? '+' : '−';
    return Panel(
      borderColor: Ledger.inkOf(context),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (t.needsReview) Align(alignment: Alignment.centerLeft, child: tagWarn(context, tr('d_waits_review'))),
        const SizedBox(height: 6),
        Text('$sign${formatMoney(t.amountMinor, t.currency)}', style: mono(size: 30, weight: FontWeight.w600)),
        if (t.isSplit) Text(tr('d_my_share', [formatMoney(t.shareMinor!, t.currency)]), style: sans(context, size: 13, color: Ledger.mutedOf(context))),
        Text(t.merchant ?? '—', style: sans(context, size: 16, weight: FontWeight.w500)),
        Text('${DateFormat.yMMMMd(intlLocale).add_Hm().format(t.time)} · ${acc == null ? '—' : s.accountName(acc)}',
            style: sans(context, size: 13, color: Ledger.mutedOf(context))),
        const SizedBox(height: 14),
        Text(tr('category'), style: sans(context, size: 12.5, color: Ledger.mutedOf(context))),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final c in cats)
            Pill(s.categoryName(c), selected: c.id == t.categoryId, onTap: () => s.categorize(t, c)),
          Pill(tr('d_other_cat'), dashed: true, onTap: () async {
            final c = await _pickCategory(context, s, t.kind);
            if (c != null) await s.categorize(t, c);
          }),
          // A purchase the savings of a goal paid for.
          if (t.kind == TxnKind.expense && !t.ownTransfer && (s.goals.isNotEmpty || t.goalId != null))
            Pill(
              t.goalId == null ? tr('goal_close') : tr('goal_from', [s.goalNames[t.goalId] ?? '']),
              selected: t.goalId != null,
              onTap: () async {
                if (t.goalId != null) return s.returnToGoal(t);
                final r = await chooseGoalSpend(context, s);
                if (r != null) await s.spendFromGoal(t, r.$1, close: r.$2);
              },
            ),
        ]),
        const SizedBox(height: 14),
        ListenableBuilder(
          listenable: _note,
          builder: (context, _) => TextField(
          controller: _note,
          decoration: InputDecoration(
            labelText: tr('comment'),
            isDense: true,
            suffixIcon: clearIcon(_note, () => s.saveTxn(t.copyWith(note: () => null), rememberMerchant: false)),
          ),
          onSubmitted: (v) => s.saveTxn(t.copyWith(note: () => v.trim().isEmpty ? null : v.trim()), rememberMerchant: false),
        )),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (t.kind == TxnKind.expense) DeskButton(tr('d_split'), small: true, onTap: () => showSplitSheet(context, t)),
          DeskButton(t.ownTransfer ? tr('d_not_own_transfer') : tr('d_own_transfer'), small: true,
              onTap: () => s.setOwnTransfer(t, !t.ownTransfer)),
          DeskButton(tr('d_edit_full'), small: true, shortcut: 'E', onTap: () => openTxnEditor(context, txn: t)),
        ]),
        const SizedBox(height: 14),
        Divider(color: Ledger.trackOf(context)),
        Text(tr('d_came_from'), style: sans(context, size: 12.5, color: Ledger.mutedOf(context))),
        Text(_source(t.source), style: sans(context, size: 13)),
        if (t.raw != null && t.raw!.trim().isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Ledger.shadeOf(context), borderRadius: BorderRadius.circular(6)),
            child: SelectableText(t.raw!, style: mono(size: 12, height: 1.5)),
          ),
        ],
        if (payee != null) ...[
          const SizedBox(height: 12),
          Text(tr('d_payee_history'), style: sans(context, size: 12.5, color: Ledger.mutedOf(context))),
          Text(tr('d_payee_stats', [payee.count, formatMoney((payee.sum / payee.count).round(), s.baseCurrency)]),
              style: sans(context, size: 13.5)),
          if (t.isCaptured) Text(tr('d_rule_learned'), style: sans(context, size: 12, color: Ledger.mutedOf(context))),
        ],
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: DeskButton(
              t.needsReview ? tr('d_confirm') : tr('d_saved'),
              primary: t.needsReview,
              shortcut: t.needsReview ? 'Enter' : null,
              onTap: t.needsReview && t.categoryId != null ? () => s.saveTxn(t.copyWith(needsReview: false)) : null,
            ),
          ),
          const SizedBox(width: 8),
          DeskButton(tr('delete'), color: warnOf(context), onTap: () => _delete(context, s, [t])),
        ]),
      ]),
    );
  }

  String _source(String src) => switch (src) {
        'manual' => tr('src_manual'),
        'excel' => tr('src_excel'),
        'recurring' => tr('d_src_recurring'),
        final x => tr('src_auto', [x]),
      };
}

Future<Category?> _pickCategory(BuildContext context, AppState s, TxnKind kind) => showDialog<Category>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text(tr('category')),
        children: [
          for (final cat in s.categoriesOf(kind))
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, cat),
              child: Row(children: [Swatch(Color(cat.color)), const SizedBox(width: 10), Text(s.categoryName(cat))]),
            ),
        ],
      ),
    );

class _Filters extends StatefulWidget {
  final String view;
  final int reviewCount;
  final ValueChanged<String> onView;
  final String query;
  final ValueChanged<String> onQuery;
  final int? category;
  final ValueChanged<int?> onCategory;
  final int? account;
  final ValueChanged<int?> onAccount;
  final String? currency;
  final List<String> currencies;
  final ValueChanged<String?> onCurrency;
  final DateTime? day;
  final VoidCallback onClearDay;
  const _Filters({
    required this.view,
    required this.reviewCount,
    required this.onView,
    required this.query,
    required this.onQuery,
    required this.category,
    required this.onCategory,
    required this.account,
    required this.onAccount,
    required this.currency,
    required this.currencies,
    required this.onCurrency,
    required this.day,
    required this.onClearDay,
  });
  @override
  State<_Filters> createState() => _FiltersState();
}

class _FiltersState extends State<_Filters> {
  late final _q = TextEditingController(text: widget.query);
  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final tabs = [
      ('all', tr('d_all')),
      ('review', '${tr('d_review')}${widget.reviewCount > 0 ? ' · ${widget.reviewCount}' : ''}'),
      ('expense', tr('d_expenses_tab')),
      ('income', tr('d_incomes')),
      ('large', tr('d_large')),
      ('split', tr('d_for_friends')),
      ('own', tr('d_own_transfers')),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Choice(options: tabs, value: widget.view, onChanged: widget.onView),
      const SizedBox(height: 12),
      Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(
          width: 340,
          child: ListenableBuilder(
            listenable: _q,
            builder: (context, _) => TextField(
              controller: _q,
              onChanged: widget.onQuery,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: clearIcon(_q, () => widget.onQuery('')),
                hintText: tr('d_search_hint'),
              ),
            ),
          ),
        ),
        _Drop<int?>(
          label: tr('category'),
          value: widget.category,
          items: [(null, tr('d_all')), for (final c in s.categories) (c.id, s.categoryName(c))],
          onChanged: widget.onCategory,
        ),
        _Drop<int?>(
          label: tr('account'),
          value: widget.account,
          items: [(null, tr('d_all')), for (final a in s.accounts) (a.id, s.accountName(a))],
          onChanged: widget.onAccount,
        ),
        _Drop<String?>(
          label: tr('currency'),
          value: widget.currency,
          items: [(null, tr('d_all')), for (final c in widget.currencies) (c, c)],
          onChanged: widget.onCurrency,
        ),
        if (widget.day != null)
          Pill(DateFormat.yMMMMd(intlLocale).format(widget.day!), selected: true, onTap: widget.onClearDay,
              trailing: const Icon(Icons.close, size: 14, color: Ledger.paper)),
        if (widget.category != null || widget.account != null || widget.currency != null || widget.query.isNotEmpty)
          TextButton(
            onPressed: () {
              _q.clear();
              widget.onQuery('');
              widget.onCategory(null);
              widget.onAccount(null);
              widget.onCurrency(null);
            },
            child: Text(tr('d_reset')),
          ),
      ]),
    ]);
  }
}

class _Drop<T> extends StatelessWidget {
  final String label;
  final T value;
  final List<(T, String)> items;
  final ValueChanged<T> onChanged;
  const _Drop({required this.label, required this.value, required this.items, required this.onChanged});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(border: Border.all(color: Ledger.ruleOf(context)), borderRadius: BorderRadius.circular(18)),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
            isDense: true,
            hint: Text(label),
            style: sans(context, size: 13),
            items: [
              for (final (v, l) in items)
                DropdownMenuItem(value: v, child: Text(v == null ? '$label: $l' : l, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => onChanged(v as T),
          ),
        ),
      );
}

class _Table extends StatelessWidget {
  final List<Txn> txns;
  final int? selected;
  final Set<int> checked;
  final bool compact;
  final ValueChanged<Txn> onSelect;
  final void Function(Txn, bool) onCheck;
  final Widget? bulk;
  const _Table({
    required this.txns,
    required this.selected,
    required this.checked,
    required this.compact,
    required this.onSelect,
    required this.onCheck,
    this.bulk,
  });

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final byDay = <DateTime, List<Txn>>{};
    for (final t in txns) {
      byDay.putIfAbsent(DateTime(t.time.year, t.time.month, t.time.day), () => []).add(t);
    }
    final limit = s.todayStats?.dailyLimit ?? 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ?bulk,
      TableHead([
        ('', 1, false),
        (tr('col_time'), 2, false),
        (tr('payee'), 7, false),
        (tr('category'), 5, false),
        (tr('account'), 3, false),
        (tr('d_source'), 3, false),
        (tr('col_amount'), 4, true),
      ]),
      if (txns.isEmpty)
        Padding(padding: const EdgeInsets.all(24), child: Text(tr('d_nothing_found'), style: sans(context, color: Ledger.mutedOf(context)))),
      for (final e in byDay.entries) ...[
        Container(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Ledger.ruleOf(context)))),
          child: Row(children: [
            Expanded(child: Text(DateFormat.MMMMEEEEd(intlLocale).format(e.key), style: sans(context, size: 13.5, weight: FontWeight.w600))),
            () {
              final day = e.value.where((t) => t.kind == TxnKind.expense && !t.excluded).fold<int>(0, (a, t) => a + (s.toBase(t) ?? 0));
              return Text(formatMoney(-day, s.baseCurrency),
                  style: mono(size: 13, color: limit > 0 && day > limit ? warnOf(context) : Ledger.mutedOf(context)));
            }(),
          ]),
        ),
        for (final t in e.value) _row(context, s, t),
      ],
    ]);
  }

  Widget _row(BuildContext context, AppState s, Txn t) {
    final on = t.id == selected;
    final cat = t.categoryId == null ? null : s.categoryById[t.categoryId];
    final acc = t.accountId == null ? null : s.accountById[t.accountId];
    final bg = on ? Ledger.withinOf(context) : (t.needsReview ? Ledger.overOf(context).withValues(alpha: .45) : null);
    return TableLine(
      [
        (
          Checkbox(
            value: checked.contains(t.id),
            visualDensity: VisualDensity.compact,
            onChanged: (v) => onCheck(t, v ?? false),
          ),
          1
        ),
        (Text(DateFormat.Hm().format(t.time), style: mono(size: 12.5, color: Ledger.mutedOf(context))), 2),
        (
          // Shared budget: who recorded it, when it wasn't me.
          s.householdOn && t.author != null && t.author != s.me && s.personOf(t.author) != null
              ? Row(children: [
                  PersonBadge(s.personOf(t.author)!, size: 16),
                  const SizedBox(width: 6),
                  Expanded(child: textCell(context, t.merchant ?? '—', sub: t.note)),
                ])
              : textCell(context, t.merchant ?? '—', sub: t.note),
          7
        ),
        (
          Align(
            alignment: Alignment.centerLeft,
            child: cat == null && t.goalId != null
                ? Text(tr('goal_from', [s.goalNames[t.goalId] ?? '']), overflow: TextOverflow.ellipsis, style: sans(context, size: 13))
                : cat == null
                ? tagWarn(context, tr('d_to_review'))
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    Swatch(Color(cat.color)),
                    const SizedBox(width: 6),
                    Flexible(child: Text(s.categoryName(cat), overflow: TextOverflow.ellipsis, style: sans(context, size: 13))),
                  ]),
          ),
          5
        ),
        (Text(acc == null ? '—' : s.accountName(acc), overflow: TextOverflow.ellipsis, style: sans(context, size: 13)), 3),
        (Text(t.isCaptured ? t.source.split(':').first : tr('src_manual'), overflow: TextOverflow.ellipsis, style: sans(context, size: 12.5, color: Ledger.mutedOf(context))), 3),
        (
          numCell(context, '${t.kind == TxnKind.income ? '+' : '−'}${formatMoney(t.amountMinor, t.currency)}',
              color: t.kind == TxnKind.income ? Ledger.goodOf(context) : (t.excluded ? Ledger.mutedOf(context) : null)),
          4
        ),
      ],
      color: bg,
      padding: compact ? 3 : 7,
      onTap: () => onSelect(t),
    );
  }
}
