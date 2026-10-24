import 'package:sqflite_sqlcipher/sqflite.dart';

import 'database.dart';
import 'models.dart';

String monthKey(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';

/// [amountMinor] in [from] expressed in [to] at [at], or null without a rate (RatesService.convert).
typedef CurrencyConverter = int? Function(int amountMinor, String from, String to, DateTime at);

class Repository {
  final Database db;
  Repository(this.db);

  /// Set by AppState: lets a friend pay back in another currency (100 ¥ owed, 1 200 ₽ received).
  CurrencyConverter? convert;

  /// Shared budget: the person this device belongs to (null when the budget isn't shared). New
  /// operations get them as author; capture uses only their own and common accounts, and never
  /// takes another person's payment for a duplicate of mine.
  String? me;

  /// SQL condition: recorded on this person's devices (or before the budget was shared).
  String get _mine => me == null ? '1 = 1' : "(author IS NULL OR author = '$me')";

  bool _usable(Account a) => me == null || a.owner == null || a.owner == me;

  // --- Reference data ---

  Future<List<Category>> categories() async =>
      (await db.query('categories', where: 'archived = 0', orderBy: 'kind, sort, id')).map(Category.fromRow).toList();

  Future<int> addCategory(String name, TxnKind kind, String icon, int color) async {
    final maxSort = Sqflite.firstIntValue(
            await db.rawQuery('SELECT MAX(sort) FROM categories WHERE kind = ?', [kind.name])) ??
        0;
    return db.insert('categories', {
      'name': name,
      'icon': icon,
      'color': color,
      'kind': kind.name,
      'sort': maxSort + 1,
    });
  }

  /// [renamed] = the user typed a new name, so a built-in category stops being auto-translated.
  Future<void> updateCategory(int id,
          {required String name, required String icon, required int color, bool renamed = false}) =>
      db.update('categories', {'name': name, 'icon': icon, 'color': color, if (renamed) 'key': null},
          where: 'id = ?', whereArgs: [id]);

  Future<void> archiveCategory(int id) =>
      db.update('categories', {'archived': 1}, where: 'id = ?', whereArgs: [id]);

  Future<List<Account>> accounts() async =>
      (await db.query('accounts', where: 'archived = 0', orderBy: 'sort, id')).map(Account.fromRow).toList();

  Future<int> addAccount(String name, String currency, String type, {String? key, String? owner}) async {
    final maxSort = Sqflite.firstIntValue(await db.rawQuery('SELECT MAX(sort) FROM accounts')) ?? 0;
    return db.insert('accounts',
        {'name': name, 'currency': currency, 'type': type, 'key': key, 'sort': maxSort + 1, 'owner': ?owner});
  }

  /// Accounts this device's person may record into: their own and the common ones.
  Future<List<Account>> myAccounts() async => (await accounts()).where(_usable).toList();

  Future<void> updateAccount(int id, {required String name, required String currency, bool renamed = false}) =>
      db.update('accounts', {'name': name, 'currency': currency, if (renamed) 'key': null},
          where: 'id = ?', whereArgs: [id]);

  /// The user's account for bank [key] ("vtb", "sber"…): one already linked to that bank, or one
  /// the user created with the bank's name ("ВТБ", "Сбербанк", "Tinkoff") in [currency], which
  /// becomes linked. Null if the user has none.
  Future<int?> accountForBank(String key, String currency) async {
    final all = await myAccounts();
    final linked = all.where((a) => a.type == key).firstOrNull;
    if (linked != null) return linked.id;
    final named = all.where((a) => a.type == 'bank' && a.currency == currency && bankKeyForName(a.name) == key).firstOrNull;
    if (named == null) return null;
    await db.update('accounts', {'type': key}, where: 'id = ?', whereArgs: [named.id]);
    return named.id;
  }

  /// Before v0.6.2 a bank's first notification created its own account even when the user already
  /// had one ("ВТБ" twice). Moves the operations of such an automatic account (no balance entered)
  /// to the user's account of that bank and removes it.
  Future<int> mergeDuplicateBankAccounts() async {
    // Never another person's account with mine.
    final all = await myAccounts();
    var merged = 0;
    for (final auto in all.where((a) => bankAliases.containsKey(a.type) && a.balanceMinor == null)) {
      final target = all
          .where((a) =>
              a.id != auto.id &&
              a.currency == auto.currency &&
              (a.type == 'bank' && bankKeyForName(a.name) == auto.type ||
                  a.type == auto.type && a.balanceMinor != null))
          .firstOrNull;
      if (target == null) continue;
      await db.transaction((tx) async {
        await tx.update('transactions', {'account_id': target.id}, where: 'account_id = ?', whereArgs: [auto.id]);
        await tx.update('goals', {'account_id': target.id}, where: 'account_id = ?', whereArgs: [auto.id]);
        await tx.delete('accounts', where: 'id = ?', whereArgs: [auto.id]);
        await tx.update('accounts', {'type': auto.type}, where: 'id = ?', whereArgs: [target.id]);
      });
      merged++;
    }
    return merged;
  }

  Future<void> archiveAccount(int id) => db.update('accounts', {'archived': 1}, where: 'id = ?', whereArgs: [id]);

  /// "Сверка": the real balance now; later transactions of the account move it automatically.
  Future<void> setAccountBalance(int id, int balanceMinor, DateTime at) => db.update(
      'accounts', {'balance_minor': balanceMinor, 'balance_at': at.millisecondsSinceEpoch},
      where: 'id = ?', whereArgs: [id]);

  /// Current balances (account id -> minor units) for accounts with a balance set: the entered
  /// balance plus incomes minus expenses recorded after it (full amounts — money actually moved).
  Future<Map<int, int>> accountBalances() async {
    final rows = await db.rawQuery('''
      SELECT a.id, a.balance_minor + COALESCE((
        SELECT SUM(CASE WHEN t.kind = 'income' THEN t.amount_minor ELSE -t.amount_minor END)
        FROM transactions t WHERE t.account_id = a.id AND t.ts > a.balance_at), 0) AS balance
      FROM accounts a WHERE a.archived = 0 AND a.balance_minor IS NOT NULL''');
    return {for (final r in rows) r['id'] as int: (r['balance'] as num).toInt()};
  }

  /// First-run setup for a country: its currency and typical accounts. Only for a fresh install
  /// ([fresh]); otherwise existing accounts and data are left alone.
  Future<void> applyCountryPreset(String country, {required bool fresh, required String cashName}) async {
    await setSetting('country', country);
    if (!fresh) return;
    final (currency, accounts, budget) = switch (country) {
      'RU' => ('RUB', [('Сбер', 'sber'), ('Т-Банк', 'tbank')], 3000000),
      'KZ' => ('KZT', [('Kaspi', 'kaspi'), ('Halyk', 'halyk')], 15000000),
      'DE' => ('EUR', [('DKB', 'dkb'), ('Sparkasse', 'sparkasse')], 100000),
      'NL' => ('EUR', [('ING', 'ing'), ('bunq', 'bunq')], 100000),
      _ => ('CNY', [('Alipay', 'alipay'), ('WeChat', 'wechat')], 300000),
    };
    await db.delete('accounts');
    for (final (name, type) in accounts) {
      await addAccount(name, currency, type);
    }
    await addAccount(cashName, currency, 'cash', key: 'cash');
    await setSetting('base_currency', currency);
    await setSetting('default_budget_minor', '$budget');
    await setSetting('default_budget_currency', currency);
  }

  Future<bool> hasTransactions() async =>
      (Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM transactions')) ?? 0) > 0;

  // --- Goals ---

  Future<List<Goal>> goals() async =>
      (await db.query('goals', where: 'archived = 0', orderBy: 'created_at')).map(Goal.fromRow).toList();

  Future<int> addGoal({
    required String name,
    required int targetMinor,
    required int savedMinor,
    required String currency,
    DateTime? deadline,
    required bool reserve,
    int? accountId,
  }) =>
      db.insert('goals', {
        'name': name,
        'target_minor': targetMinor,
        'saved_minor': savedMinor,
        'currency': currency,
        'deadline': deadline?.millisecondsSinceEpoch,
        'reserve': reserve ? 1 : 0,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'account_id': accountId,
      });

  Future<void> updateGoal(int id, {
    required String name,
    required int targetMinor,
    required int savedMinor,
    DateTime? deadline,
    required bool reserve,
    int? accountId,
  }) =>
      db.update(
        'goals',
        {
          'name': name,
          'target_minor': targetMinor,
          'saved_minor': savedMinor,
          'deadline': deadline?.millisecondsSinceEpoch,
          'reserve': reserve ? 1 : 0,
          'account_id': accountId,
        },
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<void> addToGoal(int id, int amountMinor) =>
      db.rawUpdate('UPDATE goals SET saved_minor = MAX(0, saved_minor + ?) WHERE id = ?', [amountMinor, id]);

  Future<void> archiveGoal(int id) => db.update('goals', {'archived': 1}, where: 'id = ?', whereArgs: [id]);

  Future<void> unarchiveGoal(int id) => db.update('goals', {'archived': 0}, where: 'id = ?', whereArgs: [id]);

  // --- Debts (bill splitting) ---

  /// Replaces the debts of a split bill.
  Future<void> setDebts(int txnId, List<(String?, int)> shares, String currency) async {
    await db.delete('debts', where: 'txn_id = ?', whereArgs: [txnId]);
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final (person, amount) in shares) {
      if (amount <= 0) continue;
      await db.insert('debts', {
        'txn_id': txnId,
        'person': (person == null || person.trim().isEmpty) ? null : person.trim(),
        'amount_minor': amount,
        'currency': currency,
        'created_at': now,
      });
    }
  }

  /// People you exchange money with (transfer contacts and debtors), most recent first.
  Future<List<String>> recentContacts({int limit = 12}) async {
    final rows = await db.rawQuery('''
      SELECT name FROM (
        SELECT merchant AS name, MAX(ts) AS at FROM transactions
        WHERE merchant IS NOT NULL AND (source LIKE '%prompt%' OR raw LIKE '收款-%' OR raw LIKE '扫收钱码付款-%')
        GROUP BY merchant
        UNION ALL
        SELECT person AS name, MAX(created_at) AS at FROM debts WHERE person IS NOT NULL GROUP BY person
      ) GROUP BY name ORDER BY MAX(at) DESC LIMIT ?''', [limit]);
    return rows.map((r) => r['name'] as String).toList();
  }

  Future<List<Debt>> debtsForTxn(int txnId) async =>
      (await db.query('debts', where: 'txn_id = ?', whereArgs: [txnId], orderBy: 'id')).map(Debt.fromRow).toList();

  Future<List<Debt>> openDebts() async =>
      (await db.query('debts', where: 'settled_minor < amount_minor', orderBy: 'created_at')).map(Debt.fromRow).toList();

  Future<void> settleDebt(int id, int amountMinor) => db.rawUpdate(
      'UPDATE debts SET settled_minor = MIN(amount_minor, settled_minor + ?) WHERE id = ?', [amountMinor, id]);

  Future<void> deleteDebt(int id) => db.delete('debts', where: 'id = ?', whereArgs: [id]);

  /// An incoming transfer may be a friend paying back: named debts of that person (any amount up to
  /// what they owe), or an unnamed debt of exactly this amount from the last 30 days. If it is, the
  /// debts are settled and the transfer is excluded from income. Returns true when matched.
  /// A debt paid back in another currency may differ from today's rate by this much (friends round,
  /// banks and apps use their own rates).
  static const crossCurrencyTolerance = 0.10;

  Future<bool> settleDebtsWith(Txn t) async {
    if (t.kind != TxnKind.income || t.amountMinor <= 0 || t.excluded || t.id == null) return false;
    // Each open debt with what it is worth in the transfer's currency (other currencies by the rate).
    final open = <(Debt, int)>[
      for (final d in await openDebts())
        if (d.currency == t.currency)
          (d, d.openMinor)
        else if (convert?.call(d.openMinor, d.currency, t.currency, t.time) case final v? when v > 0)
          (d, v),
    ];
    bool cross(Debt d) => d.currency != t.currency;
    int slack(int v, Debt d) => cross(d) ? (v * crossCurrencyTolerance).round() : 0;
    final person = t.merchant?.trim().toLowerCase();

    final named = person == null || person.isEmpty
        ? <(Debt, int)>[]
        : open.where((e) => e.$1.person?.trim().toLowerCase() == person).toList();
    final owed = named.fold<int>(0, (s, e) => s + e.$2);
    final owedSlack = named.fold<int>(0, (s, e) => s + slack(e.$2, e.$1));
    if (named.isNotEmpty && t.amountMinor <= owed + owedSlack) {
      var left = t.amountMinor;
      for (final (i, (d, worth)) in named.indexed) {
        if (left <= 0) break;
        final last = i == named.length - 1;
        // Within the tolerance of what's owed, the debt is paid in full (the rest is rounding).
        if (left >= worth - slack(worth, d) || last && left >= worth - owedSlack) {
          await settleDebt(d.id, d.openMinor);
          left -= worth;
        } else {
          final inDebtCurrency = cross(d) ? (d.openMinor * left / worth).round() : left;
          await settleDebt(d.id, inDebtCurrency);
          left = 0;
        }
      }
    } else {
      final since = t.time.subtract(const Duration(days: 30));
      final match = open
          .where((e) =>
              e.$1.person == null &&
              e.$1.createdAt.isAfter(since) &&
              (t.amountMinor - e.$2).abs() <= slack(e.$2, e.$1))
          .firstOrNull;
      if (match == null) return false;
      await settleDebt(match.$1.id, match.$1.openMinor);
    }
    await updateTxn(t.copyWith(excluded: true, needsReview: false));
    return true;
  }

  /// "This income is a friend paying back [d]" (chosen by hand): the debt is closed and the income
  /// doesn't count.
  Future<void> settleDebtByHand(Debt d, Txn income) async {
    await settleDebt(d.id, d.openMinor);
    await updateTxn(income.copyWith(excluded: true, needsReview: false));
  }

  // --- Transfers between my own accounts ---

  /// Payment apps and manual entries are never paired automatically (too many same-amount
  /// coincidences); bank operations are ("vtb:bank", "sber:sms", "tbank:bill").
  static bool isBankSource(String source) {
    if (!source.contains(':')) return false;
    return !const {'alipay', 'wechat', 'goal', 'quick', walletApp}.contains(source.split(':').first);
  }

  /// The other side of a transfer to myself: the opposite direction, same amount and currency,
  /// another account, within 30 minutes (the same day when one side is a bank history row without
  /// a time), not paired yet.
  Future<Txn?> findTransferTwin(Txn t) async {
    if (t.id == null || t.accountId == null) return null;
    final ms = t.time.millisecondsSinceEpoch;
    const day = 86400000;
    final rows = await db.query(
      'transactions',
      where: 'id != ? AND kind = ? AND amount_minor = ? AND currency = ? AND account_id IS NOT NULL AND account_id != ? '
          'AND ((own_transfer = 0 AND excluded = 0) OR (own_transfer = 1 AND pair_id IS NULL)) AND ts BETWEEN ? AND ?',
      whereArgs: [
        t.id, (t.kind == TxnKind.expense ? TxnKind.income : TxnKind.expense).name, t.amountMinor, t.currency,
        t.accountId, ms - day, ms + day,
      ],
      orderBy: 'ABS(ts - $ms)',
    );
    for (final r in rows.map(Txn.fromRow)) {
      if (!isBankSource(r.source)) continue;
      final dateOnly = t.source.contains('bill') || r.source.contains('bill');
      final sameDay = DateTime(r.time.year, r.time.month, r.time.day) == DateTime(t.time.year, t.time.month, t.time.day);
      if (dateOnly ? sameDay : (r.time.difference(t.time).inMinutes.abs() <= 30)) return r;
    }
    return null;
  }

  /// Marks [a] (and its other side [b], if known) as a transfer between my own accounts.
  Future<void> linkOwnTransfer(Txn a, Txn? b) async {
    await updateTxn(a.copyWith(ownTransfer: true, excluded: true, needsReview: false, pairId: () => b?.id));
    if (b != null) {
      await updateTxn(b.copyWith(ownTransfer: true, excluded: true, needsReview: false, pairId: () => a.id));
    }
  }

  /// "Not a transfer to myself": both sides count again (a side the app made up is removed).
  Future<void> unlinkOwnTransfer(Txn t) async {
    final pair = t.pairId == null ? null : await txnById(t.pairId!);
    await updateTxn(t.copyWith(ownTransfer: false, excluded: false, pairId: () => null));
    if (pair == null) return;
    if (pair.raw == mirrorRaw) {
      await deleteTxn(pair.id!);
    } else {
      await updateTxn(pair.copyWith(ownTransfer: false, excluded: false, pairId: () => null));
    }
  }

  /// Marks the other side of a transfer that the app made itself (not seen in any bank).
  static const mirrorRaw = 'own_transfer_mirror';

  /// The other account of a transfer to myself, chosen by hand ("from which account" / "to which
  /// account"); null = an account not kept in the app. The other side is the recorded operation
  /// of that bank when there is one; otherwise the app adds it (in that account's currency, by the
  /// rate), so both balances are right. Returns false when there is no rate for the conversion.
  Future<bool> setTransferCounterpart(Txn t, Account? other) async {
    final pair = t.pairId == null ? null : await txnById(t.pairId!);
    if (pair != null && other != null && pair.accountId == other.id) return true;
    // Detach the old other side.
    if (pair != null) {
      if (pair.raw == mirrorRaw) {
        await deleteTxn(pair.id!);
      } else {
        await updateTxn(pair.copyWith(ownTransfer: false, excluded: false, pairId: () => null));
      }
    }
    if (other == null) {
      await updateTxn(t.copyWith(pairId: () => null));
      return true;
    }
    final amount = other.currency == t.currency ? t.amountMinor : convert?.call(t.amountMinor, t.currency, other.currency, t.time);
    if (amount == null) {
      await updateTxn(t.copyWith(pairId: () => null));
      return false;
    }
    final from = t.accountId == null ? null : (await accounts()).where((a) => a.id == t.accountId).firstOrNull;
    final mirrorId = await insertTxn(Txn(
      time: t.time,
      amountMinor: amount,
      currency: other.currency,
      kind: t.kind == TxnKind.expense ? TxnKind.income : TxnKind.expense,
      accountId: other.id,
      merchant: from?.name,
      ownTransfer: true,
      excluded: true,
      pairId: t.id,
      raw: mirrorRaw,
    ));
    await updateTxn(t.copyWith(ownTransfer: true, excluded: true, pairId: () => mirrorId));
    return true;
  }

  /// Records made before the parsers were fixed: "Счёт карты VISA •• 4521" as the payee of Sber
  /// transfers (the sender from the bank text instead) and Alipay Bills statuses ("Auto debit
  /// successful") as the payment method. Returns how many rows changed.
  Future<int> cleanUpCapturedNames() async {
    var n = 0;
    // (No \b: Dart's word boundary is ASCII-only.)
    final ownCard = RegExp(r'^(сч[её]т|карта)', caseSensitive: false);
    for (final r in await db.query('transactions', where: "merchant IS NOT NULL AND source LIKE '%:%'")) {
      final t = Txn.fromRow(r);
      if (!ownCard.hasMatch(t.merchant!) || !RegExp(r'[•*]{1,2}\s?\d{4}').hasMatch(t.merchant!)) continue;
      await db.update('transactions', {'merchant': senderIn(t.raw)}, where: 'id = ?', whereArgs: [t.id]);
      n++;
    }
    n += await db.rawUpdate(
        "UPDATE transactions SET note = NULL WHERE source LIKE 'alipay:%' AND (note LIKE '%successful%' OR note LIKE '%成功%')");
    return n;
  }

  /// "Иван С." — how banks name me in transfers to my own accounts (learned from paired transfers).
  Future<Set<String>> selfNames() async =>
      ((await setting('self_names')) ?? '').split('\n').where((s) => s.isNotEmpty).toSet();

  /// Only person-like names ("Иван С.", "Ivan I"), never banks ("Сбербанк"): any transfer to that
  /// name would otherwise look like mine.
  /// "Иван С", "Иван Петрович С", "Ivan I. P".
  static final _personName = RegExp(r'^[A-ZА-ЯЁ][a-zа-яё]+( [A-ZА-ЯЁ][a-zа-яё]+)? [A-ZА-ЯЁ]\.?( ?[A-ZА-ЯЁ]\.?)?$');

  /// "ИВАН ПЕТРОВИЧ С.." -> "Иван Петрович С" (banks write names in capitals and with dots).
  static String normalizeName(String s) {
    final words = s.trim().replaceAll(RegExp(r'\.+$'), '').split(RegExp(r'\s+'));
    return words
        .map((w) => w.length > 2 && w == w.toUpperCase() ? w[0] + w.substring(1).toLowerCase() : w)
        .join(' ');
  }

  /// The sender named in a bank text: "… от ИВАН ПЕТРОВИЧ С. | …" (for learning my own name).
  static String? senderIn(String? raw) {
    if (raw == null) return null;
    final m = RegExp(r'\sот\s+([^.,;|]{2,40}?)(?:\.+\s|\.+$|,|;|\s+\||$)', caseSensitive: false).firstMatch(raw);
    return m == null ? null : normalizeName(m.group(1)!);
  }

  Future<void> addSelfName(String? name) async {
    if (name == null) return;
    final n = normalizeName(name);
    if (!_personName.hasMatch(n)) return;
    final names = await selfNames();
    if (names.add(n)) await setSetting('self_names', names.join('\n'));
  }

  // --- Regular payments and incomes ---

  Future<List<Recurring>> recurring() async =>
      (await db.query('recurring', where: 'archived = 0', orderBy: 'next_ts')).map(Recurring.fromRow).toList();

  Future<int> saveRecurring(Recurring r) async {
    if (r.id != null) {
      await db.update('recurring', r.toRow(), where: 'id = ?', whereArgs: [r.id]);
      return r.id!;
    }
    return db.insert('recurring', {...r.toRow(), 'created_at': DateTime.now().millisecondsSinceEpoch});
  }

  Future<void> deleteRecurring(int id) => db.update('recurring', {'archived': 1}, where: 'id = ?', whereArgs: [id]);

  /// Source of operations recorded from a regular payment: the forecast counts them as the regular
  /// item itself, so they stay out of the average spending.
  static const recurringSource = 'recurring';

  /// Records the due occurrence as an operation (today, or [at]) and moves on to the next date.
  Future<int> recordRecurring(Recurring r, {DateTime? at}) async {
    final id = await insertTxn(Txn(
      time: at ?? DateTime.now(),
      amountMinor: r.amountMinor,
      currency: r.currency,
      kind: r.kind,
      categoryId: r.categoryId,
      accountId: r.accountId,
      merchant: r.name,
      source: recurringSource,
    ));
    await saveRecurring(r.copyWith(next: r.after(r.next)));
    return id;
  }

  /// "Not this time": moves on to the next date without recording anything.
  Future<void> skipRecurring(Recurring r) => saveRecurring(r.copyWith(next: r.after(r.next)));

  // --- Backup ---

  Future<Map<String, List<Map<String, Object?>>>> dumpAll(List<String> tables) async =>
      {for (final t in tables) t: await db.query(t)};

  /// Replaces all data with [data] (rows keyed by column name; unknown columns are ignored).
  Future<void> restoreAll(Map<String, List<Map<String, Object?>>> data, List<String> tables) async {
    await db.transaction((tx) async {
      for (final t in tables.reversed) {
        await tx.delete(t);
      }
      for (final t in tables) {
        final rows = data[t];
        if (rows == null) continue;
        final columns = (await tx.rawQuery('PRAGMA table_info($t)')).map((c) => c['name'] as String).toSet();
        final b = tx.batch();
        for (final r in rows) {
          b.insert(t, {for (final e in r.entries) if (columns.contains(e.key)) e.key: e.value});
        }
        await b.commit(noResult: true);
      }
    });
  }

  // --- Settings ---

  Future<String?> setting(String key) async {
    final rows = await db.query('settings', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setSetting(String key, String value) =>
      db.insert('settings', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);

  /// One-time switch of built-in category colors to the ledger palette. Only colors still equal
  /// to the old defaults change; colors the user picked stay. Re-runs after restoring an old backup.
  Future<void> applyLedgerPalette() async {
    if (await setting('palette') == 'ledger') return;
    await db.transaction((tx) async {
      for (final e in ledgerPaletteMigration.entries) {
        await tx.update('categories', {'color': e.value}, where: 'color = ?', whereArgs: [e.key]);
      }
      await tx.insert('settings', {'key': 'palette', 'value': 'ledger'}, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  // --- Budgets ---

  /// Budget for [month] as (amount, currency): its own row, else the latest earlier month,
  /// else the default. The caller converts it to the current base currency.
  Future<(int, String)> budgetFor(DateTime month) async {
    final rows = await db.query('budgets',
        where: 'month <= ?', whereArgs: [monthKey(month)], orderBy: 'month DESC', limit: 1);
    if (rows.isNotEmpty) return (rows.first['amount_minor'] as int, rows.first['currency'] as String);
    return (
      int.tryParse(await setting('default_budget_minor') ?? '') ?? 0,
      await setting('default_budget_currency') ?? 'CNY',
    );
  }

  Future<void> setBudget(DateTime month, int amountMinor, String currency) => db.insert(
        'budgets',
        {'month': monthKey(month), 'amount_minor': amountMinor, 'currency': currency},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  // --- Transactions ---

  Future<List<Txn>> txnsBetween(DateTime from, DateTime to) async => (await db.query(
        'transactions',
        where: 'ts >= ? AND ts < ?',
        whereArgs: [from.millisecondsSinceEpoch, to.millisecondsSinceEpoch],
        orderBy: 'ts DESC, id DESC',
      ))
          .map(Txn.fromRow)
          .toList();

  Future<List<Txn>> allTxns() async =>
      (await db.query('transactions', orderBy: 'ts, id')).map(Txn.fromRow).toList();

  Future<int> deleteBySource(String source) => db.delete('transactions', where: 'source = ?', whereArgs: [source]);

  Future<void> insertTxns(List<Txn> txns) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final b = db.batch();
    for (final t in txns) {
      b.insert('transactions', {...t.toRow(), 'author': t.author ?? me, 'created_at': now});
    }
    await b.commit(noResult: true);
  }

  Future<List<Txn>> txnsNeedingReview() async =>
      (await db.query('transactions', where: 'needs_review = 1', orderBy: 'ts DESC')).map(Txn.fromRow).toList();

  Future<int> insertTxn(Txn t) =>
      db.insert('transactions', {...t.toRow(), 'author': t.author ?? me, 'created_at': DateTime.now().millisecondsSinceEpoch});

  Future<void> updateTxn(Txn t) => db.update('transactions', t.toRow(), where: 'id = ?', whereArgs: [t.id]);

  Future<void> deleteTxn(int id) => db.delete('transactions', where: 'id = ?', whereArgs: [id]);

  /// Remembers that an auto-captured operation was deleted by the user (manual, Excel and goal
  /// entries have no "app:" source and need nothing).
  Future<void> dismiss(Txn t) async {
    if (!t.source.contains(':')) return;
    await db.insert('dismissed', {
      'app': t.source.split(':').first,
      'kind': t.kind.name,
      'amount_minor': t.amountMinor,
      'ts': t.time.millisecondsSinceEpoch,
    });
  }

  /// Deleted operations of [app] like this one between [from] and [to].
  Future<int> dismissedCount({
    required String app,
    required TxnKind kind,
    required int amountMinor,
    required DateTime from,
    required DateTime to,
  }) async =>
      Sqflite.firstIntValue(await db.rawQuery(
        'SELECT COUNT(*) FROM dismissed WHERE app = ? AND kind = ? AND amount_minor = ? AND ts BETWEEN ? AND ?',
        [app, kind.name, amountMinor, from.millisecondsSinceEpoch, to.millisecondsSinceEpoch],
      )) ??
      0;

  /// What a bank history row (which may have no time) is checked against: operations of the same
  /// bank, direction and amount that day, and manual entries of that amount and currency.
  Future<List<Txn>> sameDayPayments({
    required String app,
    required TxnKind kind,
    required int amountMinor,
    required String currency,
    required DateTime day,
  }) async {
    final from = DateTime(day.year, day.month, day.day);
    final to = DateTime(day.year, day.month, day.day + 1);
    final rows = await db.query(
      'transactions',
      where: '(source LIKE ? OR (source = ? AND currency = ?)) AND kind = ? AND amount_minor = ? AND ts >= ? AND ts < ? AND $_mine',
      whereArgs: [
        '$app:%', 'manual', currency, kind.name, amountMinor,
        from.millisecondsSinceEpoch, to.millisecondsSinceEpoch,
      ],
      orderBy: 'ts',
    );
    return rows.map(Txn.fromRow).toList();
  }

  /// The same card payment seen both by Google Wallet and by the card's bank (its push or a history
  /// row): same direction, amount and currency within 15 minutes, or the same day when one side is a
  /// history row ([dateOnly], rows may have no time). [wallet]: looking from the Wallet side for the
  /// bank's operation, otherwise from the bank's side for a Wallet one not yet paired.
  Future<Txn?> findWalletTwin({
    required bool wallet,
    required TxnKind kind,
    required int amountMinor,
    required String currency,
    required DateTime time,
    bool dateOnly = false,
  }) async {
    final rows = await db.query(
      'transactions',
      where: 'kind = ? AND amount_minor = ? AND currency = ? AND ts BETWEEN ? AND ? AND $_mine',
      whereArgs: [
        kind.name,
        amountMinor,
        currency,
        time.subtract(const Duration(days: 1)).millisecondsSinceEpoch,
        time.add(const Duration(days: 1)).millisecondsSinceEpoch,
      ],
      orderBy: 'ABS(ts - ${time.millisecondsSinceEpoch})',
    );
    for (final t in rows.map(Txn.fromRow)) {
      final fromWallet = t.source.startsWith('$walletApp:');
      if (wallet) {
        // A bank operation not yet paired with a Wallet payment.
        if (fromWallet || !isBankSource(t.source) || t.source.contains('wallet')) continue;
      } else if (!fromWallet) {
        continue;
      }
      final rowOnly = dateOnly || (t.source.contains('bill') && !t.source.contains('bank'));
      final close = rowOnly
          ? t.time.year == time.year && t.time.month == time.month && t.time.day == time.day
          : t.time.difference(time).abs() <= const Duration(minutes: 15);
      if (close) return t;
    }
    return null;
  }

  /// An auto-captured transaction that could be the same payment seen by another source
  /// (screen vs notification): same app, direction and amount within [window].
  Future<Txn?> findCaptureTwin({
    required String app,
    required TxnKind kind,
    required int amountMinor,
    required DateTime time,
    required String sourceType,
    Duration window = const Duration(minutes: 3),
  }) async {
    final rows = await db.query(
      'transactions',
      where: 'source LIKE ? AND kind = ? AND amount_minor = ? AND ts BETWEEN ? AND ? AND $_mine',
      whereArgs: [
        '$app:%',
        kind.name,
        amountMinor,
        time.subtract(window).millisecondsSinceEpoch,
        time.add(window).millisecondsSinceEpoch,
      ],
      orderBy: 'ABS(ts - ${time.millisecondsSinceEpoch})',
    );
    for (final r in rows) {
      final t = Txn.fromRow(r);
      // Two payments of the same amount a minute apart are both real if the same source saw both.
      final seen = t.source.split(':').last.split('+');
      if (!seen.contains(sourceType)) return t;
    }
    return null;
  }

  /// True if this success screen was already recorded: Alipay shows the same success card again
  /// when its home page is reopened, sometimes many minutes later.
  Future<bool> isRepeatedScreen({
    required String app,
    required int amountMinor,
    required String? merchant,
    required DateTime time,
    Duration window = const Duration(minutes: 30),
  }) async {
    // Within a few minutes the merchant doesn't have to match: WeChat's success page is read once
    // before its merchant line appears and once after.
    const near = Duration(minutes: 3);
    final ms = time.millisecondsSinceEpoch;
    final rows = await db.query(
      'transactions',
      where: "source LIKE ? AND source LIKE '%screen%' AND amount_minor = ? AND $_mine AND "
          '((merchant IS ? AND ts BETWEEN ? AND ?) OR ts BETWEEN ? AND ?)',
      whereArgs: [
        '$app:%',
        amountMinor,
        merchant,
        time.subtract(window).millisecondsSinceEpoch,
        ms,
        time.subtract(near).millisecondsSinceEpoch,
        time.add(near).millisecondsSinceEpoch,
      ],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// True if this exact notification text was already recorded a few minutes ago: WeChat posts the
  /// chat notification of "Weixin Pay" again when it updates it.
  Future<bool> isRepeatedNotification({
    required String app,
    required int amountMinor,
    required String raw,
    required DateTime time,
  }) async {
    if (raw.isEmpty) return false;
    final rows = await db.query(
      'transactions',
      where: "source LIKE ? AND source LIKE '%notification%' AND amount_minor = ? AND instr(raw, ?) > 0 AND ts BETWEEN ? AND ? AND $_mine",
      whereArgs: [
        '$app:%',
        amountMinor,
        raw,
        time.subtract(const Duration(minutes: 10)).millisecondsSinceEpoch,
        time.add(const Duration(minutes: 10)).millisecondsSinceEpoch,
      ],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// The same real payment recorded another way: an auto-captured one of [appPrefix] within
  /// 3 minutes (Bills rows have minute precision), or a manual entry the same day within 30 minutes.
  Future<Txn?> findSamePayment({
    required String appPrefix,
    required TxnKind kind,
    required int amountMinor,
    required DateTime time,
  }) async {
    final ms = time.millisecondsSinceEpoch;
    final rows = await db.query(
      'transactions',
      where: '((source LIKE ? AND ts BETWEEN ? AND ?) OR (source = ? AND ts BETWEEN ? AND ?)) AND $_mine '
          'AND kind = ? AND amount_minor = ?',
      whereArgs: [
        '$appPrefix:%', ms - 180000, ms + 180000,
        'manual', ms - 1800000, ms + 1800000,
        kind.name, amountMinor,
      ],
      orderBy: 'ABS(ts - $ms)',
      limit: 1,
    );
    return rows.isEmpty ? null : Txn.fromRow(rows.first);
  }

  /// Removes WeChat transfer placeholders (amount 0) whose amount was already recorded in
  /// another row — leftovers of the prompt/answer ordering bug in v0.4.x.
  Future<int> removeAnsweredPrompts() => db.rawDelete('''
    DELETE FROM transactions
    WHERE amount_minor = 0 AND raw LIKE 'prompt:%'
      AND EXISTS (SELECT 1 FROM transactions t2
                  WHERE t2.raw = transactions.raw AND t2.amount_minor > 0 AND t2.id != transactions.id)''');

  Future<Txn?> txnById(int id) async {
    final rows = await db.query('transactions', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Txn.fromRow(rows.first);
  }

  Future<Txn?> findByRaw(String raw) async {
    final rows = await db.query('transactions', where: 'raw = ?', whereArgs: [raw], limit: 1);
    return rows.isEmpty ? null : Txn.fromRow(rows.first);
  }

  /// Last calendar day that has [kind] transactions from [source] (e.g. Excel expenses), or null.
  Future<DateTime?> lastDayOf(String source, TxnKind kind) async {
    final ms = Sqflite.firstIntValue(await db.rawQuery(
        'SELECT MAX(ts) FROM transactions WHERE source = ? AND kind = ?', [source, kind.name]));
    if (ms == null) return null;
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return DateTime(d.year, d.month, d.day);
  }

  // --- Merchant rules ---

  /// Learned category for [merchant] in this direction (income and expense rules are separate).
  Future<int?> categoryForMerchant(String merchant, TxnKind kind) async {
    final rows = await db.rawQuery('''
      SELECT r.category_id FROM merchant_rules r JOIN categories c ON c.id = r.category_id
      WHERE r.merchant = ? AND r.kind = ? AND c.archived = 0''', [merchant, kind.name]);
    return rows.isEmpty ? null : rows.first['category_id'] as int;
  }

  /// The rule's direction is the category's.
  Future<void> rememberMerchant(String merchant, int categoryId) => db.rawInsert('''
      INSERT OR REPLACE INTO merchant_rules(merchant, kind, category_id, updated_at)
      SELECT ?, kind, id, ? FROM categories WHERE id = ?''',
      [merchant, DateTime.now().millisecondsSinceEpoch, categoryId]);
}

/// Bank keys used by automatic recording (see BankParsers.kt) and the names people give such accounts.
/// Google Wallet payments (app key of their captured transactions): a card of some bank, no account.
const walletApp = 'gwallet';

const bankAliases = <String, List<String>>{
  'sber': ['сбер', 'sber'],
  'vtb': ['втб', 'vtb'],
  'tbank': ['т-банк', 'тбанк', 'т банк', 'тинькофф', 'тиньков', 'tinkoff', 't-bank', 'tbank'],
  'alfa': ['альфа', 'alfa'],
  'tochka': ['точка', 'tochka'],
  'ozon': ['озон', 'ozon'],
  'gpb': ['газпром', 'гпб', 'gazprom'],
  'yoomoney': ['юмани', 'юmoney', 'yoomoney', 'юmani'],
  'raif': ['райф', 'raif'],
  'psb': ['псб', 'psb', 'промсвязь'],
  'rshb': ['россельхоз', 'рсхб'],
  'pochta': ['почта банк', 'pochta'],
  'sovcom': ['совком', 'халва', 'sovcom'],
  'otkritie': ['открытие', 'otkritie'],
  'mts': ['мтс', 'mts'],
  'uralsib': ['уралсиб', 'uralsib'],
  'kaspi': ['kaspi', 'каспи'],
  'halyk': ['halyk', 'халык', 'халық'],
  'jusan': ['jusan', 'жусан'],
  'forte': ['forte', 'форте'],
  'bcc': ['bcc', 'бцк', 'центркредит'],
  'freedom': ['freedom', 'фридом'],
  'homecredit': ['home credit', 'хоум кредит'],
  'eurasian': ['евразийск', 'eurasian'],
  'dkb': ['dkb'],
  'sparkasse': ['sparkasse', 'spk'],
  'ing': ['ing'],
  'bunq': ['bunq'],
  'n26': ['n26'],
  'revolut': ['revolut'],
  'commerzbank': ['commerzbank'],
  'deutsche': ['deutsche bank'],
  'comdirect': ['comdirect'],
  'postbank': ['postbank'],
  'vr': ['volksbank', 'raiffeisenbank', 'vr bank', 'vr-bank'],
  'consors': ['consors'],
  'abnamro': ['abn amro', 'abn'],
  'rabobank': ['rabobank', 'rabo'],
  'sns': ['sns'],
  'asn': ['asn bank'],
  'regiobank': ['regiobank'],
  'knab': ['knab'],
  'triodos': ['triodos'],
  'targobank': ['targobank'],
  'hvb': ['hypovereinsbank', 'hvb'],
};

/// Short names that are only a bank as a whole word ("ING", not "Savings" or "Housing").
const _wholeWordAliases = {'ing', 'sns', 'abn', 'vr', 'spk', 'hvb', 'dkb', 'n26'};

/// "ВТБ", "Сбербанк", "Карта Tinkoff", "ING Girokonto" -> "vtb", "sber", "tbank", "ing"; null for other names.
String? bankKeyForName(String name) {
  final n = name.toLowerCase();
  final words = n.split(RegExp(r'[^\p{L}\p{N}]+', unicode: true)).toSet();
  for (final e in bankAliases.entries) {
    if (e.value.any((a) => _wholeWordAliases.contains(a) ? words.contains(a) : n.contains(a))) return e.key;
  }
  return null;
}
