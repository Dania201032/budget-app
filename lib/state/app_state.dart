import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, FileSystemEvent;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ChangeNotifier, debugPrint;
import 'package:flutter/services.dart' show MissingPluginException, PlatformException;

import '../capture/capture_service.dart';
import '../capture/receipt.dart';
import '../capture/shared_text.dart';
import '../data/models.dart';
import '../data/rates.dart';
import '../data/repository.dart';
import '../domain/budget_math.dart';
import '../domain/envelopes.dart';
import '../domain/holding.dart';
import '../domain/net_worth.dart';
import '../domain/money.dart';
import '../domain/periods.dart';
import '../domain/runway.dart';
import '../domain/tax_tags.dart';
import '../household/household.dart';
import '../import/statement_import.dart';
import '../io/app_log.dart';
import '../premium/premium.dart';
import '../io/backup.dart';
import '../io/home_widgets.dart';
import '../io/sheet_import.dart';
import '../l10n/strings.dart';
import '../platform.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_folder.dart';
import '../sync/sync_service.dart';

class AppState extends ChangeNotifier {
  final Repository repo;
  final CaptureService capture;
  final RatesService rates;
  final BackupService backup;
  final CaptureImporter _importer;

  /// Phone ⇄ computer sync through a cloud folder (off until set up in Settings).
  final SyncService sync;

  /// Saldo Plus: trial, personal key or the store's subscription (lib/premium/).
  final Plus plus;
  PlusStatus plusStatus = const PlusStatus(PlusSource.trial);
  bool get isPlus => plusStatus.active;
  bool plusAllows(PlusFeature f) => plusStatus.allows(f);
  bool get syncPaused => sync.enabled && !plusAllows(PlusFeature.sync);

  AppState(this.repo, this.capture, this.rates, {StoreBilling? store})
      : _importer = CaptureImporter(repo),
        backup = BackupService(repo),
        sync = SyncService(repo),
        plus = Plus(repo, store: store) {
    // Debts paid back in another currency are matched by the rate.
    repo.convert = rates.convert;
  }

  bool loaded = false;
  bool onboarded = false;
  String country = 'CN';

  /// Reading the payment screen is needed where people pay with Alipay or WeChat (their payment
  /// notifications lack the details); with bank cards the notifications are enough.
  bool get captureNeedsScreen => country == 'CN' || accounts.any((a) => a.type == 'alipay' || a.type == 'wechat');
  bool get captureReady => captureStatus.ready(needsScreen: captureNeedsScreen);
  String baseCurrency = 'CNY';
  bool budgetEnabled = true;

  /// The day's limit on Home and the widgets: budget ÷ days in the month instead of what is left
  /// of the budget ÷ the days left (setting daily_limit = fixed).
  bool fixedDailyLimit = false;

  /// The automatic recording disclosure was accepted (see confirmCaptureDisclosure).
  bool captureConsent = false;
  List<Category> categories = [];
  List<Account> accounts = [];

  // --- Shared budget (lib/household/) ---
  HouseholdConfig? household;
  List<Person> people = [];

  /// Whose budget the screens show when people have limits of their own.
  BudgetScope budgetScope = BudgetScope.all;
  final Map<String, int> _personalBudgets = {};

  /// This device takes part in a shared budget.
  bool get householdOn => household != null && sync.person != null;
  String? get me => householdOn ? sync.person : null;
  Person? personOf(String? uid) => uid == null ? null : people.where((p) => p.uid == uid).firstOrNull;
  bool get _scoped => householdOn && household!.personalLimits && budgetScope != BudgetScope.all;

  /// A person's own limit in base currency (shared budget with personal limits).
  int personalBudget(String uid) => _personalBudgets[uid] ?? 0;

  /// Whether [t] counts in the budget the screens show (always, unless people have own limits).
  bool inBudgetScope(Txn t) => !_scoped || _inScope(t);

  bool _inScope(Txn t) {
    final owner = t.accountId == null ? null : accountById[t.accountId]?.owner;
    return budgetScope == BudgetScope.common ? owner == null : owner == me;
  }

  Future<void> _loadHousehold() async {
    household = await repo.household();
    people = await repo.people();
    repo.me = householdOn ? sync.person : null;
    budgetScope = BudgetScope.values.asNameMap()[await repo.setting('budget_scope')] ?? BudgetScope.all;
    _personalBudgets.clear();
    if (householdOn && household!.personalLimits) {
      final now = DateTime.now();
      for (final p in people) {
        final b = await repo.personalBudget(p.uid);
        if (b != null) _personalBudgets[p.uid] = rates.toBase(b.$1, b.$2, now) ?? b.$1;
      }
    }
  }

  /// After the shared budget was set up, joined, left or changed.
  Future<void> reloadHousehold() async {
    await _loadHousehold();
    accounts = await repo.accounts();
    _changed();
    await _reloadAll();
  }

  Future<void> setBudgetScope(BudgetScope s) async {
    budgetScope = s;
    await repo.setSetting('budget_scope', s.name);
    await _reloadAll();
  }

  /// A person's own monthly limit (shared budget), in base currency.
  Future<void> setPersonalBudget(String person, int amountMinor) async {
    await repo.setPersonalBudget(person, amountMinor, baseCurrency);
    await reloadHousehold();
  }

  /// The common monthly budget as set, whatever budget the screens show.
  int commonBudget(DateTime m) => budgetEnabled ? _budgets[DateTime(m.year, m.month)] ?? 0 : 0;
  Map<int, int> balances = {};
  List<Goal> goals = [];

  /// Names of all goals, closed ones too: purchases paid from a goal show it.
  Map<int, String> goalNames = {};
  List<Debt> openDebts = [];

  /// Regular payments and incomes, soonest first.
  List<Recurring> recurring = [];
  CaptureStatus captureStatus = const CaptureStatus();
  List<Txn> reviewQueue = [];

  /// Set when "Split…" was pressed on a notification: the UI opens the split sheet for it.
  Txn? pendingSplit;

  /// Set when a home-screen widget was tapped: the shell opens the matching screen.
  WidgetRoute? pendingWidgetRoute;

  // Home: any period type; the "today" card always uses the current month.
  Period homePeriod = Period.containing(PeriodType.month, DateTime.now());
  List<Txn> homeTxns = [];
  PeriodStats? homeStats;
  List<Txn> _currentMonthTxns = [];

  /// The first operation's time: periods have no budget before it.
  DateTime? _since;
  MonthStats? todayStats;

  // Overview: its own period.
  Period period = Period.containing(PeriodType.month, DateTime.now());
  List<Txn> periodTxns = [];
  PeriodStats? periodStats;

  // Analytics: its own period, last 6 months of totals, and the runway settings.
  Period analyticsPeriod = Period.containing(PeriodType.month, DateTime.now());
  List<Txn> analyticsTxns = [];
  PeriodStats? analyticsStats;

  /// (month, spent, income) for the last 6 months, base currency.
  List<(DateTime, int, int)> monthlyTotals = [];
  RunwayConfig runwayConfig = const RunwayConfig();

  /// Overview breakdown view: list | calendar | table.
  String overviewView = 'list';

  /// Analytics charts the user switched off.
  Set<String> hiddenCharts = {};

  // Backup
  String? backupUri;
  String? backupFolder;
  DateTime? backupLast;
  /// Backups are encrypted (a key derived from the password is in the Android Keystore).
  bool backupEncrypted = false;
  bool _dirty = false;

  /// Month budgets in the base currency before goal reserves, by first day of month.
  final Map<DateTime, int> _budgets = {};

  Map<int, Category> get categoryById => {for (final c in categories) c.id: c};
  Map<int, Account> get accountById => {for (final a in accounts) a.id: a};
  List<Category> categoriesOf(TxnKind kind) => categories.where((c) => c.kind == kind).toList();

  String categoryName(Category c) => c.key != null && hasTr('cat_${c.key}') ? tr('cat_${c.key}') : c.name;
  String accountName(Account a) => a.key == 'cash' ? tr('acc_cash') : a.name;

  /// Converts the amount that counts (my share of a split bill) to the base currency.
  int? toBase(Txn t) => rates.toBase(t.effectiveMinor, t.currency, t.time);

  int? toBaseAmount(int minor, String currency, DateTime at) => rates.toBase(minor, currency, at);

  Set<String> get foreignCurrencies => {
        for (final a in accounts) a.currency,
        for (final g in goals) g.currency,
        for (final h in holdings) h.currency,
        for (final t in [...homeTxns, ...periodTxns, ..._currentMonthTxns]) t.currency,
      }..remove(baseCurrency);

  int get owedToMeMinor => openDebts.fold(0, (s, d) => s + (rates.toBase(d.openMinor, d.currency, DateTime.now()) ?? 0));

  // --- Lifecycle ---

  Future<void> init({bool syncAfter = true}) async {
    await repo.applyLedgerPalette();
    currentLanguage = await repo.setting('language') ?? 'ru';
    onboarded = await repo.setting('onboarded') == '1';
    country = await repo.setting('country') ?? 'CN';
    baseCurrency = await repo.setting('base_currency') ?? 'CNY';
    budgetEnabled = await repo.setting('budget_enabled') != '0';
    fixedDailyLimit = await repo.setting('daily_limit') == 'fixed';
    eveningReminder = await repo.setting('evening_reminder') ?? '21:00';
    captureConsent = await repo.setting('capture_consent') != null;
    final staleUntil = DateTime.tryParse(await repo.setting('stale_hint_until') ?? '');
    staleHintHidden = staleUntil != null && staleUntil.isAfter(DateTime.now());
    backupUri = await repo.setting('backup_uri');
    backupFolder = await repo.setting('backup_folder');
    await sync.load();
    await _migrateBackupPassword();
    runwayConfig = RunwayConfig.fromJsonString(await repo.setting('runway_config'));
    overviewView = await repo.setting('overview_view') ?? 'list';
    hiddenCharts = (await repo.setting('hidden_charts') ?? '').split(',').where((s) => s.isNotEmpty).toSet();
    final last = await repo.setting('backup_last');
    backupLast = last == null ? null : DateTime.tryParse(last);
    AppLog.line('init: settings read');
    await capture.setLanguage(currentLanguage);
    await rates.load(baseCurrency);
    AppLog.line('init: rates loaded');
    await _loadHousehold();
    await _loadPlus();
    // Once: names and notes recorded before the parsers were fixed (v0.8.8).
    if (await repo.setting('cleanup_names') == null) {
      await repo.cleanUpCapturedNames();
      await repo.setSetting('cleanup_names', '1');
    }
    // Once after the update that taught the app transfers between my own accounts (schema v7).
    if (await repo.setting('own_transfers_paired') != '2') {
      await _importer.pairEarlierTransfers();
      await repo.setSetting('own_transfers_paired', '2');
    }
    // Once after v0.13.2: purchases paid from a goal took the money from the account a second time.
    if (await repo.setting('goal_purchases_off_accounts') == null) {
      await repo.db.update('transactions', {'account_id': null}, where: 'goal_id IS NOT NULL AND excluded = 1');
      await repo.setSetting('goal_purchases_off_accounts', '1');
    }
    await refresh();
    AppLog.line('init: refreshed');
    // The phone keeps the reminders even if the app was not opened for a while; refresh them.
    await syncReminders();
    if (syncAfter) unawaited(syncNow());
    _watchSync();
  }

  // --- Sync with the computer / the phone ---

  Timer? _syncTimer;
  Timer? _syncSoon;
  StreamSubscription<FileSystemEvent>? _folderWatch;
  bool _foreground = true;

  /// While the app is open it looks at the folder every 30 s (computer) / 45 s (phone); the
  /// computer also reacts at once when Google Drive drops another device's file into the folder.
  void _watchSync() {
    _syncTimer ??= Timer.periodic(Duration(seconds: appIsDesktop ? 30 : 45), (_) {
      if (_foreground && sync.enabled) syncNow();
    });
    final path = sync.folderPath;
    if (!appIsDesktop || _folderWatch != null || path == null) return;
    try {
      _folderWatch = Directory(path).watch().listen((e) {
        final name = e.path.split(RegExp(r'[\\/]')).last;
        if (name.endsWith('.bsync') && !name.contains(sync.device ?? '-')) _syncAfter(const Duration(seconds: 2));
      });
    } catch (e) {
      // Some virtual drives don't report changes: the 30-second look still works.
      AppLog.line('folder watch unavailable: $e');
    }
  }

  /// The app is in front (phone: not paused); the periodic look runs only then.
  set foreground(bool v) => _foreground = v;

  /// A sync shortly after a change: a few edits in a row travel together.
  void _syncAfter(Duration d) {
    if (!sync.enabled) return;
    _syncSoon?.cancel();
    _syncSoon = Timer(d, syncNow);
  }

  Future<void> _loadPlus() async {
    final s = await plus.status(me: me);
    plusStatus = s.source != PlusSource.household
        ? s
        : PlusStatus(s.source, until: s.until, licensee: people.where((p) => p.uid == s.licensee).firstOrNull?.name);
  }

  Future<void> refreshPlus() async {
    await _loadPlus();
    notifyListeners();
  }

  /// A personal key; true when it was valid.
  Future<bool> enterPlusKey(String key) async {
    final ok = await plus.enterKey(key) != null;
    await refreshPlus();
    return ok;
  }

  Future<void> removePlusKey() async {
    await plus.removeKey();
    await refreshPlus();
  }

  /// Sends this device's changes and takes the other's; reloads the screens if something came.
  Future<void> syncNow() async {
    // Sync is Plus: without it, it pauses (the data stays on every device as it is). In a shared
    // budget one look a day still goes through: a partner's renewed Plus arrives that way.
    if (!plusAllows(PlusFeature.sync)) {
      if (!householdOn) return;
      final last = DateTime.tryParse(await repo.setting('plus_check_sync') ?? '');
      if (last != null && DateTime.now().difference(last) < const Duration(days: 1)) return;
      await repo.setSetting('plus_check_sync', DateTime.now().toIso8601String());
    }
    final r = await sync.sync();
    if (r != null && r.received > 0) {
      _budgets.clear();
      await init(syncAfter: false);
    }
  }

  /// Joins sync through [folder] (or starts it, on the first device). Throws [WrongSyncPassword].
  Future<SyncReport> connectSync(SyncFolder folder, String password, {required String kind, required String location}) async {
    final r = await sync.connect(folder, password, kind: kind, location: location);
    _budgets.clear();
    await init(syncAfter: false);
    return r;
  }

  /// [connectSync] for a person joining a shared budget (see SyncEngine.enable).
  Future<SyncReport> connectSyncAs(SyncFolder folder, String password,
      {required String kind,
      required String location,
      bool wipe = false,
      Future<void> Function()? beforeTake,
      Future<void> Function()? beforeSend}) async {
    final r = await sync.connect(folder, password,
        kind: kind, location: location, wipe: wipe, beforeTake: beforeTake, beforeSend: beforeSend);
    _budgets.clear();
    await init(syncAfter: false);
    return r;
  }

  Future<void> disconnectSync() async {
    await _folderWatch?.cancel();
    _folderWatch = null;
    await sync.disconnect();
  }

  /// Pulls freshly captured payments, then reloads everything shown on screen.
  Future<void> refresh() async {
    captureStatus = await capture.status();
    // The other devices may have changed the shared budget's people and limits.
    await _loadHousehold();
    // A store subscription may have started or ended, the trial run out, a partner's Plus come.
    await _loadPlus();
    final imported = await _importer.importAll(await capture.consumeInbox());
    if (imported > 0) {
      _dirty = true;
      _maybeQuietToday();
    }
    // A hand-made "ВТБ" and the one automatic recording made for the same bank become one.
    if (await repo.mergeDuplicateBankAccounts() > 0) _dirty = true;
    await repo.removeAnsweredPrompts();
    categories = await repo.categories();
    accounts = await repo.accounts();
    goals = await repo.goals();
    goalNames = await repo.goalNames();
    await _loadNetWorth();
    await _loadEnvelopes();
    taxTags = await loadTaxTags(repo);
    await _reloadAll(notify: false);
    loaded = true;
    await _takePendingAction();
    if (foreignCurrencies.isEmpty) await _recordNetWorth();
    notifyListeners();
    _updateRates();
  }

  Future<void> _takePendingAction() async {
    final a = await capture.takePendingAction();
    // "Share → Budget": a text, or a screenshot whose text is read on the phone.
    if (a != null && (a['type'] == 'share' || a['type'] == 'share_image')) {
      final text = a['type'] == 'share' ? a['text'] as String? : await capture.readSharedImage(a['uri'] as String);
      // A picture that couldn't be read (no Google Play services, the model not downloaded yet).
      shareUnreadable = text == null && a['type'] == 'share_image';
      pendingShare = parseSharedText(text ?? '');
      return;
    }
    if (a != null && a['type'] == 'widget') {
      final id = (a['categoryId'] as num?)?.toInt() ?? 0;
      pendingWidgetRoute = WidgetRoute(a['route'] as String? ?? 'home', id > 0 && categoryById.containsKey(id) ? id : null);
      return;
    }
    if (a == null || a['type'] != 'split') return;
    pendingSplit = await repo.findSamePayment(
      appPrefix: a['app'] as String,
      kind: TxnKind.expense,
      amountMinor: (a['amountMinor'] as num).toInt(),
      time: DateTime.fromMillisecondsSinceEpoch((a['ts'] as num).toInt()),
    );
  }

  Future<void> _reloadAll({bool notify = true}) async {
    reviewQueue = await repo.txnsNeedingReview();
    openDebts = await repo.openDebts();
    recurring = await repo.recurring();
    balances = await repo.accountBalances();
    final now = DateTime.now();
    final month = DateTime(now.year, now.month);
    _currentMonthTxns = await repo.txnsBetween(month, DateTime(now.year, now.month + 1));
    _since = await repo.firstTxnTime();
    homeTxns = await repo.txnsBetween(homePeriod.start, homePeriod.end);
    periodTxns = await repo.txnsBetween(period.start, period.end);
    analyticsTxns = await repo.txnsBetween(analyticsPeriod.start, analyticsPeriod.end);
    final sixAgo = DateTime(now.year, now.month - 5);
    _sixMonthTxns = await repo.txnsBetween(sixAgo, DateTime(now.year, now.month + 1));
    if (_scoped) {
      _currentMonthTxns = _currentMonthTxns.where(_inScope).toList();
      homeTxns = homeTxns.where(_inScope).toList();
      periodTxns = periodTxns.where(_inScope).toList();
      analyticsTxns = analyticsTxns.where(_inScope).toList();
      _sixMonthTxns = _sixMonthTxns.where(_inScope).toList();
    }
    _markFresh();
    await _loadBudgets({
      for (final d in analyticsPeriod.days) DateTime(d.year, d.month),
      month,
      for (final d in homePeriod.days) DateTime(d.year, d.month),
      for (final d in period.days) DateTime(d.year, d.month),
    });
    _compute();
    if (notify) notifyListeners();
    HomeWidgetsBridge.push(this);
  }

  // Payments added since the previous load slide into the lists (TxnTile → AppearIn).
  int? _lastSeenId;
  int _freshAfterId = 0;
  DateTime _freshAt = DateTime(0);

  void _markFresh() {
    var maxId = 0;
    for (final t in [..._currentMonthTxns, ...homeTxns, ...periodTxns]) {
      if ((t.id ?? 0) > maxId) maxId = t.id!;
    }
    final last = _lastSeenId;
    if (last != null && maxId > last) {
      _freshAfterId = last;
      _freshAt = DateTime.now();
    }
    if (last == null || maxId > last) _lastSeenId = maxId;
  }

  bool isFresh(Txn t) =>
      t.id != null && t.id! > _freshAfterId && DateTime.now().difference(_freshAt) < const Duration(seconds: 4);

  /// The current calendar month (for the widgets), whatever period the screens show.
  PeriodStats currentMonthStats() => PeriodStats.compute(
        period: Period.containing(PeriodType.month, DateTime.now()),
        txns: _currentMonthTxns,
        toBase: toBase,
        monthBudget: monthBudget,
      );

  /// Expense categories used most in the last six months (built-in order for the rest).
  List<Category> frequentExpenseCategories(int count) {
    final uses = <int, int>{};
    for (final t in _sixMonthTxns) {
      if (t.kind == TxnKind.expense && t.categoryId != null) uses[t.categoryId!] = (uses[t.categoryId!] ?? 0) + 1;
    }
    final list = categoriesOf(TxnKind.expense);
    final order = {for (var i = 0; i < list.length; i++) list[i].id: i};
    list.sort((a, b) {
      final byUse = (uses[b.id] ?? 0).compareTo(uses[a.id] ?? 0);
      return byUse != 0 ? byUse : order[a.id]!.compareTo(order[b.id]!);
    });
    return list.take(count).toList();
  }

  void _compute() {
    final now = DateTime.now();
    todayStats = MonthStats.compute(
      month: DateTime(now.year, now.month),
      now: now,
      budgetMinor: monthBudget(now),
      txns: _currentMonthTxns,
      baseCurrency: baseCurrency,
      toBase: toBase,
      fixedDaily: fixedDailyLimit,
    );
    // Today's limit as the home screen shows it, so the day view says the same.
    final todayLimit = todayStats!.todayAllowance.round();
    homeStats = PeriodStats.compute(
        period: homePeriod, txns: homeTxns, toBase: toBase, monthBudget: monthBudget, since: _since, todayLimit: todayLimit);
    periodStats = PeriodStats.compute(
        period: period, txns: periodTxns, toBase: toBase, monthBudget: monthBudget, since: _since, todayLimit: todayLimit);
    analyticsStats = PeriodStats.compute(
        period: analyticsPeriod, txns: analyticsTxns, toBase: toBase, monthBudget: monthBudget, since: _since, todayLimit: todayLimit);
    final months = [for (var i = 5; i >= 0; i--) DateTime(now.year, now.month - i)];
    monthlyTotals = [
      for (final m in months)
        () {
          var spent = 0, income = 0;
          for (final t in _sixMonthTxns) {
            if (t.excluded || t.time.year != m.year || t.time.month != m.month) continue;
            final v = toBase(t) ?? 0;
            if (t.kind == TxnKind.income) {
              income += v;
            } else {
              spent += v;
            }
          }
          return (m, spent, income);
        }(),
    ];
  }

  List<Txn> _sixMonthTxns = [];

  /// Downloads missing exchange rates in the background, then recomputes.
  Future<void> _updateRates() async {
    final foreign = foreignCurrencies;
    if (foreign.isEmpty) return;
    final days = <DateTime>{
      DateTime.now(),
      for (final t in [...homeTxns, ...periodTxns, ..._currentMonthTxns])
        if (t.currency != baseCurrency) DateTime(t.time.year, t.time.month, t.time.day),
    };
    await rates.ensure(days, foreign);
    for (final m in _budgets.keys.toList()) {
      _budgets[m] = await _budgetInBase(m);
    }
    _compute();
    await _recordNetWorth();
    notifyListeners();
    HomeWidgetsBridge.push(this);
  }

  Future<int> _budgetInBase(DateTime m) async {
    final (amount, currency) = await repo.budgetFor(m);
    return rates.toBase(amount, currency, m) ?? amount;
  }

  Future<void> _loadBudgets(Iterable<DateTime> months) async {
    for (final m in months) {
      final key = DateTime(m.year, m.month);
      _budgets[key] = await _budgetInBase(key);
    }
  }

  /// Monthly budget in base currency (as set by the user), 0 when the budget is off.
  int rawMonthBudget(DateTime m) {
    if (!budgetEnabled) return 0;
    final common = _budgets[DateTime(m.year, m.month)] ?? 0;
    // Shared budget with limits of one's own: the common one, mine, or all of them together.
    if (!householdOn || !household!.personalLimits) return common;
    return switch (budgetScope) {
      BudgetScope.common => common,
      BudgetScope.mine => _personalBudgets[me] ?? 0,
      BudgetScope.all => common + _personalBudgets.values.fold(0, (a, b) => a + b),
    };
  }

  /// Money set aside for goals in [m] (goals with "reserve from budget"), in base currency.
  int goalReserve(DateTime m) {
    // Goals are the household's: they come out of the common limit, not a person's own.
    if (!budgetEnabled || (_scoped && budgetScope == BudgetScope.mine)) return 0;
    final now = DateTime.now();
    return goals
        .where((g) => g.reservesIn(m))
        .fold(0, (s, g) => s + (rates.toBase(g.monthlyNeed(now), g.currency, now) ?? 0));
  }

  /// What can be spent in [m]: budget minus goal reserves.
  int monthBudget(DateTime m) {
    final b = rawMonthBudget(m);
    if (b == 0) return 0;
    return (b - goalReserve(m)).clamp(0, b);
  }

  Future<bool> _hasRecordsSince(DateTime from) async =>
      (await repo.db.query('transactions', columns: ['id'], where: 'ts >= ?', whereArgs: [from.millisecondsSinceEpoch], limit: 1))
          .isNotEmpty;

  void _changed() {
    _dirty = true;
    _maybeQuietToday();
    // The other device gets it within seconds, not at the next periodic look.
    _syncAfter(const Duration(seconds: 3));
  }

  // --- Navigation ---

  Future<void> setHomePeriod(Period p) async {
    homePeriod = p;
    await _reloadAll();
    _updateRates();
  }

  Future<void> setHomePeriodType(PeriodType type) {
    final now = DateTime.now();
    return setHomePeriod(Period.containing(type, homePeriod.contains(now) ? now : homePeriod.start));
  }

  Future<void> setPeriod(Period p) async {
    period = p;
    await _reloadAll();
    _updateRates();
  }

  Future<void> setPeriodType(PeriodType type) {
    final now = DateTime.now();
    return setPeriod(Period.containing(type, period.contains(now) ? now : period.start));
  }

  // --- Onboarding, language, country ---

  Future<void> setLanguage(String lang) async {
    currentLanguage = lang;
    await repo.setSetting('language', lang);
    await capture.setLanguage(lang);
    notifyListeners();
  }

  /// First start: country (presets currency and accounts on a fresh install) and language.
  Future<void> completeOnboarding({required String country, required String lang}) async {
    await setLanguage(lang);
    final fresh = !await repo.hasTransactions() && !onboarded;
    await repo.applyCountryPreset(country, fresh: fresh, cashName: tr('acc_cash'));
    this.country = country;
    baseCurrency = await repo.setting('base_currency') ?? baseCurrency;
    await rates.load(baseCurrency);
    await repo.setSetting('onboarded', '1');
    onboarded = true;
    _budgets.clear();
    await refresh();
  }

  /// First start on the computer: the user's countries, main currency and banks. On a fresh
  /// install the accounts are created from the chosen banks (name, currency, type) plus cash.
  Future<void> completeDesktopSetup({
    required String home,
    required String base,
    required List<(String, String, String)> accounts,
    required String countriesJson,
  }) async {
    final fresh = !await repo.hasTransactions() && !onboarded;
    await repo.setSetting('country', home);
    await repo.setSetting('desk_countries', countriesJson);
    country = home;
    if (fresh) {
      await repo.db.delete('accounts');
      for (final (name, currency, type) in accounts) {
        await repo.addAccount(name, currency, type);
      }
      await repo.addAccount(tr('acc_cash'), base, 'cash', key: 'cash');
      await repo.setSetting('base_currency', base);
    }
    baseCurrency = await repo.setting('base_currency') ?? base;
    await rates.load(baseCurrency);
    await repo.setSetting('onboarded', '1');
    onboarded = true;
    _budgets.clear();
    await refresh();
  }

  Future<void> setCountry(String c) async {
    country = c;
    await repo.setSetting('country', c);
    _changed();
    notifyListeners();
  }

  static const countryCurrency = {'CN': 'CNY', 'RU': 'RUB', 'KZ': 'KZT', 'DE': 'EUR', 'NL': 'EUR'};

  // --- Transactions ---

  /// Inserts or updates; returns the transaction id.
  Future<int> saveTxn(Txn t, {bool rememberMerchant = true}) async {
    final int id;
    if (t.id == null) {
      id = await repo.insertTxn(t);
    } else {
      id = t.id!;
      await repo.updateTxn(t);
    }
    if (rememberMerchant && t.merchant != null && t.categoryId != null && t.isCaptured) {
      await repo.rememberMerchant(t.merchant!, t.categoryId!);
    }
    _changed();
    await _reloadAll();
    _updateRates();
    return id;
  }

  /// Quick categorization from the review list; also teaches the merchant rule.
  Future<void> categorize(Txn t, Category c) async {
    await saveTxn(t.copyWith(categoryId: () => c.id, kind: c.kind, needsReview: t.amountMinor == 0));
  }

  /// Amount for a WeChat transfer that arrived without one.
  Future<void> setAmount(Txn t, int amountMinor) async {
    await saveTxn(t.copyWith(amountMinor: amountMinor, needsReview: t.categoryId == null));
    final saved = await repo.txnById(t.id!);
    if (saved != null && await repo.settleDebtsWith(saved)) await _reloadAll();
  }

  Future<void> acceptCaptureConsent() async {
    captureConsent = true;
    await repo.setSetting('capture_consent', DateTime.now().toIso8601String());
  }

  Future<void> deleteTxn(Txn t) async {
    // The other side of a transfer to myself: the one the app made goes too, a real one stays alone.
    final pair = t.pairId == null ? null : await repo.txnById(t.pairId!);
    if (pair != null) {
      if (pair.raw == Repository.mirrorRaw) {
        await repo.deleteTxn(pair.id!);
      } else {
        await repo.updateTxn(pair.copyWith(pairId: () => null));
      }
    }
    await repo.deleteTxn(t.id!);
    await repo.dismiss(t);
    _changed();
    await _reloadAll();
  }

  // --- Bill splitting ---

  /// My share of [t]; [friends] = (name or null, amount owed).
  Future<void> applySplit(Txn t, int myShare, List<(String?, int)> friends) async {
    await repo.updateTxn(t.copyWith(shareMinor: () => myShare));
    await repo.setDebts(t.id!, friends, t.currency);
    _changed();
    await _reloadAll();
  }

  Future<void> removeSplit(Txn t) async {
    await repo.updateTxn(t.copyWith(shareMinor: () => null));
    await repo.setDebts(t.id!, const [], t.currency);
    _changed();
    await _reloadAll();
  }

  Future<List<Debt>> debtsOf(Txn t) => t.id == null ? Future.value(const []) : repo.debtsForTxn(t.id!);

  Future<void> markDebtReturned(Debt d) async {
    await repo.settleDebt(d.id, d.openMinor);
    _changed();
    await _reloadAll();
  }

  /// "This income is [d] paid back": the debt closes, the income doesn't count.
  Future<void> settleDebtWith(Debt d, Txn income) async {
    await repo.settleDebtByHand(d, income);
    _changed();
    await _reloadAll();
  }

  /// Marks [t] as a transfer between my own accounts (pairing it with its other side if recorded,
  /// remembering my name as the bank writes it), or makes it count again.
  Future<void> setOwnTransfer(Txn t, bool own) async {
    if (own) {
      final twin = await repo.findTransferTwin(t);
      await repo.linkOwnTransfer(t, twin);
      await repo.addSelfName(t.merchant);
    } else {
      await repo.unlinkOwnTransfer(t);
    }
    _changed();
    await _reloadAll();
  }

  /// The other account of a transfer to myself, chosen by hand (null = not kept in the app).
  /// False when there is no exchange rate to put the amount into that account's currency.
  Future<bool> setTransferCounterpart(Txn t, Account? other) async {
    final ok = await repo.setTransferCounterpart(t, other);
    _changed();
    await _reloadAll();
    return ok;
  }

  void clearPendingSplit() => pendingSplit = null;
  void clearPendingWidgetRoute() => pendingWidgetRoute = null;

  /// What was shared to the app, to open in the editor once.
  SharedGuess? pendingShare;
  bool shareUnreadable = false;
  void clearPendingShare() => pendingShare = null;

  /// A new operation from a shared text: an account in its currency, if there is one.
  Txn draftFrom(SharedGuess g) {
    final account = g.currency == null ? null : accounts.where((a) => a.currency == g.currency).firstOrNull;
    return Txn(
      time: DateTime.now(),
      amountMinor: g.amountMinor ?? 0,
      currency: g.currency ?? baseCurrency,
      kind: g.kind,
      merchant: g.merchant,
      note: g.note.isEmpty ? null : g.note,
      accountId: account?.id,
    );
  }

  // --- Budget & currency ---

  Future<void> setBudget(int amountMinor) async {
    final now = DateTime.now();
    await repo.setBudget(DateTime(now.year, now.month), amountMinor, baseCurrency);
    if (!budgetEnabled) await setBudgetEnabled(true);
    _budgets.clear();
    _changed();
    await _reloadAll();
  }

  Future<void> setBudgetEnabled(bool on) async {
    budgetEnabled = on;
    await repo.setSetting('budget_enabled', on ? '1' : '0');
    _changed();
    await _reloadAll();
  }

  Future<void> setFixedDailyLimit(bool on) async {
    fixedDailyLimit = on;
    await repo.setSetting('daily_limit', on ? 'fixed' : 'even');
    _changed();
    _compute();
    notifyListeners();
    HomeWidgetsBridge.push(this);
  }

  Future<void> setBaseCurrency(String code) async {
    if (code == baseCurrency) return;
    baseCurrency = code;
    await repo.setSetting('base_currency', code);
    await rates.load(code);
    _budgets.clear();
    _changed();
    await _reloadAll();
    _updateRates();
  }

  /// [rate] = how many [quote] for 1 unit of the base currency; null = back to automatic.
  Future<void> setManualRate(String quote, double? rate) async {
    await rates.setManual(quote, rate);
    for (final m in _budgets.keys.toList()) {
      _budgets[m] = await _budgetInBase(m);
    }
    _compute();
    _changed();
    notifyListeners();
    if (rate == null) _updateRates();
  }

  // --- Categories & accounts ---

  Future<void> addCategory(String name, TxnKind kind, String icon, int color) async {
    await repo.addCategory(name, kind, icon, color);
    categories = await repo.categories();
    _changed();
    notifyListeners();
  }

  Future<void> updateCategory(Category c, {required String name, required String icon, required int color}) async {
    await repo.updateCategory(c.id, name: name, icon: icon, color: color, renamed: name != categoryName(c));
    categories = await repo.categories();
    _changed();
    notifyListeners();
  }

  Future<void> archiveCategory(Category c) async {
    await repo.archiveCategory(c.id);
    categories = await repo.categories();
    _changed();
    notifyListeners();
  }

  Future<void> addAccount(String name, String currency) async {
    await repo.addAccount(name, currency, 'bank');
    await repo.mergeDuplicateBankAccounts();
    accounts = await repo.accounts();
    _changed();
    notifyListeners();
    _updateRates();
  }

  Future<void> updateAccount(Account a, {required String name, required String currency}) async {
    await repo.updateAccount(a.id, name: name, currency: currency, renamed: name != accountName(a));
    await repo.mergeDuplicateBankAccounts();
    accounts = await repo.accounts();
    _changed();
    notifyListeners();
    _updateRates();
  }

  Future<void> archiveAccount(Account a) async {
    await repo.archiveAccount(a.id);
    accounts = await repo.accounts();
    _changed();
    await _reloadAll();
  }

  Future<void> setAccountBalance(Account a, int balanceMinor) async {
    await repo.setAccountBalance(a.id, balanceMinor, DateTime.now());
    accounts = await repo.accounts();
    _changed();
    await _reloadAll();
  }

  // --- Tax marks (lib/domain/tax_tags.dart) ---

  /// Category uid -> tax mark.
  Map<String, String> taxTags = {};

  String? categoryTaxTag(int? categoryId) => categoryId == null ? null : taxTags[_categoryUids[categoryId]];

  /// The mark that counts for [t]: its own, else its category's.
  String? taxTagOf(Txn t) => t.taxTag == 'none' ? null : (t.taxTag ?? categoryTaxTag(t.categoryId));

  Future<void> setCategoryTaxTag(Category c, String? tag) async {
    final uid = _categoryUids[c.id];
    if (uid == null) return;
    if (tag == null) {
      taxTags.remove(uid);
    } else {
      taxTags[uid] = tag;
    }
    await saveTaxTags(repo, taxTags);
    _changed();
    notifyListeners();
  }

  /// The year's marked spending, by mark.
  Future<Map<String, List<Txn>>> taxReport(int year) async {
    final out = <String, List<Txn>>{};
    for (final t in await repo.txnsBetween(DateTime(year), DateTime(year + 1))) {
      if (t.kind != TxnKind.expense) continue;
      final tag = taxTagOf(t);
      if (tag != null) out.putIfAbsent(tag, () => []).add(t);
    }
    return out;
  }

  /// Reads a receipt photo on the phone: its QR code and its text.
  Future<ReceiptGuess> scanReceipt(String path) async {
    final r = await capture.scanReceipt(path);
    final qr = r.$2 == null ? null : parseFiscalQr(r.$2!);
    if (qr != null) {
      final text = r.$1 == null ? null : parseReceiptText(r.$1!);
      return ReceiptGuess(amountMinor: qr.amountMinor, currency: qr.currency, time: qr.time, shop: text?.shop, refund: qr.refund);
    }
    return r.$1 == null ? const ReceiptGuess() : parseReceiptText(r.$1!);
  }

  // --- Envelopes (lib/domain/envelopes.dart) ---

  EnvelopeSettings envelopes = EnvelopeSettings();
  Map<int, String> _categoryUids = {};

  Future<void> _loadEnvelopes() async {
    envelopes = await loadEnvelopes(repo);
    _categoryUids = {
      for (final r in await repo.db.query('categories', columns: ['id', 'uid']))
        if (r['uid'] != null) r['id'] as int: r['uid'] as String,
    };
  }

  /// Every expense category's envelope in [month]: put in, spent, and what is left after
  /// carrying everything since the mode was turned on.
  Future<List<Envelope>> envelopesFor(DateTime month) async {
    final key = envelopeMonth(month);
    final start = envelopes.start ?? key;
    final months = envelopeMonthsUpTo(start, key);
    final s = start.split('-').map(int.parse).toList();
    final txns = await repo.txnsBetween(DateTime(s[0], s[1]), DateTime(month.year, month.month + 1));
    final spent = <int, Map<String, int>>{};
    for (final t in txns) {
      if (t.kind != TxnKind.expense || t.excluded || t.categoryId == null) continue;
      final v = rates.toBase(t.effectiveMinor, t.currency, t.time) ?? (t.currency == baseCurrency ? t.effectiveMinor : 0);
      final m = envelopeMonth(t.time);
      spent.putIfAbsent(t.categoryId!, () => {})[m] = (spent[t.categoryId!]![m] ?? 0) + v;
    }
    return [
      for (final c in categoriesOf(TxnKind.expense))
        if (_categoryUids[c.id] case final uid?)
          Envelope(
            c.id,
            envelopes.allocated(uid, key),
            spent[c.id]?[key] ?? 0,
            months.fold(0, (a, m) => a + envelopes.allocated(uid, m) - (spent[c.id]?[m] ?? 0)),
          ),
    ];
  }

  /// The month's budget not yet put in an envelope.
  int envelopesToAssign(DateTime month, List<Envelope> list) =>
      commonBudget(month) - list.fold(0, (a, e) => a + e.allocated);

  Future<void> setEnvelopesOn(bool on) async {
    envelopes.on = on;
    envelopes.start ??= envelopeMonth(DateTime.now());
    await saveEnvelopes(repo, envelopes);
    _changed();
    notifyListeners();
  }

  /// What goes into [c]'s envelope in [month]; [everyMonth]: from now on, every month.
  Future<void> setEnvelope(Category c, DateTime month, int amountMinor, {required bool everyMonth}) async {
    final uid = _categoryUids[c.id];
    if (uid == null) return;
    final key = envelopeMonth(month);
    if (everyMonth) {
      envelopes.plan[uid] = amountMinor;
      envelopes.months[key]?.remove(uid);
    } else {
      envelopes.months.putIfAbsent(key, () => {})[uid] = amountMinor;
    }
    await saveEnvelopes(repo, envelopes);
    _changed();
    notifyListeners();
  }

  /// Moves money between two envelopes for [month] (covering an overspent one, say).
  Future<void> moveEnvelope(Category from, Category to, DateTime month, int amountMinor) async {
    final a = _categoryUids[from.id], b = _categoryUids[to.id];
    if (a == null || b == null || a == b) return;
    final key = envelopeMonth(month);
    final m = envelopes.months.putIfAbsent(key, () => {});
    m[a] = envelopes.allocated(a, key) - amountMinor;
    m[b] = envelopes.allocated(b, key) + amountMinor;
    await saveEnvelopes(repo, envelopes);
    _changed();
    notifyListeners();
  }

  // --- Net worth ---

  /// Investments, property and loans (shared with the computer's Income page).
  List<Holding> holdings = [];

  /// The net worth recorded for each month ("2026-10").
  Map<String, int> netWorthHistory = {};

  NetWorth get netWorth {
    final now = DateTime.now();
    var accounts = 0, cards = 0;
    for (final e in balances.entries) {
      final a = accountById[e.key];
      final v = a == null ? null : rates.toBase(e.value, a.currency, now);
      if (v == null) continue;
      if (v >= 0) {
        accounts += v;
      } else {
        cards -= v;
      }
    }
    var investments = 0, property = 0, loans = 0;
    for (final h in holdings) {
      final v = rates.toBase(h.amountMinor, h.currency, now) ?? 0;
      if (h.isLoan) {
        loans += v;
      } else if (h.type == 'property') {
        property += v;
      } else {
        investments += v;
      }
    }
    return NetWorth(
      accounts: accounts,
      cards: cards,
      goals: goals.fold(0, (s, g) => s + (rates.toBase(g.savedMinor, g.currency, now) ?? 0)),
      investments: investments,
      property: property,
      loans: loans,
      owedToMe: owedToMeMinor,
    );
  }

  /// After the computer saved its profile: investments and the envelopes' plan again.
  Future<void> reloadShared() async {
    await _loadNetWorth();
    await _loadEnvelopes();
    _changed();
  }

  Future<void> _loadNetWorth() async {
    holdings = await loadHoldings(repo);
    netWorthHistory = await loadNetWorthHistory(repo);
  }

  /// Writes this month's net worth when it changed (one setting, shared by the devices).
  Future<void> _recordNetWorth() async {
    if (balances.isEmpty && holdings.isEmpty && goals.isEmpty) return;
    final key = monthKey(DateTime.now());
    final v = netWorth.total;
    if (netWorthHistory[key] == v) return;
    netWorthHistory = {...netWorthHistory, key: v};
    await repo.setSetting('networth_history', jsonEncode(netWorthHistory));
  }

  Future<void> saveHolding(Holding h) async {
    holdings = [for (final x in holdings) if (x.id != h.id) x, h];
    await saveHoldings(repo, holdings);
    _changed();
    await _recordNetWorth();
    notifyListeners();
  }

  Future<void> deleteHolding(Holding h) async {
    holdings = [for (final x in holdings) if (x.id != h.id) x];
    await saveHoldings(repo, holdings);
    _changed();
    await _recordNetWorth();
    notifyListeners();
  }

  /// Total of all accounts with a balance, in the base currency.
  int get totalBalance => balances.entries.fold(0, (s, e) {
        final a = accountById[e.key];
        if (a == null) return s;
        return s + (rates.toBase(e.value, a.currency, DateTime.now()) ?? 0);
      });

  // --- Goals ---

  Future<void> addGoal({
    required String name,
    required int targetMinor,
    required int savedMinor,
    DateTime? deadline,
    required bool reserve,
    int? accountId,
  }) async {
    await repo.addGoal(
        name: name, targetMinor: targetMinor, savedMinor: savedMinor, currency: baseCurrency, deadline: deadline,
        reserve: reserve, accountId: accountId);
    await _goalsChanged();
  }

  Future<void> updateGoal(Goal g, {
    required String name,
    required int targetMinor,
    required int savedMinor,
    DateTime? deadline,
    required bool reserve,
    int? accountId,
  }) async {
    await repo.updateGoal(g.id,
        name: name, targetMinor: targetMinor, savedMinor: savedMinor, deadline: deadline, reserve: reserve, accountId: accountId);
    await _goalsChanged();
  }

  /// Puts money aside (positive) or takes it out (negative). With an account, its balance moves too:
  /// a transfer record that is not an expense or income.
  Future<void> addToGoal(Goal g, int amountMinor, {int? accountId}) async {
    await repo.addToGoal(g.id, amountMinor);
    final a = accountId == null ? null : accountById[accountId];
    if (a != null && amountMinor != 0) {
      final now = DateTime.now();
      final inAccount = rates.convert(amountMinor.abs(), g.currency, a.currency, now) ?? amountMinor.abs();
      await repo.insertTxn(Txn(
        time: now,
        amountMinor: inAccount,
        currency: a.currency,
        kind: amountMinor > 0 ? TxnKind.expense : TxnKind.income,
        excluded: true,
        accountId: a.id,
        merchant: g.name,
        source: 'goal',
      ));
    }
    await _goalsChanged();
  }

  Future<void> deleteGoal(Goal g) async {
    await repo.archiveGoal(g.id);
    await _goalsChanged();
  }

  /// "Close a goal": [t] is paid from [g]'s savings. The money left its account when it was put
  /// aside, so the purchase moves no account balance again, and it isn't spending of the month's
  /// budget either; it keeps its category. Savings short of the price pay their part: the rest
  /// stays an ordinary purchase from the account. [close]: the goal is reached and closed.
  Future<void> spendFromGoal(Txn t, Goal g, {required bool close}) async {
    if (t.goalId != null && t.goalId != g.id) await returnToGoal(t);
    if (t.goalId != g.id) {
      final inGoal = rates.convert(t.amountMinor, t.currency, g.currency, t.time) ?? t.amountMinor;
      final fresh = await repo.goalById(g.id) ?? g;
      final taken = inGoal.clamp(0, fresh.savedMinor);
      if (taken > 0) await repo.addToGoal(g.id, -taken);
      final takenHere = taken >= inGoal ? t.amountMinor : (rates.convert(taken, g.currency, t.currency, t.time) ?? taken);
      Txn fromGoal(Txn x, int amount) => x.copyWith(
            amountMinor: amount,
            shareMinor: () => null,
            goalId: () => g.id,
            accountId: () => null,
            excluded: true,
            needsReview: false,
            merchant: () => x.merchant ?? g.name,
          );
      if (takenHere >= t.amountMinor) {
        await repo.updateTxn(fromGoal(t, t.amountMinor));
      } else if (takenHere > 0) {
        await repo.updateTxn(t.copyWith(amountMinor: t.amountMinor - takenHere, shareMinor: () => null));
        await repo.insertTxn(Txn(
          time: t.time,
          amountMinor: takenHere,
          currency: t.currency,
          kind: TxnKind.expense,
          categoryId: t.categoryId,
          merchant: t.merchant ?? g.name,
          note: t.note,
          excluded: true,
          goalId: g.id,
        ));
      }
    }
    if (close) await repo.archiveGoal(g.id);
    await _goalsChanged();
  }

  /// Undoes [spendFromGoal]: the money goes back to the goal, the purchase is ordinary spending
  /// again (from the account [accountId], if given).
  Future<void> returnToGoal(Txn t, {int? accountId}) async {
    final id = t.goalId;
    if (id == null) return;
    final g = await repo.goalById(id);
    if (g != null) {
      final inGoal = rates.convert(t.amountMinor, t.currency, g.currency, t.time) ?? t.amountMinor;
      if (t.excluded) await repo.addToGoal(id, inGoal);
      await repo.unarchiveGoal(id);
    }
    await repo.updateTxn(t.copyWith(goalId: () => null, excluded: false, accountId: () => accountId ?? t.accountId));
    await _goalsChanged();
  }

  /// A purchase recorded from the goal itself (Money → goal → "Close a goal").
  Future<void> buyFromGoal(Goal g, int amountMinor, {String? merchant, required bool close}) async {
    final id = await repo.insertTxn(Txn(
      time: DateTime.now(),
      amountMinor: amountMinor,
      currency: g.currency,
      kind: TxnKind.expense,
      merchant: merchant == null || merchant.trim().isEmpty ? g.name : merchant.trim(),
    ));
    final t = await repo.txnById(id);
    if (t != null) await spendFromGoal(t, g, close: close);
  }

  Future<void> _goalsChanged() async {
    goals = await repo.goals();
    goalNames = await repo.goalNames();
    _changed();
    await _reloadAll();
    _updateRates();
  }

  // --- Analytics ---

  Future<void> setAnalyticsPeriod(Period p) async {
    analyticsPeriod = p;
    await _reloadAll();
    _updateRates();
  }

  Future<void> setAnalyticsPeriodType(PeriodType type) {
    final now = DateTime.now();
    return setAnalyticsPeriod(Period.containing(type, analyticsPeriod.contains(now) ? now : analyticsPeriod.start));
  }

  Future<void> setOverviewView(String view) async {
    overviewView = view;
    await repo.setSetting('overview_view', view);
    notifyListeners();
  }

  Future<void> setChartVisible(String chart, bool visible) async {
    visible ? hiddenCharts.remove(chart) : hiddenCharts.add(chart);
    await repo.setSetting('hidden_charts', hiddenCharts.join(','));
    notifyListeners();
  }

  Future<void> saveRunwayConfig(RunwayConfig c) async {
    runwayConfig = c;
    await repo.setSetting('runway_config', c.toJsonString());
    _changed();
    notifyListeners();
  }

  /// Accounts counted by default: those with a reconciled balance.
  List<Account> get accountsWithBalance => accounts.where((a) => balances.containsKey(a.id)).toList();

  /// A balance not checked for two weeks drifts: cash and operations nobody notified about.
  static const staleAfter = Duration(days: 14);

  bool isStale(Account a) => a.balanceAt != null && DateTime.now().difference(a.balanceAt!) > staleAfter;

  List<Account> get staleAccounts => accounts.where(isStale).toList();

  /// "Check your balances" on the home screen, hidden for a week after "Later".
  bool staleHintHidden = false;

  Future<void> hideStaleHint() async {
    staleHintHidden = true;
    await repo.setSetting('stale_hint_until', DateTime.now().add(const Duration(days: 7)).toIso8601String());
    notifyListeners();
  }

  /// Money available now under [c], in base currency.
  int runwayStart(RunwayConfig c) {
    final now = DateTime.now();
    var total = c.extraMinor;
    final ids = c.accountIds ?? balances.keys.toSet();
    for (final id in ids) {
      final a = accountById[id];
      final b = balances[id];
      if (a == null || b == null) continue;
      total += rates.toBase(b, a.currency, now) ?? 0;
    }
    if (c.includeGoalSavings) {
      for (final g in goals) {
        total += rates.toBase(g.savedMinor, g.currency, now) ?? 0;
      }
    }
    return total;
  }

  /// Average spending and income per day over the last [days] days (stats rules: my share, no
  /// excluded transfers), without [excludedCategories].
  Future<(double, double)> averagesPerDay(int days, Set<int> excludedCategories) async {
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day - days + 1);
    final txns = await repo.txnsBetween(from, DateTime(now.year, now.month, now.day + 1));
    var spent = 0, income = 0;
    for (final t in txns) {
      // Regular items count in the forecast by themselves, not inside the average.
      if (t.excluded || t.source == Repository.recurringSource) continue;
      final v = toBase(t) ?? 0;
      if (t.kind == TxnKind.income) {
        income += v;
      } else if (!excludedCategories.contains(t.categoryId)) {
        spent += v;
      }
    }
    return (spent / days, income / days);
  }

  Future<RunwayResult> computeRunwayFor(RunwayConfig c) async {
    final now = DateTime.now();
    final (avgSpend, avgIncome) = await averagesPerDay(c.averageDays, c.excludedCategories);
    final spend = switch (c.spendMode) {
      SpendMode.average => avgSpend,
      SpendMode.budget => rawMonthBudget(now) * 12 / 365,
      SpendMode.custom => c.customSpendPerMonthMinor * 12 / 365,
    };
    final income = switch (c.incomeMode) {
      IncomeMode.none => 0.0,
      IncomeMode.average => avgIncome,
      IncomeMode.custom => c.customIncomePerMonthMinor * 12 / 365,
    };
    return computeRunway(
      config: c.useRecurring ? c.copyWith(planned: [...c.planned, ...recurringPlanned(c.horizonMonths)]) : c,
      startMinor: runwayStart(c),
      baseSpendPerDay: spend,
      baseIncomePerDay: income,
      now: now,
    );
  }

  /// The regular payments and incomes of the next [months] as planned items in the base currency.
  List<PlannedItem> recurringPlanned(int months) {
    final now = DateTime.now();
    final until = DateTime(now.year, now.month + months, now.day);
    return [
      for (final r in recurring)
        for (final d in r.occurrences(until))
          if (toBaseAmount(r.amountMinor, r.currency, d) case final v?)
            PlannedItem(name: r.name, amountMinor: r.kind == TxnKind.income ? v : -v, date: d),
    ];
  }

  // --- Regular payments and incomes ---

  /// Due within a week (or overdue): the home screen's "Soon".
  List<Recurring> get recurringSoon {
    final now = DateTime.now();
    final weekAhead = DateTime(now.year, now.month, now.day + 7);
    return recurring.where((r) => !r.next.isAfter(weekAhead)).toList();
  }

  Future<void> saveRecurring(Recurring r) async {
    await repo.saveRecurring(r);
    await _recurringChanged();
  }

  Future<void> deleteRecurring(Recurring r) async {
    await repo.deleteRecurring(r.id!);
    await _recurringChanged();
  }

  Future<void> recordRecurring(Recurring r) async {
    await repo.recordRecurring(r);
    await _recurringChanged();
  }

  Future<void> skipRecurring(Recurring r) async {
    await repo.skipRecurring(r);
    await _recurringChanged();
  }

  Future<void> _recurringChanged() async {
    _changed();
    await _reloadAll();
    await syncReminders();
  }

  /// The evening "nothing recorded today" reminder: "21:00", or "off".
  String eveningReminder = '21:00';

  Future<void> setEveningReminder(String v) async {
    eveningReminder = v;
    await repo.setSetting('evening_reminder', v);
    await syncReminders();
    notifyListeners();
  }

  /// The day already known to have records (no evening reminder that day).
  DateTime? _quietDay;

  /// After a record: the first one of the day takes today's evening reminder away.
  void _maybeQuietToday() {
    final now = DateTime.now();
    if (_quietDay != DateTime(now.year, now.month, now.day)) unawaited(syncReminders());
  }

  /// Tells the phone when to remind: the due dates of the next 60 days, at 10:00, and the evening
  /// reminder of the next two weeks (not today once something was recorded; the phone also drops
  /// it when a payment is caught that day).
  Future<void> syncReminders() async {
    final now = DateTime.now();
    final until = DateTime(now.year, now.month, now.day + 60);
    final today = DateTime(now.year, now.month, now.day);
    final recordedToday = await _hasRecordsSince(today);
    _quietDay = recordedToday ? today : null;
    final evening = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(eveningReminder);
    await capture.setReminders([
      if (evening != null)
        for (var i = 0; i < 14; i++)
          if (DateTime(now.year, now.month, now.day + i, int.parse(evening[1]!), int.parse(evening[2]!)) case final at
              when at.isAfter(now) && !(i == 0 && recordedToday))
            {
              'ts': at.millisecondsSinceEpoch,
              'title': tr('evening_title'),
              'text': tr('evening_text'),
              'idle': true,
            },
      for (final r in recurring.where((r) => r.remind))
        for (final d in r.occurrences(until))
          if (DateTime(d.year, d.month, d.day, 10).isAfter(now))
            {
              'ts': DateTime(d.year, d.month, d.day, 10).millisecondsSinceEpoch,
              'title': r.name,
              'text': tr(r.kind == TxnKind.income ? 'reminder_income' : 'reminder_payment',
                  [formatMoney(r.amountMinor, r.currency)]),
            },
    ]);
  }

  /// Biggest payees of the analytics period: (name, amount in base), largest first.
  List<(String, int)> get topPayees {
    final sums = <String, int>{};
    for (final t in analyticsTxns) {
      if (t.kind != TxnKind.expense || t.excluded || t.merchant == null) continue;
      sums[t.merchant!] = (sums[t.merchant!] ?? 0) + (toBase(t) ?? 0);
    }
    final list = sums.entries.map((e) => (e.key, e.value)).toList()..sort((a, b) => b.$2.compareTo(a.$2));
    return list.take(8).toList();
  }

  Future<void> restoreGoal(Goal g) async {
    await repo.unarchiveGoal(g.id);
    await _goalsChanged();
  }

  // --- Backup ---

  bool get backupConfigured => backupUri != null;

  /// v0.5 kept the password in the database; now only a Keystore-protected key is kept natively.
  Future<void> _migrateBackupPassword() async {
    try {
      final legacy = await repo.setting('backup_password');
      if (legacy != null && legacy.isNotEmpty) await backup.setPassword(legacy);
      if (legacy != null) await repo.db.delete('settings', where: 'key = ?', whereArgs: ['backup_password']);
      backupEncrypted = await backup.hasPassword();
    } on MissingPluginException {
      backupEncrypted = false;
    }
  }

  Future<bool> chooseBackupFolder() async {
    final r = await backup.pickFolder();
    if (r == null) return false;
    backupUri = r.$1;
    backupFolder = r.$2;
    await repo.setSetting('backup_uri', r.$1);
    await repo.setSetting('backup_folder', r.$2);
    notifyListeners();
    return true;
  }

  Future<void> setBackupPassword(String? password) async {
    await backup.setPassword(password);
    backupEncrypted = await backup.hasPassword();
    _changed();
    notifyListeners();
  }

  Future<bool> checkBackupPassword(String password) => backup.checkPassword(password);

  /// Writes a backup now; throws on failure.
  Future<void> backupNow() async {
    final uri = backupUri;
    if (uri == null) return;
    await backup.writeToFolder(uri, await backup.serialize());
    backupLast = DateTime.now();
    await repo.setSetting('backup_last', backupLast!.toIso8601String());
    _dirty = false;
    notifyListeners();
  }

  /// Called when the app goes to the background: back up if something changed.
  Future<void> autoBackup() async {
    if (!_dirty || backupUri == null) return;
    try {
      await backupNow();
    } on PlatformException catch (e) {
      debugPrint('Auto backup failed: ${e.message}');
    }
  }

  /// Restores from a backup file (already decrypted payload).
  Future<void> restoreFrom(List<int> payload) async {
    await backup.restore(Uint8List.fromList(payload));
    await repo.setSetting('onboarded', '1');
    _budgets.clear();
    await init();
  }

  // --- Import ---

  Future<void> applyImport(SheetImportPlan plan) async {
    await applySheetImport(repo, plan);
    categories = await repo.categories();
    _budgets.clear();
    _changed();
    await _reloadAll();
    _updateRates();
  }

  /// Adds a bank statement's missing operations (see lib/import/). Returns how many were added.
  Future<int> applyStatement(StatementPlan plan) async {
    final added = await applyStatementImport(repo, plan);
    _changed();
    await refresh();
    return added;
  }

  /// Transactions for export: all of them or only the given period (oldest first).
  Future<List<Txn>> txnsForExport(Period? p) async {
    final all = p == null ? await repo.allTxns() : (await repo.txnsBetween(p.start, p.end)).reversed.toList();
    final missing = {for (final t in all) t.currency}..remove(baseCurrency);
    if (missing.isNotEmpty) {
      await rates.ensure({for (final t in all) DateTime(t.time.year, t.time.month, t.time.day)}, missing,
          maxRequests: 30);
    }
    return all;
  }
}
