import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_service.dart';
import 'ledger.dart';

/// A first sync can take minutes (the cloud app carries every file across): instead of a bare
/// spinner, the steps done so far with ticks, the current one with its numbers, and a word that
/// everything was done right.
class SyncProgressView extends StatefulWidget {
  final SyncService sync;

  /// Connecting just now: the folder and the password are shown as done steps first.
  final bool connecting;
  const SyncProgressView(this.sync, {super.key, this.connecting = true});

  @override
  State<SyncProgressView> createState() => _SyncProgressViewState();
}

class _SyncProgressViewState extends State<SyncProgressView> {
  /// The stages in the order this sync went through them (joining a shared budget receives first).
  final _seen = <SyncStage>[];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = Ledger.mutedOf(context);
    return ListenableBuilder(
      listenable: widget.sync,
      builder: (context, _) {
        final p = widget.sync.progress;
        if (p != null && (_seen.isEmpty || _seen.last != p.stage)) {
          _seen.remove(p.stage);
          _seen.add(p.stage);
        }
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('syp_title'), style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          if (widget.connecting) ...[
            _line(context, true, tr('syp_folder')),
            _line(context, true, tr('syp_password')),
          ],
          if (p == null) _line(context, false, tr('syp_check')),
          for (final s in _seen) _line(context, s != p?.stage, s == p?.stage ? describe(p!) : tr('syp_${s.name}_done')),
          if (p != null && p.total > 0) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: (p.done / p.total).clamp(0.0, 1.0)),
          ],
          const SizedBox(height: 14),
          Text(tr('syp_ok'), style: theme.textTheme.bodySmall?.copyWith(color: muted)),
        ]);
      },
    );
  }

  Widget _line(BuildContext context, bool done, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(
            width: 22,
            height: 22,
            child: done
                ? Icon(Icons.check_circle, size: 22, color: Ledger.goodOf(context))
                : const Padding(padding: EdgeInsets.all(3), child: CircularProgressIndicator(strokeWidth: 2.4)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ]),
      );
}

/// "Sending to the folder: file 2 of 5", for the step list and the status lines.
String describe(SyncProgress p) {
  final base = tr('syp_${p.stage.name}', [p.done, p.total]);
  return p.stage == SyncStage.receive && p.changes > 0 ? '$base · ${tr('syp_changes', [p.changes])}' : base;
}

/// The progress while connecting, then what came of it: done, the first device (now the second
/// one), or the cloud still bringing files (the app takes them by itself).
Future<T> runWithSyncProgress<T>(BuildContext context, SyncService sync, Future<T> Function() work,
    {bool connecting = true}) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(content: SyncProgressView(sync, connecting: connecting)),
    ),
  );
  try {
    return await work();
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

Future<void> showSyncResult(BuildContext context, SyncReport r) => showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        icon: Icon(Icons.check_circle, color: Ledger.goodOf(c), size: 40),
        title: Text(tr(r.alone ? 'syr_alone_title' : 'syr_title')),
        content: Text(r.alone
            ? tr('syr_alone')
            : r.pending > 0
                ? tr('syr_pending', [r.received, r.pending])
                : tr('syr_done', [r.received, r.sent])),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(tr('ok')))],
      ),
    );

/// One line for the status rows: what sync is doing now, the files the cloud still has to bring,
/// or that the folder waits for a second device. Null when there's nothing to say.
String? syncStatusNote(SyncService sync) {
  final p = sync.progress;
  if (sync.busy && p != null) return describe(p);
  final r = sync.lastReport;
  if (r == null) return null;
  if (r.pending > 0) return tr('sys_pending', [r.pending]);
  if (r.alone && sync.otherDeviceSeen == null) return tr('sys_waiting');
  return null;
}
