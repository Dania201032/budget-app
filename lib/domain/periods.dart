import 'package:intl/intl.dart';

import '../data/models.dart';
import '../l10n/strings.dart';

enum PeriodType {
  day,
  week,
  month,
  year;

  String get label => tr('period_$name');
}

/// "Октябрь 2026" / "October 2026" / "2026年10月".
String monthTitle(DateTime m) {
  final s = (intlLocale == 'ru' || intlLocale == 'kk')
      ? DateFormat('LLLL y', intlLocale).format(m)
      : DateFormat.yMMMM(intlLocale).format(m);
  return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

/// A week as short as the language allows, so it fits next to the arrows:
/// "19–25 окт.", "19.–25. Okt.", "Oct 19–25", "10月19日–25日"; across months "29 сент. – 5 окт.";
/// the year only when it isn't this year.
String weekTitle(DateTime first, DateTime last, DateTime now) {
  final l = intlLocale;
  final thisYear = first.year == now.year && last.year == now.year;
  if (first.year == last.year && first.month == last.month) {
    // Is the day written before the month in this language ("19 окт.") or after ("Oct 19")?
    final pattern = (DateFormat.MMMd(l).pattern ?? '').trimLeft();
    final dayFirst = pattern.startsWith('d');
    final range = dayFirst
        // German writes the day with a dot: "19.–25. Okt."
        ? '${DateFormat.d(l).format(first)}${pattern.contains('d.') ? '.' : ''}–${DateFormat.MMMd(l).format(last)}'
        : '${DateFormat.MMMd(l).format(first)}–${DateFormat.d(l).format(last)}';
    return thisYear ? range : '$range ${DateFormat.y(l).format(last)}';
  }
  final end = thisYear ? DateFormat.MMMd(l) : DateFormat.yMMMd(l);
  return '${DateFormat.MMMd(l).format(first)} – ${end.format(last)}';
}

/// A calendar period; weeks start on Monday.
class Period {
  final PeriodType type;
  final DateTime start;

  const Period._(this.type, this.start);

  factory Period.containing(PeriodType type, DateTime d) => switch (type) {
        PeriodType.day => Period._(type, DateTime(d.year, d.month, d.day)),
        PeriodType.week => Period._(type, DateTime(d.year, d.month, d.day - (d.weekday - 1))),
        PeriodType.month => Period._(type, DateTime(d.year, d.month)),
        PeriodType.year => Period._(type, DateTime(d.year)),
      };

  DateTime get end => switch (type) {
        PeriodType.day => DateTime(start.year, start.month, start.day + 1),
        PeriodType.week => DateTime(start.year, start.month, start.day + 7),
        PeriodType.month => DateTime(start.year, start.month + 1),
        PeriodType.year => DateTime(start.year + 1),
      };

  Period shift(int n) => Period.containing(
        type,
        switch (type) {
          PeriodType.day => DateTime(start.year, start.month, start.day + n),
          PeriodType.week => DateTime(start.year, start.month, start.day + 7 * n),
          PeriodType.month => DateTime(start.year, start.month + n),
          PeriodType.year => DateTime(start.year + n),
        },
      );

  bool contains(DateTime t) => !t.isBefore(start) && t.isBefore(end);

  /// Days of the period (each as midnight).
  List<DateTime> get days => [
        for (var d = start; d.isBefore(end); d = DateTime(d.year, d.month, d.day + 1)) d,
      ];

  /// Columns of the breakdown table: days for a week/month, months for a year, none for a day.
  List<DateTime> get buckets => switch (type) {
        PeriodType.day => const [],
        PeriodType.week || PeriodType.month => days,
        PeriodType.year => [for (var m = 1; m <= 12; m++) DateTime(start.year, m)],
      };

  int bucketOf(DateTime t) => switch (type) {
        PeriodType.day => 0,
        // Calendar days via UTC, so a daylight-saving day (23/25 h) doesn't shift buckets.
        PeriodType.week || PeriodType.month =>
          DateTime.utc(t.year, t.month, t.day).difference(DateTime.utc(start.year, start.month, start.day)).inDays,
        PeriodType.year => t.month - 1,
      };

  String bucketLabel(DateTime b) => switch (type) {
        PeriodType.day => '',
        PeriodType.week => DateFormat('E d', intlLocale).format(b),
        PeriodType.month => '${b.day}',
        PeriodType.year => DateFormat.LLL(intlLocale).format(b),
      };

  String label() {
    final l = intlLocale;
    switch (type) {
      case PeriodType.day:
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final prefix = start == today
            ? '${tr('today')}, '
            : start == today.subtract(const Duration(days: 1))
                ? '${tr('yesterday')}, '
                : '${DateFormat.E(l).format(start)}, ';
        final fmt = start.year == now.year ? DateFormat.MMMMd(l) : DateFormat.yMMMMd(l);
        return prefix + fmt.format(start);
      case PeriodType.week:
        return weekTitle(start, DateTime(start.year, start.month, start.day + 6), DateTime.now());
      case PeriodType.month:
        return monthTitle(start);
      case PeriodType.year:
        return '${start.year}';
    }
  }

  @override
  bool operator ==(Object other) => other is Period && other.type == type && other.start == start;

  @override
  int get hashCode => Object.hash(type, start);
}

/// Totals for any period. Amounts are in the base currency.
class PeriodStats {
  final Period period;
  final int spentMinor;
  final int incomeMinor;

  /// Sum of daily limits of the period's days (month budget / days in that month).
  final int budgetMinor;
  final Map<int?, int> spentByCategory;

  /// category id -> spent per bucket.
  final Map<int?, List<int>> grid;
  final List<int> spentByBucket;

  /// Budget per bucket (daily limit for day buckets, month budget for month buckets).
  final List<int> budgetByBucket;

  /// Transactions in a currency we have no exchange rate for yet (not included in totals).
  final int unconvertedCount;

  /// Days of the period that have started (including today), and all days of the period.
  final int daysPassed;
  final int daysTotal;

  bool get isCurrent => period.contains(DateTime.now());

  double get averagePerDay => daysPassed == 0 ? 0 : spentMinor / daysPassed;
  double get forecastSpent => averagePerDay * daysTotal;
  double get forecastRemainder => budgetMinor - forecastSpent;

  const PeriodStats({
    required this.period,
    required this.spentMinor,
    required this.incomeMinor,
    required this.budgetMinor,
    required this.spentByCategory,
    required this.grid,
    required this.spentByBucket,
    required this.budgetByBucket,
    required this.unconvertedCount,
    required this.daysPassed,
    required this.daysTotal,
  });

  int get remainingMinor => budgetMinor - spentMinor;

  /// [toBase] converts the amount that counts (my share) to the base currency; null = no rate.
  /// [since]: the first day of bookkeeping — days before it have no budget (a year that began
  /// before the app has only the months since). [todayLimit]: today's limit as the home screen
  /// shows it (what is left ÷ the days left), for the day view of today.
  static PeriodStats compute({
    required Period period,
    required List<Txn> txns,
    required int? Function(Txn) toBase,
    required int Function(DateTime month) monthBudget,
    DateTime? now,
    DateTime? since,
    int? todayLimit,
  }) {
    final today = now ?? DateTime.now();
    final buckets = period.buckets;
    final byBucket = List<int>.filled(buckets.length, 0);
    final byCategory = <int?, int>{};
    final grid = <int?, List<int>>{};
    var spent = 0, income = 0, unconverted = 0;

    for (final t in txns) {
      if (!period.contains(t.time) || t.excluded) continue;
      final amount = toBase(t);
      if (amount == null) {
        unconverted++;
        continue;
      }
      if (t.kind == TxnKind.income) {
        income += amount;
        continue;
      }
      spent += amount;
      byCategory[t.categoryId] = (byCategory[t.categoryId] ?? 0) + amount;
      if (buckets.isNotEmpty) {
        final b = period.bucketOf(t.time);
        byBucket[b] += amount;
        grid.putIfAbsent(t.categoryId, () => List.filled(buckets.length, 0))[b] += amount;
      }
    }

    final dayStart = DateTime(today.year, today.month, today.day);
    final first = since == null ? null : DateTime(since.year, since.month, since.day);
    double dailyLimit(DateTime d) {
      if (first != null && d.isBefore(first)) return 0;
      if (todayLimit != null && period.type == PeriodType.day && d == dayStart) return todayLimit.toDouble();
      return monthBudget(DateTime(d.year, d.month)) / DateTime(d.year, d.month + 1, 0).day;
    }

    final budget = period.days.fold<double>(0, (s, d) => s + dailyLimit(d)).round();
    final budgetByBucket = [
      for (final b in buckets)
        period.type == PeriodType.year
            ? (first != null && DateTime(b.year, b.month + 1).isBefore(first.add(const Duration(days: 1)))
                ? 0
                : first != null && b.year == first.year && b.month == first.month
                    ? (monthBudget(b) * (DateTime(b.year, b.month + 1, 0).day - first.day + 1) / DateTime(b.year, b.month + 1, 0).day).round()
                    : monthBudget(b))
            : dailyLimit(b).round(),
    ];

    final days = period.days;
    final passed = days.where((d) => !d.isAfter(dayStart)).length;

    return PeriodStats(
      period: period,
      spentMinor: spent,
      incomeMinor: income,
      budgetMinor: budget,
      spentByCategory: byCategory,
      grid: grid,
      spentByBucket: byBucket,
      budgetByBucket: budgetByBucket,
      unconvertedCount: unconverted,
      daysPassed: passed,
      daysTotal: days.length,
    );
  }
}
