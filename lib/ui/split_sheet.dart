import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../domain/currencies.dart';
import '../domain/money.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'ledger.dart';

/// "Split the bill": equally or by my share; friends' names are optional (with a name, their
/// WeChat/Alipay payback is matched by name; without — by the exact amount).
Future<void> showSplitSheet(BuildContext context, Txn txn) async {
  final state = context.read<AppState>();
  final existing = await state.debtsOf(txn);
  final contacts = await state.repo.recentContacts();
  if (!context.mounted) return;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _SplitSheet(txn: txn, existing: existing, contacts: contacts),
  );
}

class _SplitSheet extends StatefulWidget {
  final Txn txn;
  final List<Debt> existing;
  final List<String> contacts;
  const _SplitSheet({required this.txn, required this.existing, required this.contacts});

  @override
  State<_SplitSheet> createState() => _SplitSheetState();
}

class _SplitSheetState extends State<_SplitSheet> {
  late int _people = widget.existing.isEmpty ? 2 : widget.existing.length + 1;
  /// equal parts, my share typed in, or all of it for friends (I paid for them).
  late _Mode _mode = widget.txn.shareMinor == 0
      ? _Mode.forFriends
      : (!widget.txn.isSplit || _isEqual() ? _Mode.equal : _Mode.mine);
  late final TextEditingController _mine = TextEditingController(
    text: widget.txn.isSplit ? (widget.txn.shareMinor! / 100).toString().replaceAll(RegExp(r'\.0$'), '') : '',
  );
  final List<TextEditingController> _names = [];

  bool _isEqual() {
    final t = widget.txn;
    return t.shareMinor! == t.amountMinor - (t.amountMinor ~/ (widget.existing.length + 1)) * widget.existing.length;
  }

  @override
  void initState() {
    super.initState();
    _syncNames();
    for (var i = 0; i < widget.existing.length && i < _names.length; i++) {
      _names[i].text = widget.existing[i].person ?? '';
    }
  }

  void _syncNames() {
    while (_names.length < _people - 1) {
      _names.add(TextEditingController());
    }
    while (_names.length > _people - 1) {
      _names.removeLast().dispose();
    }
  }

  @override
  void dispose() {
    _mine.dispose();
    for (final c in _names) {
      c.dispose();
    }
    super.dispose();
  }

  int get _total => widget.txn.amountMinor;

  int get _myShare {
    if (_mode == _Mode.forFriends) return 0;
    if (_mode == _Mode.equal) return _total - (_total ~/ _people) * (_people - 1);
    return (parseAmountToMinor(_mine.text) ?? 0).clamp(0, _total);
  }

  /// Equal parts of what's left for friends; the remainder cent goes to the first friend.
  List<int> get _friendShares {
    final rest = _total - _myShare;
    final n = _people - 1;
    if (n <= 0) return const [];
    final base = rest ~/ n;
    return [for (var i = 0; i < n; i++) base + (i == 0 ? rest - base * n : 0)];
  }

  Future<void> _apply() async {
    final shares = _friendShares;
    await context.read<AppState>().applySplit(widget.txn, _myShare, [
      for (var i = 0; i < shares.length; i++) (_names[i].text.trim().isEmpty ? null : _names[i].text.trim(), shares[i]),
    ]);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cur = widget.txn.currency;
    final shares = _friendShares;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('split_bill'), style: theme.textTheme.titleLarge),
          Text(formatMoney(_total, cur), style: theme.textTheme.headlineSmall),
          const SizedBox(height: 12),
          SegmentedButton<_Mode>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: _Mode.equal, label: segmentLabel(tr('split_equal'))),
              ButtonSegment(value: _Mode.mine, label: segmentLabel(tr('split_my_share'))),
              ButtonSegment(value: _Mode.forFriends, label: segmentLabel(tr('split_for_friend'))),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: Text(tr('people_count'))),
            IconButton.outlined(
              icon: const Icon(Icons.remove),
              onPressed: _people > 2 ? () => setState(() { _people--; _syncNames(); }) : null,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('$_people', style: theme.textTheme.titleLarge),
            ),
            IconButton.outlined(
              icon: const Icon(Icons.add),
              onPressed: _people < 30 ? () => setState(() { _people++; _syncNames(); }) : null,
            ),
          ]),
          if (_mode == _Mode.mine)
            TextField(
              controller: _mine,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: tr('my_part'), suffixText: currencySymbol(cur)),
              onChanged: (_) => setState(() {}),
            ),
          const SizedBox(height: 12),
          Text(tr('friends'), style: theme.textTheme.titleSmall),
          Text(tr('friends_hint'), style: theme.textTheme.bodySmall),
          if (widget.contacts.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final c in widget.contacts)
                ActionChip(
                  label: Text(c),
                  onPressed: () => setState(() {
                    final empty = _names.where((n) => n.text.trim().isEmpty).firstOrNull;
                    if (empty != null) empty.text = c;
                  }),
                ),
            ]),
          ],
          for (var i = 0; i < _names.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _names[i],
                    decoration: InputDecoration(isDense: true, labelText: tr('friend_n', [i + 1])),
                  ),
                ),
                const SizedBox(width: 12),
                Text(formatMoney(i < shares.length ? shares[i] : 0, cur)),
              ]),
            ),
          const Divider(height: 24),
          Row(children: [
            Expanded(child: Text(tr('my_part'), style: theme.textTheme.titleMedium)),
            Text(formatMoney(_myShare, cur), style: theme.textTheme.titleMedium),
          ]),
          Row(children: [
            Expanded(child: Text(tr('friends_owe'))),
            Text(formatMoney(_total - _myShare, cur)),
          ]),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: _apply, icon: const Icon(Icons.call_split), label: Text(tr('split_apply'))),
          if (widget.txn.isSplit)
            TextButton(
              onPressed: () async {
                await context.read<AppState>().removeSplit(widget.txn);
                if (context.mounted) Navigator.pop(context);
              },
              child: Text(tr('split_remove')),
            ),
        ]),
      ),
    );
  }
}

/// How the bill is shared.
enum _Mode { equal, mine, forFriends }
