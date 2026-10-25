import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../premium/premium.dart';
import '../state/app_state.dart';
import 'ledger.dart';

/// Settings → Budget Plus: the status (trial, personal key, subscription), what Plus adds, a
/// personal key, and buying it in the store the app came from.
class PlusScreen extends StatelessWidget {
  const PlusScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = state.plusStatus;
    final theme = Theme.of(context);
    final muted = Ledger.mutedOf(context);
    final now = DateTime.now();
    final day = DateFormat.yMMMd(intlLocale);
    final status = switch (s.source) {
      PlusSource.store => tr('plus_by_store'),
      PlusSource.license => s.until == null
          ? tr('plus_by_key', [s.licensee ?? ''])
          : tr('plus_by_key_until', [s.licensee ?? '', day.format(s.until!.subtract(const Duration(days: 1)))]),
      PlusSource.trial => tr('plus_trial', [s.daysLeft(now)]),
      PlusSource.household => tr('plus_by_household', [s.licensee ?? '?']),
      PlusSource.none => tr('plus_off'),
    };
    return Scaffold(
      appBar: AppBar(title: Text(tr('plus_title'))),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(children: [
            Icon(s.active ? Icons.workspace_premium : Icons.workspace_premium_outlined,
                color: s.active ? Ledger.accentOf(context) : muted),
            const SizedBox(width: 10),
            Expanded(child: Text(status, style: theme.textTheme.titleMedium)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(tr(s.source == PlusSource.household ? 'plus_household_note' : 'plus_intro'),
              style: theme.textTheme.bodySmall?.copyWith(color: muted)),
        ),
        LedgerSection(tr('plus_what')),
        for (final f in PlusFeature.values)
          LedgerTile(
            tr('plus_f_${f.name}'),
            hint: tr('plus_f_${f.name}_sub'),
            trailing: s.allows(f) ? Icon(Icons.check, size: 18, color: Ledger.accentOf(context)) : null,
          ),
        LedgerSection(tr('plus_get')),
        LedgerTile(
          tr('plus_buy'),
          hint: tr('plus_buy_sub'),
          onTap: () async {
            final ok = await state.plus.store.buy();
            if (!ok && context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('plus_buy_unavailable'))));
            }
            await state.refreshPlus();
          },
        ),
        LedgerTile(tr('plus_enter_key'), hint: tr('plus_enter_key_sub'), onTap: () => enterPlusKey(context)),
        if (s.source == PlusSource.license)
          LedgerTile(tr('plus_remove_key'), onTap: () => state.removePlusKey()),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text(tr('plus_promise'), style: theme.textTheme.bodySmall?.copyWith(color: muted)),
        ),
      ]),
    );
  }
}

Future<void> enterPlusKey(BuildContext context) async {
  final state = context.read<AppState>();
  final ctrl = TextEditingController();
  final key = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(tr('plus_enter_key')),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        minLines: 2,
        maxLines: 4,
        decoration: InputDecoration(hintText: 'BP1.…'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: Text(tr('ok'))),
      ],
    ),
  );
  if (key == null || key.trim().isEmpty) return;
  final ok = await state.enterPlusKey(key);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(ok ? 'plus_key_ok' : 'plus_key_bad'))));
}

/// Before a Plus action: true when Plus is on; otherwise says what Plus is and offers it.
Future<bool> requirePlus(BuildContext context, PlusFeature feature) async {
  final state = context.read<AppState>();
  if (state.plusAllows(feature)) return true;
  final go = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      icon: const Icon(Icons.workspace_premium_outlined),
      title: Text(tr('plus_needed', [tr('plus_f_${feature.name}')])),
      content: Text(tr(state.plusStatus.source == PlusSource.household ? 'plus_needed_household' : 'plus_needed_sub')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('cancel'))),
        TextButton(onPressed: () => Navigator.pop(c, 'key'), child: Text(tr('plus_enter_key'))),
        FilledButton(onPressed: () => Navigator.pop(c, 'more'), child: Text(tr('plus_more'))),
      ],
    ),
  );
  if (!context.mounted) return false;
  if (go == 'key') await enterPlusKey(context);
  if (go == 'more' && context.mounted) {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PlusScreen()));
  }
  return state.plusAllows(feature);
}

/// The settings line under "Budget Plus": where it comes from, or what it would add.
String plusTileHint(PlusStatus s) {
  final short = switch (s.source) {
    PlusSource.store => tr('plus_short_store'),
    PlusSource.license => tr('plus_short_key'),
    PlusSource.trial => '${tr('plus_short_trial')} · ${s.daysLeft(DateTime.now())}',
    PlusSource.household => tr('plus_short_household', [s.licensee ?? '?']),
    PlusSource.none => null,
  };
  return short == null ? tr('plus_tile_sub_off') : tr('plus_tile_sub_on', [short]);
}
