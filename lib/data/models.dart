enum TxnKind {
  expense,
  income;

  static TxnKind parse(String s) => TxnKind.values.firstWhere((k) => k.name == s, orElse: () => TxnKind.expense);
}

class Category {
  final int id;
  final String name;

  /// Built-in categories have a key ("food", "transport"…) and are shown translated;
  /// renaming a category clears the key.
  final String? key;
  final String icon;
  final int color;
  final TxnKind kind;
  final int sort;
  final bool archived;

  const Category({
    required this.id,
    required this.name,
    this.key,
    required this.icon,
    required this.color,
    required this.kind,
    this.sort = 0,
    this.archived = false,
  });

  factory Category.fromRow(Map<String, Object?> r) => Category(
        id: r['id'] as int,
        name: r['name'] as String,
        key: r['key'] as String?,
        icon: r['icon'] as String,
        color: r['color'] as int,
        kind: TxnKind.parse(r['kind'] as String),
        sort: r['sort'] as int,
        archived: (r['archived'] as int) == 1,
      );
}

/// Where the money lives: Alipay, WeChat, cash, a bank card.
class Account {
  final int id;
  final String name;

  /// Built-in "cash" account is shown translated.
  final String? key;
  final String currency;

  /// alipay | wechat | cash | bank | sber | tbank | kaspi … (bank accounts are matched by this)
  final String type;

  /// Balance the user entered ("сверка") and when; the current balance adds later transactions.
  final int? balanceMinor;
  final DateTime? balanceAt;

  /// Shared budget: whose account it is (a person's uid; null = common to everyone), and whether
  /// the others can't see it at all (it then never reaches their devices).
  final String? owner;
  final bool hidden;

  const Account({
    required this.id,
    required this.name,
    this.key,
    required this.currency,
    required this.type,
    this.balanceMinor,
    this.balanceAt,
    this.owner,
    this.hidden = false,
  });

  factory Account.fromRow(Map<String, Object?> r) => Account(
        id: r['id'] as int,
        name: r['name'] as String,
        key: r['key'] as String?,
        currency: r['currency'] as String,
        type: r['type'] as String,
        balanceMinor: r['balance_minor'] as int?,
        balanceAt: r['balance_at'] == null ? null : DateTime.fromMillisecondsSinceEpoch(r['balance_at'] as int),
        owner: r['owner'] as String?,
        hidden: (r['private'] as int? ?? 0) == 1,
      );
}

/// Someone sharing the budget (see lib/household/).
class Person {
  final int id;
  final String uid;
  final String name;
  final int color;
  const Person({required this.id, required this.uid, required this.name, this.color = 0});

  factory Person.fromRow(Map<String, Object?> r) =>
      Person(id: r['id'] as int, uid: r['uid'] as String? ?? '', name: r['name'] as String, color: r['color'] as int? ?? 0);

  String get initial => name.trim().isEmpty ? '?' : String.fromCharCode(name.trim().runes.first).toUpperCase();
}

class Txn {
  final int? id;
  final DateTime time;

  /// Amount actually paid/received in minor units (fen / kopecks), always positive; [kind] gives the direction.
  final int amountMinor;

  /// My part of a bill split with friends; budgets and stats use it instead of [amountMinor].
  final int? shareMinor;

  /// Not counted in stats at all (e.g. a friend paying back a debt). Account balances still move.
  final bool excluded;
  final String currency;
  final TxnKind kind;
  final int? categoryId;
  final int? accountId;
  final String? merchant;
  final String? note;

  /// "manual", "excel", or for auto-captured payments `app:screen`, `app:notification+screen`, `app:bill`…
  final String source;

  /// Auto-captured and not yet confirmed/categorized by the user.
  final bool needsReview;
  final String? raw;

  /// Money moved between my own accounts (VTB → Sber): never spending or income, but balances move.
  /// Always [excluded] as well; [pairId] is the other side when both were recorded.
  final bool ownTransfer;
  final int? pairId;

  /// Shared budget: the person (uid) who recorded it, null before the budget was shared.
  final String? author;

  /// Paid from the savings of this goal ("close a goal"): not spending of the month's budget.
  final int? goalId;

  const Txn({
    this.id,
    required this.time,
    required this.amountMinor,
    this.shareMinor,
    this.excluded = false,
    required this.currency,
    required this.kind,
    this.categoryId,
    this.accountId,
    this.merchant,
    this.note,
    this.source = 'manual',
    this.needsReview = false,
    this.raw,
    this.ownTransfer = false,
    this.pairId,
    this.author,
    this.goalId,
  });

  /// Auto-captured from payment apps / bank notifications (not manual, not imported from a spreadsheet).
  bool get isCaptured => source != 'manual' && source != 'excel';

  /// The amount that counts for budgets and stats.
  int get effectiveMinor => shareMinor ?? amountMinor;

  bool get isSplit => shareMinor != null && shareMinor != amountMinor;

  factory Txn.fromRow(Map<String, Object?> r) => Txn(
        id: r['id'] as int,
        time: DateTime.fromMillisecondsSinceEpoch(r['ts'] as int),
        amountMinor: r['amount_minor'] as int,
        shareMinor: r['share_minor'] as int?,
        excluded: (r['excluded'] as int? ?? 0) == 1,
        currency: r['currency'] as String,
        kind: TxnKind.parse(r['kind'] as String),
        categoryId: r['category_id'] as int?,
        accountId: r['account_id'] as int?,
        merchant: r['merchant'] as String?,
        note: r['note'] as String?,
        source: r['source'] as String,
        needsReview: (r['needs_review'] as int) == 1,
        raw: r['raw'] as String?,
        ownTransfer: (r['own_transfer'] as int? ?? 0) == 1,
        pairId: r['pair_id'] as int?,
        author: r['author'] as String?,
        goalId: r['goal_id'] as int?,
      );

  Map<String, Object?> toRow() => {
        if (id != null) 'id': id,
        'ts': time.millisecondsSinceEpoch,
        'amount_minor': amountMinor,
        'share_minor': shareMinor,
        'excluded': excluded ? 1 : 0,
        'currency': currency,
        'kind': kind.name,
        'category_id': categoryId,
        'account_id': accountId,
        'merchant': merchant,
        'note': note,
        'source': source,
        'needs_review': needsReview ? 1 : 0,
        'raw': raw,
        'own_transfer': ownTransfer ? 1 : 0,
        'pair_id': pairId,
        'author': author,
        'goal_id': goalId,
      };

  Txn copyWith({
    DateTime? time,
    int? amountMinor,
    int? Function()? shareMinor,
    bool? excluded,
    String? currency,
    TxnKind? kind,
    int? Function()? categoryId,
    int? Function()? accountId,
    String? Function()? merchant,
    String? Function()? note,
    String? source,
    bool? needsReview,
    String? raw,
    bool? ownTransfer,
    int? Function()? pairId,
    int? Function()? goalId,
  }) =>
      Txn(
        id: id,
        time: time ?? this.time,
        amountMinor: amountMinor ?? this.amountMinor,
        shareMinor: shareMinor != null ? shareMinor() : this.shareMinor,
        excluded: excluded ?? this.excluded,
        currency: currency ?? this.currency,
        kind: kind ?? this.kind,
        categoryId: categoryId != null ? categoryId() : this.categoryId,
        accountId: accountId != null ? accountId() : this.accountId,
        merchant: merchant != null ? merchant() : this.merchant,
        note: note != null ? note() : this.note,
        source: source ?? this.source,
        needsReview: needsReview ?? this.needsReview,
        raw: raw ?? this.raw,
        ownTransfer: ownTransfer ?? this.ownTransfer,
        pairId: pairId != null ? pairId() : this.pairId,
        author: author,
        goalId: goalId != null ? goalId() : this.goalId,
      );
}

/// Savings goal. [reserve] = the monthly amount needed is taken out of the spending budget.
class Goal {
  final int id;
  final String name;
  final int targetMinor;
  final int savedMinor;
  final String currency;
  final DateTime? deadline;
  final bool reserve;
  final DateTime createdAt;

  /// Account where the savings live (optional): suggested when putting money aside or taking it out.
  final int? accountId;

  const Goal({
    required this.id,
    required this.name,
    required this.targetMinor,
    required this.savedMinor,
    required this.currency,
    this.deadline,
    this.reserve = true,
    required this.createdAt,
    this.accountId,
  });

  factory Goal.fromRow(Map<String, Object?> r) => Goal(
        id: r['id'] as int,
        name: r['name'] as String,
        targetMinor: r['target_minor'] as int,
        savedMinor: r['saved_minor'] as int,
        currency: r['currency'] as String,
        deadline: r['deadline'] == null ? null : DateTime.fromMillisecondsSinceEpoch(r['deadline'] as int),
        reserve: (r['reserve'] as int) == 1,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
        accountId: r['account_id'] as int?,
      );

  int get leftMinor => (targetMinor - savedMinor).clamp(0, targetMinor);
  double get progress => targetMinor == 0 ? 1 : (savedMinor / targetMinor).clamp(0, 1);
  bool get done => savedMinor >= targetMinor;

  /// Months left until the deadline, counting the current month (at least 1).
  int monthsLeft(DateTime now) {
    final d = deadline;
    if (d == null) return 0;
    final m = (d.year - now.year) * 12 + d.month - now.month + 1;
    return m < 1 ? 1 : m;
  }

  /// How much to put aside per month to reach the target by the deadline (0 without a deadline).
  int monthlyNeed(DateTime now) {
    if (done || deadline == null) return 0;
    return (leftMinor / monthsLeft(now)).ceil();
  }

  /// Whether the goal takes money out of [month]'s budget.
  bool reservesIn(DateTime month) {
    final d = deadline;
    if (!reserve || done || d == null) return false;
    final m = DateTime(month.year, month.month);
    return !m.isBefore(DateTime(createdAt.year, createdAt.month)) && !m.isAfter(DateTime(d.year, d.month));
  }
}

/// A friend's part of a bill I paid. [person] null = unnamed (settled by an incoming transfer of the same amount).
class Debt {
  final int id;
  final int? txnId;
  final String? person;
  final int amountMinor;
  final int settledMinor;
  final String currency;
  final DateTime createdAt;

  const Debt({
    required this.id,
    this.txnId,
    this.person,
    required this.amountMinor,
    required this.settledMinor,
    required this.currency,
    required this.createdAt,
  });

  factory Debt.fromRow(Map<String, Object?> r) => Debt(
        id: r['id'] as int,
        txnId: r['txn_id'] as int?,
        person: r['person'] as String?,
        amountMinor: r['amount_minor'] as int,
        settledMinor: r['settled_minor'] as int,
        currency: r['currency'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      );

  int get openMinor => amountMinor - settledMinor;
  bool get settled => openMinor <= 0;
}

enum Every {
  week,
  month,
  year;

  static Every parse(String s) => Every.values.firstWhere((e) => e.name == s, orElse: () => Every.month);
}

/// A regular payment or income (rent, a subscription, a stipend): shown as "soon" on the home
/// screen, reminded about on the day, and counted in the forecast.
class Recurring {
  final int? id;
  final String name;
  final int amountMinor;
  final String currency;
  final TxnKind kind;
  final int? categoryId;
  final int? accountId;
  final Every every;

  /// Day of the month (1–31; the last day in shorter months) for monthly and yearly ones.
  final int day;

  /// The next date it is due (local midnight).
  final DateTime next;
  final bool remind;

  const Recurring({
    this.id,
    required this.name,
    required this.amountMinor,
    required this.currency,
    required this.kind,
    this.categoryId,
    this.accountId,
    required this.every,
    required this.day,
    required this.next,
    this.remind = true,
  });

  factory Recurring.fromRow(Map<String, Object?> r) => Recurring(
        id: r['id'] as int,
        name: r['name'] as String,
        amountMinor: r['amount_minor'] as int,
        currency: r['currency'] as String,
        kind: TxnKind.parse(r['kind'] as String),
        categoryId: r['category_id'] as int?,
        accountId: r['account_id'] as int?,
        every: Every.parse(r['every'] as String),
        day: r['day'] as int,
        next: DateTime.fromMillisecondsSinceEpoch(r['next_ts'] as int),
        remind: (r['remind'] as int) == 1,
      );

  Map<String, Object?> toRow() => {
        if (id != null) 'id': id,
        'name': name,
        'amount_minor': amountMinor,
        'currency': currency,
        'kind': kind.name,
        'category_id': categoryId,
        'account_id': accountId,
        'every': every.name,
        'day': day,
        'next_ts': next.millisecondsSinceEpoch,
        'remind': remind ? 1 : 0,
      };

  /// The due date after [from] (which is one of its due dates).
  DateTime after(DateTime from) {
    DateTime clamp(int y, int m) {
      final last = DateTime(y, m + 1, 0).day;
      return DateTime(y, m, day < last ? day : last);
    }

    return switch (every) {
      Every.week => DateTime(from.year, from.month, from.day + 7),
      Every.month => clamp(from.year, from.month + 1),
      Every.year => clamp(from.year + 1, from.month),
    };
  }

  /// Due dates from [next] up to [until] (inclusive).
  Iterable<DateTime> occurrences(DateTime until) sync* {
    var d = next;
    for (var i = 0; i < 1000 && !d.isAfter(until); i++) {
      yield d;
      d = after(d);
    }
  }

  Recurring copyWith({String? name, int? amountMinor, String? currency, TxnKind? kind, int? Function()? categoryId,
          int? Function()? accountId, Every? every, int? day, DateTime? next, bool? remind}) =>
      Recurring(
        id: id,
        name: name ?? this.name,
        amountMinor: amountMinor ?? this.amountMinor,
        currency: currency ?? this.currency,
        kind: kind ?? this.kind,
        categoryId: categoryId != null ? categoryId() : this.categoryId,
        accountId: accountId != null ? accountId() : this.accountId,
        every: every ?? this.every,
        day: day ?? this.day,
        next: next ?? this.next,
        remind: remind ?? this.remind,
      );
}
