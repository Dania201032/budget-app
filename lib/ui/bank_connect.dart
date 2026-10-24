import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../import/bunq.dart';
import '../import/fints/fints_banks.dart';
import '../import/fints/fints_client.dart';
import '../import/statement.dart';
import '../l10n/strings.dart';
import '../security/secure_store.dart';
import '../state/app_state.dart';

/// Downloading operations straight from a bank: bunq's API with the user's API key, German banks
/// over FinTS with their online-banking login. The device talks to the bank itself; the PIN is
/// asked each time and never stored, the bunq key is kept in secure storage.

/// Shows a spinner over the screen while [work] runs.
Future<T> _whileBusy<T>(BuildContext context, String text, Future<T> Function() work) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
          const SizedBox(width: 16),
          Expanded(child: Text(text)),
        ]),
      ),
    ),
  );
  try {
    return await work();
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

Future<int?> _askDays(BuildContext context) => showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('bank_period')),
        children: [
          for (final d in const [30, 90, 365])
            SimpleDialogOption(onPressed: () => Navigator.pop(ctx, d), child: Text(tr('bank_days', [d]))),
        ],
      ),
    );

Future<T?> _choose<T>(BuildContext context, String title, List<T> items, String Function(T) label) => showDialog<T>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: [for (final i in items) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, i), child: Text(label(i)))],
      ),
    );

Future<void> _showError(BuildContext context, String message, {List<String> log = const []}) => showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          if (log.isNotEmpty)
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: log.join('\n'))),
              child: Text(tr('bank_copy_log')),
            ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('ok'))),
        ],
      ),
    );

// --- bunq ---

const _bunqKey = 'bunq_state';

Future<Statement?> downloadFromBunq(BuildContext context) async {
  final store = SecureStore.instance;
  final saved = await store.read(_bunqKey);
  var state = saved == null ? null : BunqState.fromJson(jsonDecode(saved) as Map<String, dynamic>);
  if (!context.mounted) return null;
  if (state == null) {
    final key = await _askBunqKey(context);
    if (key == null || key.trim().isEmpty || !context.mounted) return null;
    state = BunqState(key.trim());
  }
  final days = await _askDays(context);
  if (days == null || !context.mounted) return null;
  final client = BunqClient(state);
  try {
    final accounts = await _whileBusy(context, tr('bank_loading'), client.accounts);
    await store.write(_bunqKey, jsonEncode(state.toJson()));
    if (!context.mounted || accounts.isEmpty) return null;
    final account = accounts.length == 1
        ? accounts.single
        : await _choose(context, tr('bank_choose_account'), accounts, (a) => '${a.name} · ${a.iban ?? a.currency}');
    if (account == null || !context.mounted) return null;
    final s = await _whileBusy(context, tr('bank_loading'), () => client.payments(account, DateTime.now().subtract(Duration(days: days))));
    await store.write(_bunqKey, jsonEncode(state.toJson()));
    return s;
  } on BunqError catch (e) {
    // A wrong or revoked key: forget it, so it is asked again next time.
    if (e.status == 400 || e.status == 403) await store.write(_bunqKey, null);
    if (context.mounted) await _showError(context, tr('bunq_failed', [e.message]));
    return null;
  }
}

Future<String?> _askBunqKey(BuildContext context) {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('bunq'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('bunq_key_hint')),
          const SizedBox(height: 12),
          TextField(controller: ctrl, decoration: InputDecoration(labelText: tr('bunq_key')), obscureText: true),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(tr('bank_connect'))),
      ],
    ),
  );
}

// --- FinTS ---

/// Login details kept between uses (never the PIN).
class _FintsLogin {
  String bank;
  String blz;
  String url;
  String user;
  String systemId;
  String? securityFunction;
  String? tanMedium;
  _FintsLogin(this.bank, this.blz, this.url, this.user, {this.systemId = '0', this.securityFunction, this.tanMedium});

  Map<String, Object?> toJson() =>
      {'bank': bank, 'blz': blz, 'url': url, 'user': user, 'system': systemId, 'func': securityFunction, 'medium': tanMedium};

  static _FintsLogin? fromJson(String? s) {
    if (s == null) return null;
    final j = jsonDecode(s) as Map<String, dynamic>;
    return _FintsLogin(j['bank'] as String, j['blz'] as String, j['url'] as String, j['user'] as String,
        systemId: j['system'] as String? ?? '0', securityFunction: j['func'] as String?, tanMedium: j['medium'] as String?);
  }
}

class _FintsDialogs implements FintsUi {
  final BuildContext context;
  _FintsDialogs(this.context);

  @override
  Future<String?> chooseTanMethod(List<FintsTanMethod> methods) async =>
      (await _choose(context, tr('fints_tan_method'), methods, (m) => m.name))?.code;

  @override
  Future<String?> askTanMedium() => _askText(tr('fints_tan_medium'), tr('fints_tan_medium_hint'));

  @override
  Future<String?> askTan(FintsChallenge c) {
    if (c.decoupled) {
      return showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text(tr('fints_confirm_title')),
          content: SingleChildScrollView(
            child: Text([
              if (c.stillWaiting) tr('fints_still_waiting'),
              if (c.text.isNotEmpty) c.text else tr('fints_confirm_text'),
            ].join('\n\n')),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, ''), child: Text(tr('fints_confirmed'))),
          ],
        ),
      );
    }
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(tr('fints_tan')),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (c.image != null) Image.memory(c.image!, width: 220, gaplessPlayback: true),
            if (c.text.isNotEmpty) Text(c.text),
            const SizedBox(height: 12),
            TextField(controller: ctrl, autofocus: true, decoration: InputDecoration(labelText: tr('fints_tan'))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text(tr('ok'))),
        ],
      ),
    );
  }

  Future<String?> _askText(String title, String hint) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(hint),
          TextField(controller: ctrl, autofocus: true),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text(tr('ok'))),
        ],
      ),
    );
  }
}

Future<Statement?> downloadFromFints(BuildContext context) async {
  if (fintsProductId.isEmpty) {
    await _showError(context, tr('fints_not_registered'));
    return null;
  }
  final repo = context.read<AppState>().repo;
  final saved = _FintsLogin.fromJson(await repo.setting('fints_login'));
  if (!context.mounted) return null;
  final form = await showDialog<(_FintsLogin, String)>(context: context, builder: (_) => _FintsForm(saved));
  if (form == null || !context.mounted) return null;
  final (login, pin) = form;
  final days = await _askDays(context);
  if (days == null || !context.mounted) return null;

  final client = FintsClient(
    url: login.url,
    blz: login.blz,
    userId: login.user,
    pin: pin,
    ui: _FintsDialogs(context),
    systemId: login.blz == saved?.blz && login.user == saved?.user ? login.systemId : '0',
    securityFunction: login.blz == saved?.blz && login.user == saved?.user ? login.securityFunction : null,
    tanMedium: login.tanMedium,
  );
  try {
    await _whileBusy(context, tr('bank_loading'), client.open);
    login
      ..systemId = client.systemId
      ..securityFunction = client.securityFunction
      ..tanMedium = client.tanMedium;
    await repo.setSetting('fints_login', jsonEncode(login.toJson()));
    if (!context.mounted) return null;
    final accounts = client.accounts;
    if (accounts.isEmpty) throw FintsError(tr('fints_no_accounts'), client.log);
    final account = accounts.length == 1
        ? accounts.single
        : await _choose(context, tr('bank_choose_account'), accounts, (a) => '${a.name.isEmpty ? a.number : a.name} · ${a.iban ?? a.number}');
    if (account == null || !context.mounted) return null;
    final s = await _whileBusy(context, tr('bank_loading'), () => client.statement(account, DateTime.now().subtract(Duration(days: days))));
    await client.close();
    return Statement(format: 'fints', app: login.bank == 'other' ? null : login.bank, accountRef: s.accountRef, rows: s.rows);
  } on FintsCancelled {
    await client.close();
    return null;
  } on FintsPinWrong catch (e) {
    if (context.mounted) await _showError(context, tr('fints_pin_wrong'), log: e.log);
    return null;
  } on FintsError catch (e) {
    await client.close();
    if (context.mounted) await _showError(context, tr('fints_failed', [e.message]), log: client.log);
    return null;
  }
}

class _FintsForm extends StatefulWidget {
  final _FintsLogin? saved;
  const _FintsForm(this.saved);

  @override
  State<_FintsForm> createState() => _FintsFormState();
}

class _FintsFormState extends State<_FintsForm> {
  late FintsBank _bank = fintsBanks.firstWhere((b) => b.key == widget.saved?.bank, orElse: () => fintsBanks.first);
  late final _blz = TextEditingController(text: widget.saved?.blz ?? _bank.blz ?? '');
  late final _url = TextEditingController(text: widget.saved?.url ?? _bank.url ?? '');
  late final _user = TextEditingController(text: widget.saved?.user ?? '');
  final _pin = TextEditingController();

  bool get _valid =>
      RegExp(r'^\d{8}$').hasMatch(_blz.text.trim()) &&
      _url.text.trim().startsWith('https://') &&
      _user.text.trim().isNotEmpty &&
      _pin.text.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline);
    return AlertDialog(
      title: Text(tr('fints_title')),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          DropdownButtonFormField<FintsBank>(
            initialValue: _bank,
            isExpanded: true,
            decoration: InputDecoration(labelText: tr('fints_bank')),
            items: [
              for (final b in fintsBanks) DropdownMenuItem(value: b, child: Text(b.key == 'other' ? tr('fints_other_bank') : b.name)),
            ],
            onChanged: (b) => setState(() {
              _bank = b!;
              _blz.text = b.blz ?? '';
              _url.text = b.url ?? '';
            }),
          ),
          TextField(
            controller: _blz,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: tr('fints_blz')),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(labelText: tr('fints_url')),
            onChanged: (_) => setState(() {}),
          ),
          if (_bank.url == null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(tr('fints_url_hint'), style: muted)),
          TextField(
            controller: _user,
            decoration: InputDecoration(labelText: tr('fints_user')),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            controller: _pin,
            obscureText: true,
            decoration: InputDecoration(labelText: tr('fints_pin')),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Text(tr('fints_private'), style: muted),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('cancel'))),
        FilledButton(
          onPressed: !_valid
              ? null
              : () => Navigator.pop(context, (
                    _FintsLogin(
                      _bank.key,
                      _blz.text.trim(),
                      _url.text.trim(),
                      _user.text.trim(),
                      systemId: widget.saved?.systemId ?? '0',
                      securityFunction: widget.saved?.securityFunction,
                      tanMedium: widget.saved?.tanMedium,
                    ),
                    _pin.text,
                  )),
          child: Text(tr('bank_connect')),
        ),
      ],
    );
  }
}
