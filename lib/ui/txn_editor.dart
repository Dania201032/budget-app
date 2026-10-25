import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../domain/currencies.dart';
import '../domain/money.dart';
import '../domain/tax_tags.dart';
import '../io/receipts.dart';
import '../l10n/strings.dart';
import '../platform.dart';
import '../state/app_state.dart';
import 'goal_spend.dart';
import 'ledger.dart';
import 'lock_screen.dart';
import 'receipt_view.dart';
import 'split_sheet.dart';

/// [draft] pre-fills a new transaction (e.g. from a skipped bank notification).
Future<void> openTxnEditor(BuildContext context, {Txn? txn, Txn? draft}) => Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TxnEditor(txn: txn, draft: draft), fullscreenDialog: true),
    );

/// Sum of an expression like "45,5+12−3" in minor units; null if it isn't a positive amount.
int? evaluateAmount(String expr) {
  final s = expr.replaceAll(RegExp(r'[\s  ]'), '').replaceAll('-', '−');
  if (s.isEmpty) return null;
  final parts = RegExp(r'([+−]?)([^+−]*)').allMatches(s).where((m) => m.group(0)!.isNotEmpty);
  var total = 0;
  for (final m in parts) {
    if (m.group(2)!.isEmpty) continue; // a trailing operator
    final v = double.tryParse(m.group(2)!.replaceAll(',', '.'));
    if (v == null) return null;
    final minor = (v * 100).round();
    total += m.group(1) == '−' ? -minor : minor;
  }
  return total > 0 ? total : null;
}

/// 4550 -> "45,5" (no grouping, so it can be edited further).
String _plainAmount(int minor) {
  final whole = minor ~/ 100;
  final cents = minor % 100;
  if (cents == 0) return '$whole';
  final c = cents.toString().padLeft(2, '0');
  return '$whole,${c.endsWith('0') ? c[0] : c}';
}

class TxnEditor extends StatefulWidget {
  final Txn? txn;
  final Txn? draft;
  const TxnEditor({super.key, this.txn, this.draft});

  @override
  State<TxnEditor> createState() => _TxnEditorState();
}

class _TxnEditorState extends State<TxnEditor> {
  late TxnKind _kind;
  late DateTime _time;
  int? _categoryId;
  int? _accountId;

  /// "Close a goal": the goal that paid for this purchase, and (when just chosen) whether it is
  /// reached and closed.
  int? _goalId;

  /// The receipt's photo (a file name on this device) and the operation's own tax mark.
  String? _receipt;
  String? _taxTag;
  bool _goalChosen = false;
  bool _closeGoal = false;
  late bool _excluded;
  late bool _ownTransfer;


  /// The other account of an own transfer ("from which" / "to which"); null = not in the app.
  int? _counterId;
  bool _counterChanged = false;
  late String _expr;
  late bool _keypad;
  late final TextEditingController _merchant;
  late final TextEditingController _note;
  bool _remember = true;

  bool get _isNew => widget.txn == null;

  @override
  void initState() {
    super.initState();
    final t = widget.txn ?? widget.draft;
    final state = context.read<AppState>();
    _kind = t?.kind ?? TxnKind.expense;
    _time = t?.time ?? DateTime.now();
    _categoryId = t?.categoryId;
    _goalId = t?.goalId;
    _receipt = t?.receipt;
    _taxTag = t?.taxTag;
    _accountId = t?.accountId ?? state.accounts.firstOrNull?.id;
    _excluded = t?.excluded ?? false;
    _ownTransfer = t?.ownTransfer ?? false;
    if (t?.pairId != null) {
      state.repo.txnById(t!.pairId!).then((p) {
        if (!mounted) return;
        setState(() {
          if (!_counterChanged) _counterId = p?.accountId;
        });
      });
    }
    _expr = t == null || t.amountMinor == 0 ? '' : _plainAmount(t.amountMinor);
    _keypad = _isNew || t?.amountMinor == 0;
    _merchant = TextEditingController(text: t?.merchant ?? '');
    _note = TextEditingController(text: t?.note ?? '');
  }

  @override
  void dispose() {
    _merchant.dispose();
    _note.dispose();
    super.dispose();
  }

  // --- Calculator keypad ---

  bool get _hasOperator => _expr.contains(RegExp(r'[+−]'));

  void _key(String k) {
    HapticFeedback.selectionClick();
    setState(() {
      final last = _expr.isEmpty ? '' : _expr[_expr.length - 1];
      final term = _expr.split(RegExp(r'[+−]')).last;
      switch (k) {
        case '⌫':
          if (_expr.isNotEmpty) _expr = _expr.substring(0, _expr.length - 1);
        case '=':
          final v = evaluateAmount(_expr);
          if (v != null) _expr = _plainAmount(v);
        case '+' || '−':
          if (_expr.isEmpty) return;
          _expr = '+−'.contains(last) ? _expr.substring(0, _expr.length - 1) + k : _expr + k;
        case ',':
          if (term.contains(',')) return;
          _expr += term.isEmpty ? '0,' : ',';
        default: // digits, "00"
          final decimals = term.contains(',') ? term.split(',').last.length : -1;
          if (decimals >= 2) return;
          final d = k == '00' && decimals == 1 ? '0' : k;
          if (term == '0') {
            // Replace a leading zero; "0" + "0" stays "0".
            if (d.startsWith('0')) return;
            _expr = _expr.substring(0, _expr.length - 1) + d;
          } else if (term.isEmpty && d == '00') {
            _expr += '0';
          } else {
            _expr += d;
          }
      }
    });
  }

  void _showKeypad() {
    FocusScope.of(context).unfocus();
    setState(() => _keypad = true);
  }

  // --- Saving ---

  /// Saves and returns the saved transaction (with id), or null if the input is invalid.
  Future<Txn?> _save({bool close = true}) async {
    final state = context.read<AppState>();
    final amount = evaluateAmount(_expr);
    if (amount == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('enter_amount'))));
      return null;
    }
    final account = _accountId == null ? null : state.accountById[_accountId];
    final merchant = _merchant.text.trim().isEmpty ? null : _merchant.text.trim();
    final note = _note.text.trim().isEmpty ? null : _note.text.trim();
    final base = widget.txn ??
        Txn(time: _time, amountMinor: amount, currency: account?.currency ?? state.baseCurrency, kind: _kind);
    // A changed total invalidates an old split.
    final keepShare = base.shareMinor != null && amount == base.amountMinor;
    final txn = base.copyWith(
      time: _time,
      amountMinor: amount,
      shareMinor: () => keepShare ? base.shareMinor : null,
      excluded: _excluded || _ownTransfer,
      currency: account?.currency ?? base.currency,
      kind: _kind,
      categoryId: () => _categoryId,
      accountId: () => _accountId,
      merchant: () => merchant,
      note: () => note,
      receipt: () => _receipt,
      taxTag: () => _taxTag,
      needsReview: _categoryId == null && base.isCaptured && !_ownTransfer,
    );
    final id = await state.saveTxn(txn, rememberMerchant: _remember);
    final savedTxn = await state.repo.txnById(id);
    if (savedTxn != null) {
      final goal = _goalId == null ? null : state.goals.where((g) => g.id == _goalId).firstOrNull;
      if (_goalChosen && goal != null) {
        await state.spendFromGoal(savedTxn, goal, close: _closeGoal);
      } else if (base.goalId != null && _goalId == null) {
        await state.returnToGoal(savedTxn, accountId: _accountId);
      }
    }
    if (!keepShare && base.isSplit) await state.removeSplit(txn);
    if (_ownTransfer != base.ownTransfer) {
      final saved = await state.repo.txnById(id);
      if (saved != null) await state.setOwnTransfer(saved, _ownTransfer);
    }
    if (_ownTransfer && _counterChanged) {
      final saved = await state.repo.txnById(id);
      final ok = saved == null || await state.setTransferCounterpart(saved, state.accountById[_counterId]);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('transfer_no_rate'))));
      }
    }
    // A light tap of the vibration motor: saved.
    HapticFeedback.lightImpact();
    if (close && mounted) Navigator.pop(context);
    return state.repo.txnById(id);
  }

  String _taxTagLabel(AppState state) {
    final own = _taxTag;
    final tag = own == 'none' ? null : (own ?? state.categoryTaxTag(_categoryId));
    return tag == null ? tr('tax_mark_none_short') : '${tr('tax_mark')}: ${tr('tax_$tag')}';
  }

  Future<void> _chooseTaxTag(AppState state) async {
    final cat = state.categoryTaxTag(_categoryId);
    const asCategory = '';
    final v = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(tr('tax_mark'), style: Theme.of(c).textTheme.titleMedium),
          ),
          ListTile(
            title: Text(tr('tax_as_category', [cat == null ? tr('tax_mark_none_short') : tr('tax_$cat')])),
            trailing: _taxTag == null ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(c, asCategory),
          ),
          for (final t in taxTagKeys)
            ListTile(
              title: Text(tr('tax_$t')),
              trailing: _taxTag == t ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(c, t),
            ),
          ListTile(
            title: Text(tr('tax_mark_none')),
            trailing: _taxTag == 'none' ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(c, 'none'),
          ),
        ]),
      ),
    );
    if (v == null) return;
    setState(() => _taxTag = v == asCategory ? null : v);
  }

  /// Camera or gallery, then the receipt is read: amount, time, shop (and the account in its
  /// currency) fill in what is still empty.
  Future<void> _scanReceipt(AppState state) async {
    final camera = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.photo_camera_outlined), title: Text(tr('rc_camera')), onTap: () => Navigator.pop(c, true)),
          ListTile(leading: const Icon(Icons.photo_library_outlined), title: Text(tr('rc_gallery')), onTap: () => Navigator.pop(c, false)),
        ]),
      ),
    );
    if (camera == null) return;
    final String? path = camera
        ? await appLock.whileInSystemScreen(state.capture.takeReceiptPhoto)
        : (await appLock.whileInSystemScreen(() => FilePicker.pickFiles(type: FileType.image))).firstOrNull?.path;
    if (path == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final guess = await state.scanReceipt(path);
    final name = await keepReceipt(path);
    if (!mounted) return;
    setState(() {
      _receipt = name;
      if (guess.amountMinor != null) _expr = _plainAmount(guess.amountMinor!);
      if (guess.time != null) _time = guess.time!;
      if (guess.shop != null && _merchant.text.trim().isEmpty) _merchant.text = guess.shop!;
      if (guess.refund) _kind = TxnKind.income;
      final cur = guess.currency;
      final account = _accountId == null ? null : state.accountById[_accountId];
      if (cur != null && account?.currency != cur) {
        final other = state.accounts.where((a) => a.currency == cur).firstOrNull;
        if (other != null) _accountId = other.id;
      }
    });
    messenger.showSnackBar(SnackBar(
      content: Text(guess.isEmpty
          ? tr('rc_nothing')
          : tr('rc_read', [guess.amountMinor == null ? '—' : formatMoney(guess.amountMinor!, guess.currency ?? state.baseCurrency)])),
    ));
  }

  /// "From which account" (an income) / "to which account" (an expense) of a transfer to myself.
  Future<void> _pickCounter(AppState state) async {
    const notInApp = -1;
    final id = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(tr(_kind == TxnKind.expense ? 'transfer_to_account' : 'transfer_from_account'),
                style: Theme.of(c).textTheme.titleMedium),
          ),
          for (final a in state.accounts.where((a) => a.id != _accountId))
            ListTile(
              leading: Text(currencySymbol(a.currency), style: mono(size: 16)),
              title: Text(state.accountName(a)),
              trailing: a.id == _counterId ? Icon(Icons.check, color: Ledger.accentOf(c)) : Text(a.currency, style: mono(size: 12)),
              onTap: () => Navigator.pop(c, a.id),
            ),
          ListTile(
            leading: const Icon(Icons.more_horiz),
            title: Text(tr('transfer_not_in_app')),
            trailing: _counterId == null ? Icon(Icons.check, color: Ledger.accentOf(c)) : null,
            onTap: () => Navigator.pop(c, notInApp),
          ),
        ]),
      ),
    );
    if (id == null) return;
    setState(() {
      _counterId = id == notInApp ? null : id;
      _counterChanged = true;
    });
  }

  /// Saves, then asks which friend's debt this income pays back.
  Future<void> _payback() async {
    final state = context.read<AppState>();
    final t = await _save(close: false);
    if (t == null || !mounted) return;
    final debt = await showModalBottomSheet<Debt>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(tr('payback_pick'), style: Theme.of(ctx).textTheme.titleMedium),
          ),
          for (final d in state.openDebts)
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(d.person ?? tr('unnamed_friend')),
              subtitle: Text(DateFormat.yMMMd(intlLocale).format(d.createdAt)),
              trailing: Text(formatMoney(d.openMinor, d.currency), style: mono(size: 14)),
              onTap: () => Navigator.pop(ctx, d),
            ),
        ]),
      ),
    );
    if (debt == null) return;
    await state.settleDebtWith(debt, t);
    if (mounted) Navigator.pop(context);
  }

  /// Saves what's on screen, then opens the split sheet for the stored transaction.
  Future<void> _split() async {
    final t = await _save(close: false);
    if (t == null || !mounted) return;
    await showSplitSheet(context, t);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('delete_op_q')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('delete'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AppState>().deleteTxn(widget.txn!);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _pickDateTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _time,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_time));
    setState(() {
      _time = DateTime(date.year, date.month, date.day, time?.hour ?? _time.hour, time?.minute ?? _time.minute);
    });
  }

  Future<void> _pickAccount(AppState state) async {
    final id = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          for (final a in state.accounts)
            ListTile(
              leading: Text(currencySymbol(a.currency), style: mono(size: 16)),
              title: Text(state.accountName(a)),
              trailing: a.id == _accountId ? Icon(Icons.check, color: Ledger.accentOf(c)) : Text(a.currency, style: mono(size: 12)),
              onTap: () => Navigator.pop(c, a.id),
            ),
        ]),
      ),
    );
    if (id != null) setState(() => _accountId = id);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final categories = state.categoriesOf(_kind);
    final account = _accountId == null ? null : state.accountById[_accountId];
    final currency = account?.currency ?? widget.txn?.currency ?? state.baseCurrency;
    final t = widget.txn;
    final captured = t?.isCaptured ?? false;
    final ink = Ledger.inkOf(context);
    final muted = Ledger.mutedOf(context);
    final rule = Ledger.ruleOf(context);
    final result = _hasOperator ? evaluateAmount(_expr) : null;

    Widget kindTab(TxnKind k, String label) {
      final selected = _kind == k;
      return Expanded(
        child: InkWell(
          onTap: () => setState(() {
            _kind = k;
            if (_categoryId != null && state.categoryById[_categoryId]?.kind != _kind) _categoryId = null;
          }),
          child: Container(
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: selected ? Ledger.accentOf(context) : Colors.transparent, width: 3)),
            ),
            child: Text(label, style: mono(size: 14, weight: selected ? FontWeight.w600 : FontWeight.w400, color: selected ? ink : muted)),
          ),
        ),
      );
    }

    Widget field(String label, Widget value, {VoidCallback? onTap}) => InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 46),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: rule))),
            child: Row(children: [
              SizedBox(width: 116, child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: muted))),
              Expanded(child: value),
            ]),
          ),
        );

    Widget input(TextEditingController c) => TextField(
          controller: c,
          onTap: () => setState(() => _keypad = false),
          onChanged: (_) => setState(() {}),
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            isDense: true,
            hintText: '—',
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
          ),
        );

    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? tr('new_op') : tr('op')),
        actions: [
          if (!_isNew) IconButton(icon: const Icon(Icons.delete_outline), tooltip: tr('delete'), onPressed: _delete),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(onPressed: _save, child: Text(tr('save'))),
          ),
        ],
      ),
      body: Column(children: [
        Container(
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ink))),
          child: Row(children: [kindTab(TxnKind.expense, tr('expense')), kindTab(TxnKind.income, tr('income_one'))]),
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
            // Amount: tap to bring the calculator back.
            InkWell(
              onTap: _showKeypad,
              child: Container(
                padding: const EdgeInsets.fromLTRB(0, 14, 0, 12),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: rule))),
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      LedgerCaption(tr('amount')),
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text(_expr.isEmpty ? '0' : _expr,
                              style: mono(size: 42, color: _expr.isEmpty ? muted : ink, height: 1.1)),
                          if (_keypad) Container(width: 2, height: 40, margin: const EdgeInsets.only(left: 3), color: Ledger.accentOf(context)),
                        ]),
                      ),
                      if (result != null) Text('= ${_plainAmount(result)}', style: mono(size: 14, color: muted)),
                    ]),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(border: Border.all(color: ink), borderRadius: BorderRadius.circular(3)),
                    child: Text('${currencySymbol(currency)} $currency', style: mono(size: 13)),
                  ),
                ]),
              ),
            ),
            if (_kind == TxnKind.income && !_ownTransfer && !(t?.excluded ?? false) && state.openDebts.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _payback,
                  icon: const Icon(Icons.handshake_outlined, size: 18),
                  label: Text(tr('payback_button')),
                ),
              ),
            if (_kind == TxnKind.expense && !_ownTransfer)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _split,
                  icon: const Icon(Icons.call_split, size: 18),
                  label: Text(t != null && t.isSplit
                      ? '${tr('split_bill')} · ${tr('my_share', [formatMoney(t.shareMinor!, t.currency)])}'
                      : tr('split_bill')),
                ),
              ),
            // Paid from a goal's savings: the money left the account when it was put aside.
            if (_kind == TxnKind.expense && !_ownTransfer && (state.goals.isNotEmpty || _goalId != null))
              Row(children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () async {
                        final r = await chooseGoalSpend(context, state);
                        if (r == null || !mounted) return;
                        setState(() {
                          _goalId = r.$1.id;
                          _closeGoal = r.$2;
                          _goalChosen = true;
                        });
                      },
                      icon: Icon(_goalId == null ? Icons.outlined_flag : Icons.flag, size: 18),
                      label: Text(
                        _goalId == null
                            ? tr('goal_close')
                            : [
                                tr('goal_from', [state.goalNames[_goalId] ?? '']),
                                if (_goalChosen) tr(_closeGoal ? 'goal_close_full' : 'goal_close_part'),
                              ].join(' · '),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
                if (_goalId != null)
                  IconButton(
                    tooltip: tr('goal_unlink'),
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() {
                      _goalId = null;
                      _goalChosen = false;
                    }),
                  ),
              ]),
            if (_goalId != null)
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 4),
                child: Text(tr('goal_no_account_hint'), style: Theme.of(context).textTheme.bodySmall),
              ),
            // A photo of the receipt: read on the phone, kept with the operation.
            if (_kind == TxnKind.expense && !appIsDesktop)
              Row(children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => _scanReceipt(state),
                      icon: Icon(_receipt == null ? Icons.document_scanner_outlined : Icons.receipt_long, size: 18),
                      label: Text(tr(_receipt == null ? 'rc_scan' : 'rc_attached')),
                    ),
                  ),
                ),
                if (_receipt != null) ...[
                  IconButton(tooltip: tr('rc_show'), icon: const Icon(Icons.image_outlined, size: 18), onPressed: () => showReceipt(context, _receipt!)),
                  IconButton(tooltip: tr('rc_remove'), icon: const Icon(Icons.close, size: 18), onPressed: () => setState(() => _receipt = null)),
                ],
              ]),
            // What may lower the tax: the category's mark, or the operation's own.
            if (_kind == TxnKind.expense)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _chooseTaxTag(state),
                  icon: const Icon(Icons.account_balance_outlined, size: 18),
                  label: Text(_taxTagLabel(state), overflow: TextOverflow.ellipsis),
                ),
              ),
            LedgerSection(tr('category'), padding: const EdgeInsets.only(top: 6, bottom: 8)),
            Container(
              color: rule,
              padding: const EdgeInsets.all(1),
              child: GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 1,
                crossAxisSpacing: 1,
                childAspectRatio: 2.6,
                padding: EdgeInsets.zero,
                children: [
                  for (final c in categories)
                    _CategoryCell(
                      name: state.categoryName(c),
                      color: Color(c.color),
                      selected: _categoryId == c.id,
                      onTap: () => setState(() => _categoryId = _categoryId == c.id ? null : c.id),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            field(tr('payee'), input(_merchant)),
            field(
              tr('account'),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(children: [
                  Expanded(child: Text(account == null ? '—' : state.accountName(account))),
                  Icon(Icons.expand_more, size: 18, color: muted),
                ]),
              ),
              onTap: () => _pickAccount(state),
            ),
            field(
              tr('date'),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '${DateFormat('dd.MM.yyyy', intlLocale).format(_time)} · ${DateFormat.Hm(intlLocale).format(_time)}',
                  style: mono(size: 14, weight: FontWeight.w400),
                ),
              ),
              onTap: _pickDateTime,
            ),
            field(tr('comment'), input(_note)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _ownTransfer,
              onChanged: (v) => setState(() => _ownTransfer = v),
              title: Text(tr('own_transfer')),
              subtitle: Text(tr('own_transfer_sub')),
            ),
            if (_ownTransfer)
              field(
                tr(_kind == TxnKind.expense ? 'transfer_to_account' : 'transfer_from_account'),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(children: [
                    Expanded(
                      child: Text(switch (state.accountById[_counterId]) {
                        null => tr('transfer_not_in_app'),
                        final a => state.accountName(a),
                      }),
                    ),
                    Icon(Icons.expand_more, size: 18, color: muted),
                  ]),
                ),
                onTap: () => _pickCounter(state),
              ),
            if (!_ownTransfer)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _excluded,
                onChanged: (v) => setState(() => _excluded = v),
                title: Text(tr('not_counted')),
              ),
            if (captured && _merchant.text.isNotEmpty)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _remember,
                onChanged: (v) => setState(() => _remember = v ?? true),
                title: Text(tr('remember_category', [_merchant.text])),
              ),
            if (captured) ...[
              const SizedBox(height: 8),
              Text(tr('auto_recorded', [t!.source]), style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            ],
          ]),
        ),
        if (_keypad && MediaQuery.viewInsetsOf(context).bottom == 0) _Keypad(onKey: _key, onClear: () => setState(() => _expr = '')),
      ]),
    );
  }
}

class _CategoryCell extends StatelessWidget {
  final String name;
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  const _CategoryCell({required this.name, required this.color, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = Ledger.inkOf(context);
    return Material(
      color: selected ? ink : theme.colorScheme.surface,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(children: [
            Container(width: 8, height: 8, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: selected ? theme.colorScheme.surface : ink,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  height: 1.15,
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Digits, decimal comma, + and − for adding up a receipt; "=" shows the total. Long-press ⌫ clears.
class _Keypad extends StatelessWidget {
  final ValueChanged<String> onKey;
  final VoidCallback onClear;
  const _Keypad({required this.onKey, required this.onClear});

  static const _keys = ['7', '8', '9', '⌫', '4', '5', '6', '+', '1', '2', '3', '−', ',', '0', '00', '='];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rule = Ledger.ruleOf(context);
    final ink = Ledger.inkOf(context);
    final localizations = MaterialLocalizations.of(context);
    return Container(
      decoration: BoxDecoration(color: rule, border: Border(top: BorderSide(color: ink))),
      child: SafeArea(
        top: false,
        child: GridView.count(
          crossAxisCount: 4,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 1,
          crossAxisSpacing: 1,
          childAspectRatio: 1.9,
          padding: EdgeInsets.zero,
          children: [
            for (final k in _keys)
              Material(
                color: '⌫+−='.contains(k) ? Ledger.shadeOf(context) : theme.colorScheme.surface,
                child: InkWell(
                  onTap: () => onKey(k),
                  onLongPress: k == '⌫' ? onClear : null,
                  child: Center(
                    child: k == '⌫'
                        ? Icon(Icons.backspace_outlined, size: 22, color: ink, semanticLabel: localizations.deleteButtonTooltip)
                        : Text(k, style: mono(size: 22, weight: FontWeight.w400, color: k == '=' ? Ledger.accentOf(context) : ink)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
