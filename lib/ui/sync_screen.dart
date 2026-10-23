import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../platform.dart';
import '../state/app_state.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_folder.dart';
import '../sync/sync_service.dart';
import 'ledger.dart';

/// Settings → Sync: the phone and the computer share their data through a Google Drive folder.
class SyncScreen extends StatelessWidget {
  /// Opened from the computer's first start ("I have data on my phone"): closes once joined.
  final bool closeWhenJoined;
  const SyncScreen({super.key, this.closeWhenJoined = false});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final sync = state.sync;
    final theme = Theme.of(context);
    final muted = Ledger.mutedOf(context);
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text(tr('sync'))),
        body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(tr('sync_explain'), style: theme.textTheme.bodyMedium),
          ),
          if (!sync.enabled) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: FilledButton.icon(
                icon: const Icon(Icons.folder_open),
                label: Text(tr('sync_choose_folder')),
                onPressed: sync.busy ? null : () => _setUp(context, state),
              ),
            ),
          ] else ...[
            LedgerSection(tr('sync')),
            LedgerTile(tr('sync_folder'), hint: sync.folderLabel),
            LedgerTile(
              tr('sync_last'),
              value: sync.lastSync == null ? tr('never') : DateFormat('dd.MM HH:mm', intlLocale).format(sync.lastSync!),
              hint: sync.lastError == null ? null : tr('sync_error', [sync.lastError]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: FilledButton.icon(
                icon: sync.busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync),
                label: Text(sync.busy ? tr('sync_working') : tr('sync_now')),
                onPressed: sync.busy ? null : () => state.syncNow(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextButton(onPressed: sync.busy ? null : () => _turnOff(context, state), child: Text(tr('sync_off'))),
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text(tr('sync_when'), style: theme.textTheme.bodySmall?.copyWith(color: muted)),
          ),
        ]),
      ),
    );
  }

  Future<void> _setUp(BuildContext context, AppState state) async {
    final SyncFolder folder;
    final String kind;
    final String location;
    if (appIsDesktop) {
      final path = await FilePicker.getDirectoryPath(dialogTitle: tr('sync_choose_folder'));
      if (path == null) return;
      folder = IoSyncFolder(path);
      kind = 'io';
      location = path;
    } else {
      final picked = await SafSyncFolder.pick();
      if (picked == null) return;
      folder = SafSyncFolder(picked.$1, picked.$2);
      kind = 'saf';
      location = picked.$1;
    }
    if (!context.mounted) return;
    final exists = await SyncService.hasGroup(folder);
    if (!context.mounted) return;
    final password = await _askPassword(context, newGroup: !exists);
    if (password == null || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 20),
          Expanded(child: Text(tr('sync_working'))),
        ]),
      ),
    );
    try {
      final r = await state.connectSync(folder, password, kind: kind, location: location);
      nav.pop();
      messenger.showSnackBar(SnackBar(content: Text(tr('sync_done', [r.received, r.sent]))));
      if (closeWhenJoined) nav.pop(true);
    } on WrongSyncPassword {
      nav.pop();
      messenger.showSnackBar(SnackBar(content: Text(tr('sync_wrong_password'))));
    } catch (e) {
      nav.pop();
      messenger.showSnackBar(SnackBar(content: Text(tr('sync_error', ['$e']))));
    }
  }

  /// A new folder: the password twice; a folder another device already uses: its password once.
  Future<String?> _askPassword(BuildContext context, {required bool newGroup}) async {
    final first = TextEditingController();
    final second = TextEditingController();
    String? error;
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(tr(newGroup ? 'sync_password_new' : 'sync_password_enter')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(tr(newGroup ? 'sync_password_new_sub' : 'sync_password_enter_sub'),
                style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(controller: first, obscureText: true, autofocus: true,
                decoration: InputDecoration(labelText: tr('sync_password_enter'), errorText: newGroup ? null : error)),
            if (newGroup)
              TextField(controller: second, obscureText: true,
                  decoration: InputDecoration(labelText: tr('repeat_password'), errorText: error)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
            FilledButton(
              onPressed: () {
                if (first.text.length < 6) {
                  setState(() => error = tr('sync_password_short'));
                  return;
                }
                if (newGroup && first.text != second.text) {
                  setState(() => error = tr('passwords_differ'));
                  return;
                }
                Navigator.pop(ctx, first.text);
              },
              child: Text(tr('ok')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _turnOff(BuildContext context, AppState state) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(tr('sync_off_q')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('sync_off'))),
        ],
      ),
    );
    if (ok == true) await state.disconnectSync();
  }
}
