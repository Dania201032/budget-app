import '../data/models.dart';

/// Month budget numbers, same logic as the user's spreadsheet
/// (daily limit = budget / days, running balance, "can spend per day from tomorrow", forecast).
class MonthStats {
  final DateTime month;
  final int budgetMinor;
  final int daysInMonth;

  /// Days elapsed including today (0 for a future month, all days for a past month).
  final int daysPassed;
  final int spentMinor;
  final int spentTodayMinor;
  final int incomeMinor;

  /// Expense sum per day of month (index 0 = day 1).
  final List<int> spentByDay;

  /// Expense sum per category id (null key = uncategorized).
  final Map<int?, int> spentByCategory;

  const MonthStats({
    required this.month,
    required this.budgetMinor,
    required this.daysInMonth,
    required this.daysPassed,
    required this.spentMinor,
    required this.spentTodayMinor,
    required this.incomeMinor,
    required this.spentByDay,
    required this.spentByCategory,
    required this.isCurrentMonth,
    this.fixedDaily = false,
  });

  final bool isCurrentMonth;

  /// The day's limit is always budget ÷ days in the month (the user's choice), instead of what is
  /// left of the budget ÷ the days left.
  final bool fixedDaily;

  double get dailyLimit => daysInMonth == 0 ? 0 : budgetMinor / daysInMonth;
  int get remainingMinor => budgetMinor - spentMinor;
  int get daysLeftAfterToday => daysInMonth - daysPassed;

  /// "Остаток нарастающим итогом": how far ahead (+) or behind (−) of the even daily pace we are.
  double get runningBalance => daysPassed * dailyLimit - spentMinor;

  /// What can be spent today: the usual daily limit, or (by default) the share that leaves the rest
  /// of the month an equal amount per day.
  double get todayAllowance => fixedDaily ? dailyLimit : evenAllowance;

  /// Budget left ÷ days left, today included.
  double get evenAllowance {
    final daysLeftInclToday = daysInMonth - daysPassed + 1;
    if (daysLeftInclToday <= 0) return 0;
    return (budgetMinor - (spentMinor - spentTodayMinor)) / daysLeftInclToday;
  }

  double get todayLeft => todayAllowance - spentTodayMinor;

  /// "Можно тратить в день (с завтра)".
  double get perDayFromTomorrow => daysLeftAfterToday > 0 ? remainingMinor / daysLeftAfterToday : 0;

  double get averagePerDay => daysPassed > 0 ? spentMinor / daysPassed : 0;
  double get forecastSpent => averagePerDay * daysInMonth;
  double get forecastRemainder => budgetMinor - forecastSpent;

  /// [toBase] converts a transaction to the base currency (null = no rate yet, skipped);
  /// by default only base-currency transactions count.
  static MonthStats compute({
    required DateTime month,
    required DateTime now,
    required int budgetMinor,
    required List<Txn> txns,
    required String baseCurrency,
    int? Function(Txn)? toBase,
    bool fixedDaily = false,
  }) {
    final convert = toBase ?? (Txn t) => t.currency == baseCurrency ? t.effectiveMinor : null;
    final first = DateTime(month.year, month.month);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final today = DateTime(now.year, now.month, now.day);

    final isCurrent = today.year == first.year && today.month == first.month;
    int daysPassed;
    if (today.isBefore(first)) {
      daysPassed = 0;
    } else if (isCurrent) {
      daysPassed = today.day;
    } else {
      daysPassed = daysInMonth;
    }

    final byDay = List<int>.filled(daysInMonth, 0);
    final byCategory = <int?, int>{};
    var spent = 0, spentToday = 0, income = 0;
    for (final t in txns) {
      if (t.time.year != first.year || t.time.month != first.month || t.excluded) continue;
      final amount = convert(t);
      if (amount == null) continue;
      if (t.kind == TxnKind.income) {
        income += amount;
        continue;
      }
      spent += amount;
      byDay[t.time.day - 1] += amount;
      byCategory[t.categoryId] = (byCategory[t.categoryId] ?? 0) + amount;
      if (t.time.year == today.year && t.time.month == today.month && t.time.day == today.day) {
        spentToday += amount;
      }
    }

    return MonthStats(
      month: first,
      budgetMinor: budgetMinor,
      daysInMonth: daysInMonth,
      daysPassed: daysPassed,
      spentMinor: spent,
      spentTodayMinor: spentToday,
      incomeMinor: income,
      spentByDay: byDay,
      spentByCategory: byCategory,
      isCurrentMonth: isCurrent,
      fixedDaily: fixedDaily,
    );
  }
}
