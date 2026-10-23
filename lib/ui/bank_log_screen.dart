import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../capture/capture_service.dart';
import '../data/models.dart';
import '../domain/money.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'txn_editor.dart';

/// The last bank notifications: what was recorded, what was skipped and why. A skipped one can be
/// added by hand with its amount pre-filled.
class BankLogScreen extends StatefulWidget {
  const BankLogScreen({super.key});

  @override
  State<BankLogScreen> createState() => _BankLogScreenState();
}

class _BankLogScreenState extends State<BankLogScreen> {
  late Future<List<BankLogEntry>> _entries;

  @override
  void initState() {
    super.initState();
    _entries = context.read<AppState>().capture.bankLog();
  }

  Future<void> _clear() async {
    await context.read<AppState>().capture.clearBankLog();
    setState(() => _entries = Future.value(const []));
  }

  void _add(BankLogEntry e) {
    final state = context.read<AppState>();
    final account = state.accounts.where((a) => a.type == e.app).firstOrNull;
    openTxnEditor(
      context,
      draft: Txn(
        time: e.time,
        amountMinor: e.amountMinor ?? e.guessedAmountMinor ?? 0,
        currency: account?.currency ?? e.currency ?? state.baseCurrency,
        kind: e.kind ?? TxnKind.expense,
        accountId: account?.id,
        merchant: e.merchant,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeFmt = DateFormat('d MMM, HH:mm', currentLanguage);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('bank_log')),
        actions: [IconButton(tooltip: tr('bank_log_clear'), icon: const Icon(Icons.delete_sweep_outlined), onPressed: _clear)],
      ),
      body: FutureBuilder<List<BankLogEntry>>(
        future: _entries,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final entries = snap.data!;
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(tr('bank_log_note'), style: theme.textTheme.bodySmall),
              ),
              if (entries.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(tr('bank_log_empty'))),
              for (final e in entries)
                ListTile(
                  isThreeLine: true,
                  leading: Icon(
                    e.recorded ? Icons.check_circle : Icons.remove_circle_outline,
                    color: e.recorded ? Colors.green.shade600 : theme.colorScheme.outline,
                  ),
                  title: Text(
                    e.recorded && e.amountMinor != null
                        ? '${tr('reason_recorded')}: ${e.kind == TxnKind.income ? '+' : '−'}'
                            '${formatMoney(e.amountMinor!, e.currency ?? 'RUB')}'
                        : tr('reason_${e.reason}'),
                  ),
                  subtitle: Text(
                    '${e.bank} · ${timeFmt.format(e.time)}\n${[e.title, e.text].where((s) => s.isNotEmpty).join(' — ')}',
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: e.recorded || e.reason == 'code'
                      ? null
                      : IconButton(tooltip: tr('add_manually'), icon: const Icon(Icons.add), onPressed: () => _add(e)),
                ),
            ],
          );
        },
      ),
    );
  }
}
