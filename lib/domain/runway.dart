import 'dart:convert';

/// "How long will my money last": settings the user can change, with sensible defaults.
enum SpendMode { average, budget, custom }

enum IncomeMode { none, average, custom }

/// A one-off planned income (+) or expense (−), e.g. "Tuition −5 000 in January", "Scholarship +3 000".
class PlannedItem {
  final String name;
  final int amountMinor;
  final DateTime date;
  const PlannedItem({required this.name, required this.amountMinor, required this.date});

  Map<String, Object?> toJson() => {'name': name, 'amount': amountMinor, 'date': date.millisecondsSinceEpoch};

  factory PlannedItem.fromJson(Map<String, dynamic> j) => PlannedItem(
        name: j['name'] as String? ?? '',
        amountMinor: (j['amount'] as num).toInt(),
        date: DateTime.fromMillisecondsSinceEpoch((j['date'] as num).toInt()),
      );
}

class RunwayConfig {
  /// Accounts whose balances count; null = every account with a balance set.
  final Set<int>? accountIds;

  /// Money already put aside for goals counts as available.
  final bool includeGoalSavings;

  /// Money the app doesn't track (cash at home, a deposit…), in base currency.
  final int extraMinor;

  final SpendMode spendMode;

  /// Window for the average: last N days.
  final int averageDays;
  final int customSpendPerMonthMinor;

  /// Categories left out of the average (e.g. a one-time trip).
  final Set<int> excludedCategories;

  /// "What if I spend X% less/more": −50…+50.
  final int adjustPercent;

  final IncomeMode incomeMode;
  final int customIncomePerMonthMinor;

  /// Untouchable reserve: the money "runs out" when the balance reaches it.
  final int reserveMinor;
  /// Regular payments and incomes (rent, stipend) count as planned items.
  final bool useRecurring;
  final List<PlannedItem> planned;
  final int horizonMonths;

  /// "Make it last until…" date.
  final DateTime? targetDate;

  const RunwayConfig({
    this.accountIds,
    this.includeGoalSavings = false,
    this.extraMinor = 0,
    this.spendMode = SpendMode.average,
    this.averageDays = 30,
    this.customSpendPerMonthMinor = 0,
    this.excludedCategories = const {},
    this.adjustPercent = 0,
    this.incomeMode = IncomeMode.none,
    this.customIncomePerMonthMinor = 0,
    this.reserveMinor = 0,
    this.useRecurring = true,
    this.planned = const [],
    this.horizonMonths = 12,
    this.targetDate,
  });

  RunwayConfig copyWith({
    Set<int>? Function()? accountIds,
    bool? includeGoalSavings,
    int? extraMinor,
    SpendMode? spendMode,
    int? averageDays,
    int? customSpendPerMonthMinor,
    Set<int>? excludedCategories,
    int? adjustPercent,
    IncomeMode? incomeMode,
    int? customIncomePerMonthMinor,
    int? reserveMinor,
    bool? useRecurring,
    List<PlannedItem>? planned,
    int? horizonMonths,
    DateTime? Function()? targetDate,
  }) =>
      RunwayConfig(
        accountIds: accountIds != null ? accountIds() : this.accountIds,
        includeGoalSavings: includeGoalSavings ?? this.includeGoalSavings,
        extraMinor: extraMinor ?? this.extraMinor,
        spendMode: spendMode ?? this.spendMode,
        averageDays: averageDays ?? this.averageDays,
        customSpendPerMonthMinor: customSpendPerMonthMinor ?? this.customSpendPerMonthMinor,
        excludedCategories: excludedCategories ?? this.excludedCategories,
        adjustPercent: adjustPercent ?? this.adjustPercent,
        incomeMode: incomeMode ?? this.incomeMode,
        customIncomePerMonthMinor: customIncomePerMonthMinor ?? this.customIncomePerMonthMinor,
        reserveMinor: reserveMinor ?? this.reserveMinor,
        useRecurring: useRecurring ?? this.useRecurring,
        planned: planned ?? this.planned,
        horizonMonths: horizonMonths ?? this.horizonMonths,
        targetDate: targetDate != null ? targetDate() : this.targetDate,
      );

  String toJsonString() => jsonEncode({
        'accounts': accountIds?.toList(),
        'goals': includeGoalSavings,
        'extra': extraMinor,
        'spendMode': spendMode.name,
        'avgDays': averageDays,
        'customSpend': customSpendPerMonthMinor,
        'excluded': excludedCategories.toList(),
        'adjust': adjustPercent,
        'incomeMode': incomeMode.name,
        'customIncome': customIncomePerMonthMinor,
        'reserve': reserveMinor,
        'recurring': useRecurring,
        'planned': [for (final p in planned) p.toJson()],
        'horizon': horizonMonths,
        'target': targetDate?.millisecondsSinceEpoch,
      });

  factory RunwayConfig.fromJsonString(String? s) {
    if (s == null || s.isEmpty) return const RunwayConfig();
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      return RunwayConfig(
        accountIds: (j['accounts'] as List?)?.map((e) => (e as num).toInt()).toSet(),
        includeGoalSavings: j['goals'] == true,
        extraMinor: (j['extra'] as num?)?.toInt() ?? 0,
        spendMode: SpendMode.values.firstWhere((m) => m.name == j['spendMode'], orElse: () => SpendMode.average),
        averageDays: (j['avgDays'] as num?)?.toInt() ?? 30,
        customSpendPerMonthMinor: (j['customSpend'] as num?)?.toInt() ?? 0,
        excludedCategories: ((j['excluded'] as List?) ?? const []).map((e) => (e as num).toInt()).toSet(),
        adjustPercent: (j['adjust'] as num?)?.toInt() ?? 0,
        incomeMode: IncomeMode.values.firstWhere((m) => m.name == j['incomeMode'], orElse: () => IncomeMode.none),
        customIncomePerMonthMinor: (j['customIncome'] as num?)?.toInt() ?? 0,
        reserveMinor: (j['reserve'] as num?)?.toInt() ?? 0,
        useRecurring: j['recurring'] != false,
        planned: [for (final p in (j['planned'] as List? ?? const [])) PlannedItem.fromJson(p as Map<String, dynamic>)],
        horizonMonths: (j['horizon'] as num?)?.toInt() ?? 12,
        targetDate: j['target'] == null ? null : DateTime.fromMillisecondsSinceEpoch((j['target'] as num).toInt()),
      );
    } catch (_) {
      return const RunwayConfig();
    }
  }
}

class RunwayPoint {
  final DateTime day;
  final int balanceMinor;
  const RunwayPoint(this.day, this.balanceMinor);
}

class RunwayResult {
  final int startMinor;

  /// Spending and income per day used for the projection (after the % adjustment).
  final double spendPerDay;
  final double incomePerDay;

  /// First day the balance drops below the reserve; null = lasts longer than [maxYears].
  final DateTime? runsOutOn;

  /// Daily balance for the chart horizon.
  final List<RunwayPoint> projection;

  /// Max spending per day so the money (minus the reserve) lasts until the target date.
  final double? allowedPerDayForTarget;
  final int daysToTarget;

  const RunwayResult({
    required this.startMinor,
    required this.spendPerDay,
    required this.incomePerDay,
    required this.runsOutOn,
    required this.projection,
    required this.allowedPerDayForTarget,
    required this.daysToTarget,
  });

  int? daysLeft(DateTime today) =>
      runsOutOn == null ? null : DateTime.utc(runsOutOn!.year, runsOutOn!.month, runsOutOn!.day)
          .difference(DateTime.utc(today.year, today.month, today.day))
          .inDays;
}

const maxYears = 30;

/// Day-by-day projection: balance − spending + income, with planned one-offs on their dates.
RunwayResult computeRunway({
  required RunwayConfig config,
  required int startMinor,
  required double baseSpendPerDay,
  required double baseIncomePerDay,
  required DateTime now,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final spend = baseSpendPerDay * (100 + config.adjustPercent) / 100;
  final income = baseIncomePerDay;

  final plannedByDay = <DateTime, int>{};
  for (final p in config.planned) {
    final d = DateTime(p.date.year, p.date.month, p.date.day);
    if (d.isBefore(today)) continue;
    plannedByDay[d] = (plannedByDay[d] ?? 0) + p.amountMinor;
  }

  final horizonEnd = DateTime(today.year, today.month + config.horizonMonths, today.day);
  final points = <RunwayPoint>[RunwayPoint(today, startMinor)];
  var balance = startMinor.toDouble() + (plannedByDay[today] ?? 0);
  DateTime? runsOut = balance < config.reserveMinor ? today : null;
  final limit = DateTime(today.year + maxYears, today.month, today.day);
  var day = today;
  while (day.isBefore(limit)) {
    day = DateTime(day.year, day.month, day.day + 1);
    balance += income - spend + (plannedByDay[day] ?? 0);
    if (!day.isAfter(horizonEnd)) points.add(RunwayPoint(day, balance.round()));
    if (runsOut == null && balance < config.reserveMinor) runsOut = day;
    // Nothing more to learn once it ran out and the chart horizon is filled.
    if (runsOut != null && day.isAfter(horizonEnd)) break;
    // Never runs out when the net flow is not negative and no planned expense is ahead.
    if (runsOut == null && income >= spend && day.isAfter(horizonEnd) &&
        plannedByDay.keys.every((d) => !d.isAfter(day))) {
      break;
    }
  }

  double? allowed;
  var daysToTarget = 0;
  final target = config.targetDate;
  if (target != null) {
    final t = DateTime(target.year, target.month, target.day);
    daysToTarget = DateTime.utc(t.year, t.month, t.day).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
    if (daysToTarget > 0) {
      final plannedBefore = plannedByDay.entries.where((e) => !e.key.isAfter(t)).fold<int>(0, (s, e) => s + e.value);
      allowed = (startMinor - config.reserveMinor + income * daysToTarget + plannedBefore) / daysToTarget;
    }
  }

  return RunwayResult(
    startMinor: startMinor,
    spendPerDay: spend,
    incomePerDay: income,
    runsOutOn: runsOut,
    projection: points,
    allowedPerDayForTarget: allowed,
    daysToTarget: daysToTarget,
  );
}
