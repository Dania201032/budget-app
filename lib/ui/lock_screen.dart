import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../security/app_lock.dart';
import 'ledger.dart';

/// The app lock instance (loaded in main()).
final appLock = AppLock();

/// Covers the whole app with [LockScreen] while locked; the app underneath keeps its state.
class LockGate extends StatefulWidget {
  final Widget child;
  const LockGate({super.key, required this.child});

  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    appLock.addListener(_changed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    appLock.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) appLock.onPaused();
    if (s == AppLifecycleState.resumed) appLock.onResumed();
  }

  @override
  Widget build(BuildContext context) => Stack(children: [
        Offstage(offstage: appLock.locked, child: widget.child),
        if (appLock.locked) const Positioned.fill(child: LockScreen()),
      ]);
}

/// PIN pad, with the fingerprint / face prompt offered right away when it's on.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String _pin = '';
  bool _wrong = false;
  int _failures = 0;
  DateTime? _waitUntil;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bio());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _bio() async {
    if (appLock.biometrics) await appLock.unlockWithBiometrics(tr('lock_reason'));
  }

  bool get _waiting => _waitUntil != null && DateTime.now().isBefore(_waitUntil!);

  Future<void> _key(String k) async {
    if (_waiting) return;
    HapticFeedback.selectionClick();
    if (k == '⌫') {
      setState(() => _pin = _pin.isEmpty ? '' : _pin.substring(0, _pin.length - 1));
      return;
    }
    if (_pin.length >= appLock.pinLength) return;
    setState(() {
      _pin += k;
      _wrong = false;
    });
    if (_pin.length < appLock.pinLength) return;
    if (await appLock.checkPin(_pin)) return;
    _failures++;
    setState(() {
      _wrong = true;
      _pin = '';
      // After 5 wrong PINs, wait 30 seconds before each next try.
      if (_failures >= 5) {
        _waitUntil = DateTime.now().add(const Duration(seconds: 30));
        _tick?.cancel();
        _tick = Timer.periodic(const Duration(seconds: 1), (t) {
          if (!_waiting) t.cancel();
          if (mounted) setState(() {});
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = Ledger.inkOf(context);
    Widget key(String k, {Widget? child, VoidCallback? onTap}) => Expanded(
          child: InkWell(
            onTap: onTap ?? () => _key(k),
            child: SizedBox(height: 64, child: Center(child: child ?? Text(k, style: mono(size: 26, weight: FontWeight.w400)))),
          ),
        );
    final wait = _waiting ? _waitUntil!.difference(DateTime.now()).inSeconds + 1 : 0;
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: Column(children: [
          const Spacer(),
          Icon(Icons.lock_outline, size: 40, color: ink),
          const SizedBox(height: 12),
          Text(tr('lock_enter_pin'), style: theme.textTheme.titleMedium),
          const SizedBox(height: 20),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < appLock.pinLength; i++)
              Container(
                width: 14,
                height: 14,
                margin: const EdgeInsets.symmetric(horizontal: 7),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < _pin.length ? ink : null,
                  border: Border.all(color: ink),
                ),
              ),
          ]),
          const SizedBox(height: 12),
          SizedBox(
            height: 20,
            child: Text(
              _waiting ? tr('lock_wait', [wait]) : (_wrong ? tr('lock_wrong') : ''),
              style: theme.textTheme.bodySmall?.copyWith(color: Ledger.badOf(context)),
            ),
          ),
          const Spacer(),
          for (final row in const [['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9']])
            Row(children: [for (final k in row) key(k)]),
          Row(children: [
            appLock.biometrics
                ? key('bio', child: Icon(Icons.fingerprint, size: 30, color: ink), onTap: _bio)
                : const Expanded(child: SizedBox()),
            key('0'),
            key('⌫', child: Icon(Icons.backspace_outlined, color: ink)),
          ]),
          const SizedBox(height: 16),
        ]),
      ),
    );
  }
}

/// Settings → App lock.
/// Asks a new PIN twice; null if cancelled.
Future<String?> askNewPin(BuildContext context) async {
  final first = await askPin(context, tr('lock_new_pin'));
  if (first == null || !context.mounted) return null;
  final second = await askPin(context, tr('lock_repeat_pin'));
  if (second == null || !context.mounted) return null;
  if (first != second) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('lock_pins_differ'))));
    return null;
  }
  return first;
}

Future<String?> askPin(BuildContext context, String title) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        obscureText: true,
        maxLength: 6,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(helperText: tr('lock_pin_rule')),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
        FilledButton(
          onPressed: () {
            if (c.text.length >= 4) Navigator.pop(ctx, c.text);
          },
          child: Text(tr('ok')),
        ),
      ],
    ),
  );
}

class LockSettingsScreen extends StatefulWidget {
  const LockSettingsScreen({super.key});

  @override
  State<LockSettingsScreen> createState() => _LockSettingsScreenState();
}

class _LockSettingsScreenState extends State<LockSettingsScreen> {
  bool _bioAvailable = false;

  @override
  void initState() {
    super.initState();
    appLock.addListener(_changed);
    appLock.biometricsAvailable().then((v) {
      if (mounted) setState(() => _bioAvailable = v);
    });
  }

  @override
  void dispose() {
    appLock.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});


  Future<void> _toggle(bool on) async {
    if (on) {
      final pin = await askNewPin(context);
      if (pin != null) await appLock.setPin(pin);
      return;
    }
    // Turning it off needs the current PIN.
    final pin = await askPin(context, tr('lock_current_pin'));
    if (pin == null) return;
    if (await appLock.checkPin(pin)) {
      await appLock.disable();
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('lock_wrong'))));
    }
  }

  Future<void> _changePin() async {
    final current = await askPin(context, tr('lock_current_pin'));
    if (current == null) return;
    if (!await appLock.checkPin(current)) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('lock_wrong'))));
      return;
    }
    if (!mounted) return;
    final pin = await askNewPin(context);
    if (pin != null) await appLock.setPin(pin);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('lock'))),
      body: ListView(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(tr('lock_hint'), style: theme.textTheme.bodySmall?.copyWith(color: Ledger.mutedOf(context))),
        ),
        SwitchListTile(value: appLock.enabled, onChanged: _toggle, title: Text(tr('lock_on'))),
        if (appLock.enabled) ...[
          if (_bioAvailable)
            SwitchListTile(
              value: appLock.biometrics,
              onChanged: appLock.setBiometrics,
              title: Text(tr('lock_bio')),
            ),
          ListTile(title: Text(tr('lock_change_pin')), onTap: _changePin),
          LedgerSection(tr('lock_after')),
          RadioGroup<int>(
            groupValue: appLock.lockAfter.inSeconds,
            onChanged: (v) => appLock.setLockAfter(Duration(seconds: v ?? 0)),
            child: Column(children: [
              for (final s in const [0, 60, 300])
                RadioListTile<int>(value: s, title: Text(tr('lock_after_$s'))),
            ]),
          ),
        ],
      ]),
    );
  }
}
