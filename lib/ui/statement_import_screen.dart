import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/repository.dart';
import '../domain/money.dart';
import '../import/read_statement.dart';
import '../import/statement.dart';
import '../import/statement_import.dart';
import '../l10n/strings.dart';
import '../platform.dart';
import '../state/app_state.dart';
import 'bank_connect.dart';
import 'lock_screen.dart';

/// Adds operations from a bank's or payment app's statement file: those the app missed are
/// added, those it already has are recognised (and get the shop's name and category), failed and
/// pending ones are left out.
class StatementImportScreen extends StatefulWidget {
  const StatementImportScreen({super.key});

  @override
  State<StatementImportScreen> createState() => _StatementImportScreenState();
}

class _StatementImportScreenState extends State<StatementImportScreen> {
  String? _fileName;
  Statement? _statement;
  Account? _account;
  StatementPlan? _plan;
  String? _error;
  bool _busy = false;
  bool _showKnown = false;
  bool _showSkipped = false;
  late final Repository _repo;

  @override
  void initState() {
    super.initState();
    _repo = context.read<AppState>().repo;
  }

  Future<void> _pick() async {
    final files = await appLock.whileInSystemScreen(() => FilePicker.pickFiles(type: FileType.any));
    if (files.isEmpty || !mounted) return;
    final f = files.first;
    final bytes = await f.xFile.readAsBytes();
    setState(() {
      _fileName = f.name;
      _statement = null;
      _plan = null;
      _error = null;
    });
    await _read(f.name, bytes, null);
  }

  Future<void> _use(Statement s) async {
    _statement = s;
    _account = await guessStatementAccount(_repo, s);
    await _replan();
  }

  /// Operations downloaded straight from a bank (bunq API, FinTS) go the same way as a file's.
  Future<void> _download(Future<Statement?> Function(BuildContext) fetch) async {
    setState(() {
      _fileName = null;
      _statement = null;
      _plan = null;
      _error = null;
    });
    try {
      final s = await fetch(context);
      if (s == null || !mounted) return;
      setState(() => _busy = true);
      await _use(s);
    } catch (e) {
      _error = tr('bank_failed', [e]);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _read(String name, Uint8List bytes, String? password) async {
    setState(() => _busy = true);
    try {
      final list = await readStatementFile(name, bytes, password: password);
      // A ZIP of several files (Sparkasse: one CAMT per day) is one statement.
      final s = list.length == 1
          ? list.first
          : Statement(
              format: list.first.format,
              app: list.map((s) => s.app).nonNulls.firstOrNull,
              accountRef: list.first.accountRef,
              rows: [for (final s in list) ...s.rows],
            );
      await _use(s);
    } on StatementPasswordNeeded catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      final pw = await _askPassword(wrong: e.wrong);
      if (pw != null && mounted) await _read(name, bytes, pw);
      return;
    } on UnknownStatement catch (e) {
      _error = switch (e.reason) {
        'pdf_desktop' => tr('stmt_pdf_phone'),
        'xls' => tr('stmt_xls'),
        'empty' => tr('stmt_empty'),
        _ => tr('stmt_unknown'),
      };
    } catch (e) {
      _error = tr('read_failed', [e]);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _replan() async {
    final s = _statement;
    final a = _account;
    if (s == null || a == null) {
      _plan = null;
      return;
    }
    _plan = await planStatementImport(_repo, s, a);
  }

  Future<String?> _askPassword({required bool wrong}) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('stmt_password')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(wrong ? tr('stmt_password_wrong') : tr('stmt_password_hint')),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.visiblePassword,
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(tr('ok'))),
        ],
      ),
    );
  }

  Future<void> _apply() async {
    final plan = _plan!;
    setState(() => _busy = true);
    final added = await context.read<AppState>().applyStatement(plan);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('stmt_done', [added, plan.known.length]))));
    Navigator.pop(context);
  }

  String _reason(String? r) => switch (r) {
        'failed' => tr('stmt_r_failed'),
        'pending' => tr('stmt_r_pending'),
        'neutral' => tr('stmt_r_neutral'),
        'deleted' => tr('stmt_r_deleted'),
        'excel' => tr('stmt_r_excel'),
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline);
    final s = _statement;
    final plan = _plan;
    final day = DateFormat.yMMMd(intlLocale);

    Widget row(PlannedRow p, {Widget? leading, String? sub}) {
      final r = p.row;
      final cat = p.categoryId == null ? null : state.categoryById[p.categoryId];
      return ListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        leading: leading,
        title: Text(r.payee ?? r.details ?? '—', maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            r.hasTime ? DateFormat.yMMMd(intlLocale).add_Hm().format(r.time) : day.format(r.time),
            if (cat != null) state.categoryName(cat),
            ?sub,
          ].join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Text(
          formatMoney(r.kind == TxnKind.expense ? -r.amountMinor : r.amountMinor,
              r.currency.isEmpty ? (_account?.currency ?? '') : r.currency,
              signed: true),
          style: theme.textTheme.bodyMedium,
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(tr('stmt_title'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(tr('stmt_explain')),
        const SizedBox(height: 6),
        Text(appIsDesktop ? tr('stmt_formats_desktop') : tr('stmt_formats'), style: muted),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _busy ? null : _pick,
          icon: const Icon(Icons.upload_file_outlined),
          label: Text(_fileName ?? tr('stmt_pick')),
        ),
        const SizedBox(height: 16),
        Text(tr('bank_direct'), style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(tr('bank_direct_sub'), style: muted),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton(onPressed: _busy ? null : () => _download(downloadFromBunq), child: const Text('bunq')),
          OutlinedButton(onPressed: _busy ? null : () => _download(downloadFromFints), child: Text(tr('fints_button'))),
        ]),
        if (_busy) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ),
        if (s != null && !_busy) ...[
          const SizedBox(height: 16),
          Text(
            tr('stmt_found', [
              s.rows.length,
              if (s.from != null) day.format(s.from!) else '',
              if (s.to != null) day.format(s.to!) else '',
            ]),
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            initialValue: _account?.id,
            isExpanded: true,
            decoration: InputDecoration(labelText: tr('stmt_account')),
            items: [
              for (final a in state.accounts)
                DropdownMenuItem(value: a.id, child: Text('${state.accountName(a)} (${a.currency})', overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (id) async {
              _account = state.accounts.where((a) => a.id == id).firstOrNull;
              setState(() => _busy = true);
              await _replan();
              if (mounted) setState(() => _busy = false);
            },
          ),
          if (_account == null)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(tr('stmt_pick_account'), style: muted)),
        ],
        if (plan != null && !_busy) ...[
          const SizedBox(height: 16),
          Text(tr('stmt_summary', [plan.toAdd.length, plan.known.length, plan.skipped.length]), style: theme.textTheme.bodyMedium),
          const SizedBox(height: 8),
          if (plan.toAdd.isNotEmpty) ...[
            Text(tr('stmt_new'), style: theme.textTheme.titleSmall),
            for (final p in plan.toAdd)
              row(p,
                  leading: Checkbox(
                    value: p.include,
                    onChanged: (v) => setState(() => p.include = v ?? false),
                  )),
          ] else
            Text(tr('stmt_nothing_new'), style: muted),
          if (plan.known.isNotEmpty) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => setState(() => _showKnown = !_showKnown),
              child: Text('${tr('stmt_known')} (${plan.known.length})'),
            ),
            if (_showKnown) for (final p in plan.known) row(p),
          ],
          if (plan.skipped.isNotEmpty) ...[
            TextButton(
              onPressed: () => setState(() => _showSkipped = !_showSkipped),
              child: Text('${tr('stmt_skipped')} (${plan.skipped.length})'),
            ),
            if (_showSkipped) for (final p in plan.skipped) row(p, sub: _reason(p.reason)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy || (plan.toAdd.every((p) => !p.include) && plan.known.isEmpty) ? null : _apply,
            child: Text(tr('stmt_add', [plan.toAdd.where((p) => p.include).length])),
          ),
          const SizedBox(height: 8),
          Text(tr('stmt_private'), style: muted),
        ],
      ]),
    );
  }
}
