import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../domain/currencies.dart';
import '../domain/money.dart';
import '../household/household.dart';
import '../household/household_flow.dart';
import '../l10n/strings.dart';
import '../platform.dart';
import '../premium/premium.dart';
import '../state/app_state.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_folder.dart';
import '../sync/sync_service.dart';
import 'home_screen.dart' show editBudgetDialog;
import 'ledger.dart';
import 'lock_screen.dart';
import 'plus_screen.dart';
import 'sync_progress.dart';
import 'widgets.dart';

/// Settings → Shared budget: setting one up (the four questions), joining one, and once in it,
/// the people, their limits, whose each account is and who may see it.
class HouseholdScreen extends StatelessWidget {
  const HouseholdScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: Ledger.mutedOf(context));
    void push(Widget w) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));

    if (!state.householdOn) {
      return Scaffold(
        appBar: AppBar(title: Text(tr('hh_title'))),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Text(tr('hh_intro')),
          const SizedBox(height: 8),
          Text(tr('hh_intro_sub'), style: muted),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () async {
              if (await requirePlus(context, PlusFeature.household)) push(const HouseholdSetupScreen());
            },
            child: Text(tr('hh_create')),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () async {
              if (await requirePlus(context, PlusFeature.household)) push(const HouseholdJoinScreen());
            },
            child: Text(tr('hh_join')),
          ),
          const SizedBox(height: 16),
          Text(tr('hh_join_sub'), style: muted),
        ]),
      );
    }

    final config = state.household!;
    final me = state.me;
    String ownerName(String? owner) {
      if (owner == null) return tr('hh_common');
      final p = state.personOf(owner);
      return p == null ? '—' : (owner == me ? tr('hh_me', [p.name]) : p.name);
    }

    return Scaffold(
      appBar: AppBar(title: Text(tr('hh_title'))),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        LedgerSection(tr('hh_people')),
        for (final p in state.people)
          LedgerTile(
            p.uid == me ? tr('hh_me', [p.name]) : p.name,
            trailing: PersonBadge(p, size: 22),
            onTap: () => _rename(context, state, p),
          ),
        if (config.personalLimits) ...[
          LedgerSection(tr('hh_limits')),
          LedgerTile(
            tr('hh_common_limit'),
            value: state.commonBudget(DateTime.now()) == 0 ? tr('hh_not_set') : formatMoney(state.commonBudget(DateTime.now()), state.baseCurrency),
            onTap: () => editBudgetDialog(context),
          ),
          for (final p in state.people)
            LedgerTile(
              tr('hh_own_limit', [p.name]),
              value: state.personalBudget(p.uid) == 0 ? tr('hh_not_set') : formatMoney(state.personalBudget(p.uid), state.baseCurrency),
              onTap: () async {
                final v = await askAmount(
                  context,
                  title: tr('hh_own_limit', [p.name]),
                  subtitle: tr('hh_own_limit_sub'),
                  initial: state.personalBudget(p.uid) == 0 ? '' : (state.personalBudget(p.uid) / 100).toStringAsFixed(0),
                  suffix: currencySymbol(state.baseCurrency),
                );
                if (v != null) await state.setPersonalBudget(p.uid, v);
              },
            ),
        ],
        LedgerSection(tr('hh_accounts')),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text(tr(config.hiddenAccounts ? 'hh_accounts_sub_hidden' : 'hh_accounts_sub'), style: muted),
        ),
        for (final a in state.accounts)
          LedgerTile(
            state.accountName(a),
            hint: a.hidden ? tr('hh_hidden_mark') : null,
            value: ownerName(a.owner),
            onTap: () => _accountSheet(context, state, a),
          ),
        LedgerSection(tr('hh_invite')),
        LedgerTile(tr('hh_invite_how'), onTap: () => showInvite(context, config)),
        LedgerTile(tr('hh_answers'), hint: _answers(config)),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: TextButton(onPressed: () => _leave(context, state), child: Text(tr('hh_leave'))),
        ),
      ]),
    );
  }

  static String _answers(HouseholdConfig c) => [
        tr(c.hiddenAccounts ? 'hh_q1_hidden' : 'hh_q1_all'),
        tr(c.personalLimits ? 'hh_q2_own' : 'hh_q2_one'),
        tr('hh_dev_${c.partnerDevice}'),
        tr('hh_cloud_${c.cloud}'),
      ].join(' · ');

  Future<void> _rename(BuildContext context, AppState state, Person p) async {
    final name = await askText(context, title: tr('hh_name'), initial: p.name);
    if (name == null || name.trim().isEmpty) return;
    await state.repo.renamePerson(p.uid, name);
    await state.reloadHousehold();
  }

  Future<void> _accountSheet(BuildContext context, AppState state, Account a) {
    final config = state.household!;
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: StatefulBuilder(builder: (sheet, setSheet) {
          final fresh = state.accountById[a.id] ?? a;
          return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(tr('hh_whose', [state.accountName(fresh)]), style: Theme.of(sheet).textTheme.titleMedium),
            ),
            RadioGroup<String>(
              groupValue: fresh.owner ?? '',
              onChanged: (v) async {
                await state.repo.setAccountOwner(fresh.id, v == null || v.isEmpty ? null : v);
                await state.reloadHousehold();
                setSheet(() {});
              },
              child: Column(children: [
                RadioListTile<String>(value: '', title: Text(tr('hh_common')), subtitle: Text(tr('hh_common_sub'))),
                for (final p in state.people)
                  RadioListTile<String>(value: p.uid, title: Text(p.uid == state.me ? tr('hh_me', [p.name]) : p.name)),
              ]),
            ),
            if (config.hiddenAccounts && fresh.owner != null && fresh.owner == state.me)
              SwitchListTile(
                value: fresh.hidden,
                title: Text(tr('hh_hide')),
                subtitle: Text(tr('hh_hide_sub')),
                onChanged: (v) async {
                  await state.repo.setAccountHidden(fresh.id, v);
                  await state.reloadHousehold();
                  setSheet(() {});
                },
              ),
            const SizedBox(height: 8),
          ]);
        }),
      ),
    );
  }

  Future<void> _leave(BuildContext context, AppState state) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(tr('hh_leave_q')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('hh_leave'))),
        ],
      ),
    );
    if (ok == true) await leaveHousehold(state);
  }
}

Future<String?> askText(BuildContext context, {required String title, String? initial, String? hint, bool obscure = false}) {
  final ctrl = TextEditingController(text: initial ?? '');
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (hint != null) Text(hint, style: Theme.of(ctx).textTheme.bodySmall),
        TextField(controller: ctrl, autofocus: true, obscureText: obscure),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(tr('ok'))),
      ],
    ),
  );
}

/// How to bring the second person in, for their device and the cloud chosen.
Future<void> showInvite(BuildContext context, HouseholdConfig c) => showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('hh_invite_how')),
        content: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('hh_step_share'), style: Theme.of(ctx).textTheme.titleSmall),
            Text(tr('hh_share_${c.cloud}')),
            const SizedBox(height: 12),
            Text(tr('hh_step_app'), style: Theme.of(ctx).textTheme.titleSmall),
            Text(tr('hh_app_${c.partnerDevice}')),
            const SizedBox(height: 12),
            Text(tr('hh_step_join'), style: Theme.of(ctx).textTheme.titleSmall),
            Text(tr('hh_join_steps')),
          ]),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('ok')))],
      ),
    );

/// The folder chooser of the phone (Android's) or of the computer.
Future<(SyncFolder, String, String)?> _pickFolder() async {
  if (appIsDesktop) {
    final path = await appLock.whileInSystemScreen(() => FilePicker.getDirectoryPath(dialogTitle: tr('sync_choose_folder')));
    return path == null ? null : (IoSyncFolder(path), 'io', path);
  }
  final picked = await appLock.whileInSystemScreen(SafSyncFolder.pick);
  return picked == null ? null : (SafSyncFolder(picked.$1, picked.$2), 'saf', picked.$1);
}

/// [sync]: the work connects sync — its steps are shown instead of a bare spinner.
Future<T?> _working<T>(BuildContext context, Future<T> Function() work, {SyncService? sync}) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: sync != null
            ? SyncProgressView(sync)
            : Row(children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 20),
                Expanded(child: Text(tr('sync_working'))),
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

/// A step of a wizard: a question with its answers, or a form.
class _Step extends StatelessWidget {
  final String title;
  final String? sub;
  final List<Widget> children;
  const _Step(this.title, {this.sub, required this.children});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
      Text(title, style: theme.textTheme.titleLarge),
      if (sub != null) ...[
        const SizedBox(height: 6),
        Text(sub!, style: theme.textTheme.bodyMedium?.copyWith(color: Ledger.mutedOf(context))),
      ],
      const SizedBox(height: 12),
      ...children,
    ]);
  }
}

Widget _choice<T>(T value, T group, ValueChanged<T> onChanged, String title, [String? sub]) => RadioGroup<T>(
      groupValue: group,
      onChanged: (v) => onChanged(v as T),
      child: RadioListTile<T>(value: value, title: Text(title), subtitle: sub == null ? null : Text(sub), contentPadding: EdgeInsets.zero),
    );

// --- Setting one up ---

class HouseholdSetupScreen extends StatefulWidget {
  const HouseholdSetupScreen({super.key});
  @override
  State<HouseholdSetupScreen> createState() => _HouseholdSetupScreenState();
}

class _HouseholdSetupScreenState extends State<HouseholdSetupScreen> {
  int _step = 0;
  bool _hidden = false;
  bool _personal = false;
  String _device = 'android';
  String _cloud = 'gdrive';
  final _myName = TextEditingController();
  final _partnerName = TextEditingController();
  final _owners = <int, String?>{};
  final _hiddenIds = <int>{};
  final _pw1 = TextEditingController();
  final _pw2 = TextEditingController();
  String? _error;
  bool _done = false;

  static const _me = 'me';

  @override
  void initState() {
    super.initState();
    // Each phone records its owner's payments: by default the accounts are mine.
    for (final a in context.read<AppState>().accounts) {
      _owners[a.id] = _me;
    }
  }

  int get _last => 7;

  bool get _canNext => switch (_step) {
        4 => _myName.text.trim().isNotEmpty,
        6 => _pw1.text.isEmpty || (_pw1.text.length >= 6 && _pw1.text == _pw2.text),
        _ => true,
      };

  void _next() {
    setState(() {
      _error = null;
      _step++;
      if (_step == 6 && !_hidden) _step++; // the personal password is for hidden accounts only
    });
  }

  void _back() {
    if (_step == 0 || _done) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _step--;
      if (_step == 6 && !_hidden) _step--;
    });
  }

  Future<void> _create() async {
    final state = context.read<AppState>();
    final f = await _pickFolder();
    if (f == null || !mounted) return;
    final (folder, kind, location) = f;
    if (await SyncService.hasGroup(folder)) {
      setState(() => _error = tr('hh_folder_used'));
      return;
    }
    if (!mounted) return;
    final password = await askNewGroupPassword(context);
    if (password == null || !mounted) return;
    try {
      await _working(context, () async {
        await foundHousehold(
          state,
          config: HouseholdConfig(hiddenAccounts: _hidden, personalLimits: _personal, partnerDevice: _device, cloud: _cloud),
          myName: _myName.text,
          partnerName: _partnerName.text,
          owners: _owners,
          hidden: _hidden ? _hiddenIds : const {},
          personalPassword: _hidden && _pw1.text.isNotEmpty ? _pw1.text : null,
          folder: folder,
          password: password,
          kind: kind,
          location: location,
        );
        await state.syncNow();
      }, sync: state.sync);
      if (mounted) setState(() => _done = true);
    } on FolderInUse {
      setState(() => _error = tr('hh_folder_used'));
    } catch (e) {
      setState(() => _error = tr('sync_error', ['$e']));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final partner = _partnerName.text.trim().isEmpty ? tr('hh_partner') : _partnerName.text.trim();
    final Widget body;
    if (_done) {
      body = _Step(tr('hh_done'), sub: tr('hh_done_sub'), children: [
        Text(tr('hh_step_share'), style: Theme.of(context).textTheme.titleSmall),
        Text(tr('hh_share_$_cloud')),
        const SizedBox(height: 12),
        Text(tr('hh_step_app'), style: Theme.of(context).textTheme.titleSmall),
        Text(tr('hh_app_$_device')),
        const SizedBox(height: 12),
        Text(tr('hh_step_join'), style: Theme.of(context).textTheme.titleSmall),
        Text(tr('hh_join_steps')),
        const SizedBox(height: 12),
        Text(tr('hh_tell_password'), style: Theme.of(context).textTheme.bodySmall),
      ]);
    } else {
      body = switch (_step) {
        0 => _Step(tr('hh_q1'), children: [
            _choice(false, _hidden, (v) => setState(() => _hidden = v), tr('hh_q1_all'), tr('hh_q1_all_sub')),
            _choice(true, _hidden, (v) => setState(() => _hidden = v), tr('hh_q1_hidden'), tr('hh_q1_hidden_sub')),
          ]),
        1 => _Step(tr('hh_q2'), children: [
            _choice(false, _personal, (v) => setState(() => _personal = v), tr('hh_q2_one'), tr('hh_q2_one_sub')),
            _choice(true, _personal, (v) => setState(() => _personal = v), tr('hh_q2_own'), tr('hh_q2_own_sub')),
          ]),
        2 => _Step(tr('hh_q3'), children: [
            for (final d in const ['android', 'iphone', 'computer'])
              _choice(d, _device, (v) => setState(() => _device = v), tr('hh_dev_$d'), tr('hh_dev_${d}_sub')),
          ]),
        3 => _Step(tr('hh_q4'), sub: tr('hh_q4_sub'), children: [
            for (final c in const ['gdrive', 'onedrive', 'yandex', 'jianguoyun', 'other'])
              _choice(c, _cloud, (v) => setState(() => _cloud = v), tr('hh_cloud_$c'), tr('hh_cloud_${c}_sub')),
          ]),
        4 => _Step(tr('hh_names'), children: [
            TextField(
              controller: _myName,
              decoration: InputDecoration(labelText: tr('hh_my_name')),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              controller: _partnerName,
              decoration: InputDecoration(labelText: tr('hh_partner_name'), helperText: tr('hh_partner_name_sub'), helperMaxLines: 3),
              onChanged: (_) => setState(() {}),
            ),
          ]),
        5 => _Step(tr('hh_accounts'), sub: tr(_hidden ? 'hh_setup_accounts_sub_hidden' : 'hh_setup_accounts_sub'), children: [
            for (final a in state.accounts) ...[
              const SizedBox(height: 8),
              Text(state.accountName(a), style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: _me, label: Text(tr('hh_mine'), overflow: TextOverflow.ellipsis)),
                  ButtonSegment(value: '', label: Text(tr('hh_common'), overflow: TextOverflow.ellipsis)),
                  ButtonSegment(value: 'partner', label: Text(partner, overflow: TextOverflow.ellipsis)),
                ],
                selected: {_owners[a.id] ?? ''},
                onSelectionChanged: (s) => setState(() {
                  final v = s.first;
                  _owners[a.id] = v.isEmpty ? null : v;
                  if (v != _me) _hiddenIds.remove(a.id);
                }),
              ),
              if (_hidden && _owners[a.id] == _me)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _hiddenIds.contains(a.id),
                  title: Text(tr('hh_hide')),
                  onChanged: (v) => setState(() => v == true ? _hiddenIds.add(a.id) : _hiddenIds.remove(a.id)),
                ),
            ],
          ]),
        6 => _Step(tr('hh_personal_pw'), sub: tr('hh_personal_pw_sub'), children: [
            TextField(controller: _pw1, obscureText: true, decoration: InputDecoration(labelText: tr('hh_personal_pw')), onChanged: (_) => setState(() {})),
            TextField(
              controller: _pw2,
              obscureText: true,
              decoration: InputDecoration(
                labelText: tr('repeat_password'),
                errorText: _pw1.text.isNotEmpty && _pw1.text.length < 6
                    ? tr('sync_password_short')
                    : (_pw2.text.isNotEmpty && _pw1.text != _pw2.text ? tr('passwords_differ') : null),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ]),
        _ => _Step(tr('hh_folder'), sub: tr('hh_folder_sub'), children: [
            Text(tr('hh_folder_$_cloud')),
            const SizedBox(height: 16),
            FilledButton.icon(icon: const Icon(Icons.folder_open), label: Text(tr('sync_choose_folder')), onPressed: _create),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ]),
      };
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr('hh_create'))),
      body: SafeArea(
        child: Column(children: [
          if (!_done) LinearProgressIndicator(value: (_step + 1) / (_last + 1)),
          Expanded(child: body),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(children: [
              TextButton(onPressed: _back, child: Text(_done ? tr('done') : tr('hh_back'))),
              const Spacer(),
              if (!_done && _step < _last)
                FilledButton(onPressed: _canNext ? _next : null, child: Text(_step == 6 && _pw1.text.isEmpty ? tr('skip') : tr('next'))),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// The shared budget's password, twice (a new folder).
Future<String?> askNewGroupPassword(BuildContext context) {
  final a = TextEditingController();
  final b = TextEditingController();
  String? error;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(tr('hh_group_pw')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(tr('hh_group_pw_sub'), style: Theme.of(ctx).textTheme.bodySmall),
          TextField(controller: a, obscureText: true, autofocus: true, decoration: InputDecoration(labelText: tr('sync_password_enter'))),
          TextField(controller: b, obscureText: true, decoration: InputDecoration(labelText: tr('repeat_password'), errorText: error)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
          FilledButton(
            onPressed: () {
              if (a.text.length < 6) return setState(() => error = tr('sync_password_short'));
              if (a.text != b.text) return setState(() => error = tr('passwords_differ'));
              Navigator.pop(ctx, a.text);
            },
            child: Text(tr('ok')),
          ),
        ],
      ),
    ),
  );
}

// --- Joining one ---

class HouseholdJoinScreen extends StatefulWidget {
  const HouseholdJoinScreen({super.key});
  @override
  State<HouseholdJoinScreen> createState() => _HouseholdJoinScreenState();
}

class _HouseholdJoinScreenState extends State<HouseholdJoinScreen> {
  int _step = 0;
  (SyncFolder, String, String)? _folder;
  String? _password;
  HouseholdInvite? _invite;
  String? _person; // null: a new person
  final _name = TextEditingController();
  bool _hasOwn = false;
  bool _keepMine = true;
  bool _personHasKey = false;
  final _pw1 = TextEditingController();
  final _pw2 = TextEditingController();
  String? _error;
  bool _done = false;

  Future<void> _open() async {
    final f = await _pickFolder();
    if (f == null || !mounted) return;
    final password = await askText(context, title: tr('hh_group_pw'), hint: tr('hh_group_pw_enter'), obscure: true);
    if (password == null || password.isEmpty || !mounted) return;
    final state = context.read<AppState>();
    final repo = state.repo;
    try {
      state.sync.beginConnect();
      final invite = await _working(context, () => readInvite(f.$1, password, sync: state.sync), sync: state.sync)
          .whenComplete(state.sync.endConnect);
      if (invite == null || !mounted) return;
      if (invite.isPlainSync) {
        setState(() => _error = tr('hh_not_household'));
        return;
      }
      _hasOwn = await repo.hasTransactions();
      setState(() {
        _folder = f;
        _password = password;
        _invite = invite;
        _person = null;
        _error = null;
        _step = 1;
      });
    } on WrongSyncPassword {
      setState(() => _error = tr('sync_wrong_password'));
    } catch (e) {
      setState(() => _error = tr('sync_error', ['$e']));
    }
  }

  Future<void> _afterWho() async {
    final person = _person;
    _personHasKey = person != null && await SyncService.hasPersonKey(_folder!.$1, person);
    // My other device: its records are mine already, the budget's are taken as they are.
    _keepMine = person == null;
    setState(() {
      _step = _hasOwn ? 2 : 3;
      if (_step == 3 && !(_invite!.config?.hiddenAccounts ?? false)) _step = 4;
    });
  }

  Future<void> _join() async {
    final state = context.read<AppState>();
    final (folder, kind, location) = _folder!;
    try {
      await _working(context, () => joinHousehold(
            state,
            person: _person,
            newName: _person == null ? _name.text.trim() : null,
            keepMine: _keepMine,
            personalPassword: _pw1.text.isEmpty ? null : _pw1.text,
            folder: folder,
            password: _password!,
            kind: kind,
            location: location,
          ), sync: state.sync);
      if (mounted) setState(() => _done = true);
    } on WrongSyncPassword {
      setState(() => _error = tr('hh_personal_pw_wrong'));
    } catch (e) {
      setState(() => _error = tr('sync_error', ['$e']));
    }
  }

  @override
  Widget build(BuildContext context) {
    final invite = _invite;
    final hiddenOn = invite?.config?.hiddenAccounts ?? false;
    final Widget body;
    if (_done) {
      body = _Step(tr('hh_joined'), sub: tr('hh_joined_sub'), children: const []);
    } else {
      body = switch (_step) {
        0 => _Step(tr('hh_join'), sub: tr('hh_join_find'), children: [
            FilledButton.icon(icon: const Icon(Icons.folder_open), label: Text(tr('sync_choose_folder')), onPressed: _open),
          ]),
        1 => _Step(tr('hh_who'), children: [
            for (final e in invite!.people.entries)
              _choice<String?>(e.key, _person, (v) => setState(() => _person = v), e.value, tr('hh_who_existing')),
            _choice<String?>(null, _person, (v) => setState(() => _person = v), tr('hh_who_new')),
            if (_person == null)
              TextField(controller: _name, decoration: InputDecoration(labelText: tr('hh_my_name')), onChanged: (_) => setState(() {})),
          ]),
        2 => _Step(tr('hh_own_data'), sub: tr('hh_own_data_sub'), children: [
            _choice(true, _keepMine, (v) => setState(() => _keepMine = v), tr('hh_keep_mine'), tr('hh_keep_mine_sub')),
            _choice(false, _keepMine, (v) => setState(() => _keepMine = v), tr('hh_start_fresh'), tr('hh_start_fresh_sub')),
          ]),
        3 => _Step(tr('hh_personal_pw'), sub: tr(_personHasKey ? 'hh_personal_pw_enter' : 'hh_personal_pw_sub'), children: [
            TextField(controller: _pw1, obscureText: true, decoration: InputDecoration(labelText: tr('hh_personal_pw')), onChanged: (_) => setState(() {})),
            if (!_personHasKey)
              TextField(
                controller: _pw2,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: tr('repeat_password'),
                  errorText: _pw2.text.isNotEmpty && _pw1.text != _pw2.text ? tr('passwords_differ') : null,
                ),
                onChanged: (_) => setState(() {}),
              ),
          ]),
        _ => _Step(tr('hh_ready_join'), sub: tr(_keepMine && _hasOwn ? 'hh_ready_merge' : 'hh_ready_take'), children: [
            FilledButton(onPressed: _join, child: Text(tr('hh_join'))),
          ]),
      };
    }
    final canNext = switch (_step) {
      1 => _person != null || _name.text.trim().isNotEmpty,
      3 => _pw1.text.isEmpty || _personHasKey || (_pw1.text.length >= 6 && _pw1.text == _pw2.text),
      _ => true,
    };
    return Scaffold(
      appBar: AppBar(title: Text(tr('hh_join'))),
      body: SafeArea(
        child: Column(children: [
          Expanded(child: body),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(children: [
              TextButton(
                onPressed: () => _done || _step == 0 ? Navigator.pop(context) : setState(() => _step = _step == 4 && !hiddenOn ? (_hasOwn ? 2 : 1) : _step - 1),
                child: Text(_done ? tr('done') : tr('hh_back')),
              ),
              const Spacer(),
              if (!_done && _step >= 1 && _step <= 3)
                FilledButton(
                  onPressed: !canNext
                      ? null
                      : () {
                          if (_step == 1) {
                            _afterWho();
                          } else {
                            setState(() => _step = _step == 2 && !hiddenOn ? 4 : _step + 1);
                          }
                        },
                  child: Text(_step == 3 && _pw1.text.isEmpty ? tr('skip') : tr('next')),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}
