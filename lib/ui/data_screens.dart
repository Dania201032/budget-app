
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/currencies.dart';
import '../domain/money.dart';
import '../io/export.dart';
import '../io/sheet_import.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'lock_screen.dart';

// --- Export ---

Future<void> showExportSheet(BuildContext context) => showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => const _ExportSheet(),
    );

class _ExportSheet extends StatefulWidget {
  const _ExportSheet();

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  ExportFormat _format = ExportFormat.xlsx;
  bool _allTime = true;
  bool _busy = false;

  Future<void> _export() async {
    final state = context.read<AppState>();
    setState(() => _busy = true);
    try {
      final period = _allTime ? null : state.period;
      final txns = await state.txnsForExport(period);
      final rows = transactionRows(
        txns: txns,
        categoryName: (id) => id == null || state.categoryById[id] == null ? '' : state.categoryName(state.categoryById[id]!),
        accountName: (id) => id == null || state.accountById[id] == null ? '' : state.accountName(state.accountById[id]!),
        baseCurrency: state.baseCurrency,
        toBase: state.toBase,
      );
      final stamp = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final label = period == null ? 'all_$stamp' : period.label().replaceAll(RegExp(r'[^\p{L}\p{N}\-]+', unicode: true), '_');
      await appLock.whileInSystemScreen(() => shareExport(rows: rows, format: _format, fileBaseName: 'Budget_$label'));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('export_failed', [e]))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('export_title'), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          SegmentedButton<ExportFormat>(
            segments: const [
              ButtonSegment(value: ExportFormat.xlsx, label: Text('Excel'), icon: Icon(Icons.table_chart_outlined)),
              ButtonSegment(value: ExportFormat.csv, label: Text('CSV'), icon: Icon(Icons.description_outlined)),
            ],
            selected: {_format},
            onSelectionChanged: (s) => setState(() => _format = s.first),
          ),
          const SizedBox(height: 8),
          RadioGroup<bool>(
            groupValue: _allTime,
            onChanged: (v) => setState(() => _allTime = v ?? true),
            child: Column(children: [
              RadioListTile(value: true, title: Text(tr('all_time'))),
              RadioListTile(value: false, title: Text(tr('period_from_overview', [state.period.label()]))),
            ]),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _export,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.ios_share),
            label: Text(tr('export_send')),
          ),
        ]),
      ),
    );
  }
}

// --- Excel import ---

class SheetImportScreen extends StatefulWidget {
  const SheetImportScreen({super.key});

  @override
  State<SheetImportScreen> createState() => _SheetImportScreenState();
}

class _SheetImportScreenState extends State<SheetImportScreen> {
  SheetImportPlan? _plan;
  String? _fileName;
  String? _error;
  bool _busy = false;
  late String _currency = context.read<AppState>().baseCurrency;

  Future<void> _pick() async {
    final state = context.read<AppState>();
    final files = await appLock.whileInSystemScreen(() => FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx']));
    if (files.isEmpty || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await files.first.xFile.readAsBytes();
      final plan = await planSheetImport(bytes, categories: state.categories, currency: _currency);
      setState(() {
        _plan = plan;
        _fileName = files.first.name;
        if (plan.isEmpty) _error = tr('nothing_found');
      });
    } catch (e) {
      setState(() => _error = tr('read_failed', [e]));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply() async {
    final plan = _plan!;
    setState(() => _busy = true);
    await context.read<AppState>().applyImport(plan);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr('imported', [plan.expenses.length, plan.incomes.length]))));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plan = _plan;
    return Scaffold(
      appBar: AppBar(title: Text(tr('import_excel'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(tr('import_explain')),
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tr('sheet_currency')),
          trailing: Text('${currencySymbol(_currency)}  $_currency'),
          onTap: plan != null
              ? null
              : () async {
                  final code = await Navigator.of(context).push<String>(MaterialPageRoute(
                    builder: (ctx) => Scaffold(
                      appBar: AppBar(title: Text(tr('currency'))),
                      body: ListView(children: [
                        for (final c in currencies)
                          ListTile(title: Text('${c.code} ${c.symbol}'), onTap: () => Navigator.pop(ctx, c.code)),
                      ]),
                    ),
                  ));
                  if (code != null) setState(() => _currency = code);
                },
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _busy ? null : _pick,
          icon: const Icon(Icons.folder_open),
          label: Text(_fileName ?? tr('pick_xlsx')),
        ),
        if (_busy) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ),
        if (plan != null && !plan.isEmpty) ...[
          const SizedBox(height: 16),
          Text(tr('will_import'), style: theme.textTheme.titleMedium),
          for (final e in plan.perSheet.entries)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(e.key),
              subtitle: Text(tr('n_ops', [e.value.$1])),
              trailing: Text(formatMoney(e.value.$2, plan.currency)),
            ),
          if (plan.budgets.isNotEmpty)
            Text(
              tr('month_budgets', [
                plan.budgets.entries.map((e) => '${DateFormat.LLLL(intlLocale).format(e.key)} ${formatMoney(e.value, plan.currency)}').join(', ')
              ]),
              style: theme.textTheme.bodySmall,
            ),
          if (plan.newCategories.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(tr('new_categories', [plan.newCategories.join(', ')]), style: theme.textTheme.bodySmall),
            ),
          const SizedBox(height: 8),
          Text(tr('reimport_note'), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy ? null : _apply, child: Text(tr('import_button'))),
        ],
      ]),
    );
  }
}

// --- Cloud backup ---

class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  bool _busy = false;
  List<Map<String, Object?>> _files = [];

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  /// Google Drive folder while on mobile data: copies wait in Drive's upload queue.
  bool _waitsForWifi = false;

  Future<void> _loadFiles() async {
    final state = context.read<AppState>();
    final uri = state.backupUri;
    if (uri == null) return;
    try {
      final files = await state.backup.listFolder(uri);
      final waits = await state.backup.waitsForWifi(uri);
      if (mounted) {
        setState(() {
          _files = files;
          _waitsForWifi = waits;
        });
      }
    } on PlatformException {
      // Folder no longer accessible: the user can choose it again.
    }
  }

  Future<void> _run(Future<void> Function() action, {String? success}) async {
    setState(() => _busy = true);
    try {
      await action();
      if (success != null && mounted) {
        // Saved, but Drive will only upload it on Wi-Fi: say so instead of a plain "saved".
        final text = success == tr('backup_done') && _waitsForWifi ? tr('backup_queued_wifi') : success;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
      }
    } on PlatformException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('backup_failed', [e.message]))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Password typed twice; only a key derived from it is kept (Android Keystore), never the password.
  Future<void> _setPassword() async {
    final state = context.read<AppState>();
    final first = TextEditingController();
    final second = TextEditingController();
    String? error;
    final p = await showDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setState) => AlertDialog(
          title: Text(tr('backup_password')),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('backup_password_sub'), style: Theme.of(c).textTheme.bodySmall),
            TextField(controller: first, autofocus: true, obscureText: true, decoration: InputDecoration(labelText: tr('backup_password'))),
            TextField(controller: second, obscureText: true, decoration: InputDecoration(labelText: tr('repeat_password'), errorText: error)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('cancel'))),
            FilledButton(
              onPressed: () {
                if (first.text.length < 4) {
                  setState(() => error = tr('password_too_short'));
                } else if (first.text != second.text) {
                  setState(() => error = tr('passwords_differ'));
                } else {
                  Navigator.pop(c, first.text);
                }
              },
              child: Text(tr('save')),
            ),
          ],
        ),
      ),
    );
    if (p == null) return;
    await state.setBackupPassword(p);
    // Older backups were made with the previous key: make a fresh one right away.
    await _run(() async {
      await state.backupNow();
      await _loadFiles();
    }, success: tr('backup_done'));
  }

  Future<void> _checkPassword() async {
    final state = context.read<AppState>();
    final controller = TextEditingController();
    final p = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('check_password')),
        content: TextField(controller: controller, autofocus: true, obscureText: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, controller.text), child: Text(tr('ok'))),
        ],
      ),
    );
    if (p == null || !mounted) return;
    final ok = await state.checkBackupPassword(p);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(ok ? tr('password_correct') : tr('password_wrong'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final configured = state.backupConfigured;
    String fmt(DateTime d) => DateFormat.yMMMd(intlLocale).add_Hm().format(d);

    return Scaffold(
      appBar: AppBar(title: Text(tr('backup'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(tr('backup_explain')),
        const SizedBox(height: 16),
        if (configured) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_outlined),
            title: Text(tr('backup_folder', [state.backupFolder ?? ''])),
            subtitle: Text(tr('backup_last', [state.backupLast == null ? tr('never') : fmt(state.backupLast!)])),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(state.backupEncrypted ? Icons.lock_outline : Icons.lock_open),
            title: Text(state.backupEncrypted ? tr('password_set') : tr('password_none')),
            subtitle: Text(tr('password_where'), style: theme.textTheme.bodySmall),
          ),
          Wrap(spacing: 8, children: [
            TextButton(onPressed: _setPassword, child: Text(state.backupEncrypted ? tr('change_password') : tr('set_password'))),
            if (state.backupEncrypted) TextButton(onPressed: _checkPassword, child: Text(tr('check_password'))),
          ]),
          if (_waitsForWifi)
            Card(
              color: theme.colorScheme.errorContainer,
              child: ListTile(
                leading: Icon(Icons.wifi_off, color: theme.colorScheme.onErrorContainer),
                title: Text(tr('drive_wifi_title'), style: TextStyle(color: theme.colorScheme.onErrorContainer)),
                subtitle: Text(tr('drive_wifi_body'), style: TextStyle(color: theme.colorScheme.onErrorContainer)),
              ),
            ),
          Text(tr('cloud_upload_note'), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy
                ? null
                : () => _run(() async {
                      await state.backupNow();
                      await _loadFiles();
                    }, success: tr('backup_done')),
            icon: const Icon(Icons.cloud_upload_outlined),
            label: Text(tr('backup_now')),
          ),
        ],
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => _run(() async {
                    final path = await state.backup.packToCache(await state.backup.serialize());
                    await appLock.whileInSystemScreen(() => SharePlus.instance.share(ShareParams(files: [XFile(path)], subject: tr('backup'))));
                  }),
          icon: const Icon(Icons.share_outlined),
          label: Text(tr('send_backup')),
        ),
        Text(tr('send_backup_sub'), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () async {
                  final ok = await appLock.whileInSystemScreen(state.chooseBackupFolder);
                  if (!ok || !context.mounted) return;
                  if (!state.backupEncrypted) await _setPassword();
                  await _run(() async {
                    await state.backupNow();
                    await _loadFiles();
                  }, success: tr('backup_done'));
                },
          icon: const Icon(Icons.create_new_folder_outlined),
          label: Text(configured ? tr('change_folder') : tr('choose_folder')),
        ),
        const Divider(height: 32),
        Text(tr('restore'), style: theme.textTheme.titleMedium),
        for (final f in _files)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.restore),
            title: Text(f['name'] as String),
            subtitle: Text(fmt(DateTime.fromMillisecondsSinceEpoch((f['modified'] as num).toInt()))),
            onTap: _busy
                ? null
                : () async {
                    final bytes = await state.backup.readFromFolder(state.backupUri!, f['name'] as String);
                    if (context.mounted) await restoreBackupBytes(context, bytes);
                  },
          ),
        TextButton.icon(
          onPressed: _busy ? null : () => restoreFromBackupFile(context),
          icon: const Icon(Icons.file_open_outlined),
          label: Text(tr('restore')),
        ),
      ]),
    );
  }
}

/// Pick a backup file anywhere (cloud app, Downloads…) and restore it.
Future<void> restoreFromBackupFile(BuildContext context) async {
  final state = context.read<AppState>();
  final bytes = await appLock.whileInSystemScreen(state.backup.pickFile);
  if (bytes == null || !context.mounted) return;
  await restoreBackupBytes(context, bytes);
}

Future<void> restoreBackupBytes(BuildContext context, Uint8List bytes) async {
  final state = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  try {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('restore')),
        content: Text(tr('restore_confirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('restore'))),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    String? password;
    if (await state.backup.isEncrypted(bytes)) {
      if (!context.mounted) return;
      final controller = TextEditingController();
      password = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(tr('enter_password')),
          content: TextField(controller: controller, autofocus: true, obscureText: true),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(c, controller.text), child: Text(tr('ok'))),
          ],
        ),
      );
      if (password == null) return;
    }
    final Uint8List payload;
    try {
      payload = await state.backup.unpack(bytes, password);
    } on PlatformException {
      messenger.showSnackBar(SnackBar(content: Text(tr('wrong_password'))));
      return;
    }
    await state.restoreFrom(payload);
    messenger.showSnackBar(SnackBar(content: Text(tr('restore_done'))));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(tr('restore_failed', [e]))));
  }
}
