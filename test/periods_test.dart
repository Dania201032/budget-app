import 'package:budget_app/data/models.dart';
import 'package:budget_app/domain/periods.dart';
import 'package:budget_app/l10n/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

Txn _e(DateTime t, int minor, {int? cat}) =>
    Txn(time: t, amountMinor: minor, currency: 'CNY', kind: TxnKind.expense, categoryId: cat);

void main() {
  setUpAll(initializeDateFormatting);

  // intl puts (narrow) non-breaking spaces into dates.
  String plain(String s) => s.replaceAll(RegExp('[  ]'), ' ');

  test('weeks start on Monday and can span two months', () {
    final w = Period.containing(PeriodType.week, DateTime(2026, 10, 1, 15)); // Thursday
    expect(w.start, DateTime(2026, 9, 28));
    expect(w.end, DateTime(2026, 10, 5));
    expect(w.days, hasLength(7));
    expect(w.shift(1).start, DateTime(2026, 10, 5));
    currentLanguage = 'ru';
    expect(plain(weekTitle(w.start, DateTime(2026, 10, 4), DateTime(2026, 10, 22))), '28 сент. – 4 окт.');
    expect(plain(weekTitle(w.start, DateTime(2026, 10, 4), DateTime(2027, 1, 5))), '28 сент. – 4 окт. 2026 г.');
  });

  test('a week title is short in every language', () {
    final now = DateTime(2026, 10, 22);
    addTearDown(() => currentLanguage = 'ru');
    for (final (lang, expected) in [
      ('ru', '19–25 окт.'),
      ('en', 'Oct 19–25'),
      ('zh', '10月19日–25日'),
      ('kk', '19–25 қаз.'),
      ('de', '19.–25. Okt.'),
      ('nl', '19–25 okt'),
    ]) {
      currentLanguage = lang;
      expect(plain(weekTitle(DateTime(2026, 10, 19), DateTime(2026, 10, 25), now)), expected, reason: lang);
    }
    currentLanguage = 'ru';
  });

  test('day, month and year boundaries', () {
    final d = Period.containing(PeriodType.day, DateTime(2026, 12, 31, 23));
    expect(d.shift(1).start, DateTime(2027, 1, 1));
    final m = Period.containing(PeriodType.month, DateTime(2026, 10, 12));
    expect(m.buckets, hasLength(31));
    expect(m.label(), 'Октябрь 2026');
    final y = Period.containing(PeriodType.year, DateTime(2026, 10, 12));
    expect(y.buckets, hasLength(12));
    expect(y.bucketOf(DateTime(2026, 10, 12)), 9);
    expect(y.shift(-1).label(), '2025');
  });

  test('week budget sums daily limits of both months', () {
    final w = Period.containing(PeriodType.week, DateTime(2026, 10, 1));
    final s = PeriodStats.compute(
      period: w,
      txns: [_e(DateTime(2026, 9, 29, 10), 5000, cat: 1), _e(DateTime(2026, 10, 2, 10), 2000, cat: 1)],
      toBase: (t) => t.amountMinor,
      // September 3000/30 = 100 per day, October 3100/31 = 100 per day.
      monthBudget: (m) => m.month == 9 ? 300000 : 310000,
    );
    expect(s.budgetMinor, 70000);
    expect(s.spentMinor, 7000);
    expect(s.spentByBucket, [0, 5000, 0, 0, 2000, 0, 0]);
    expect(s.grid[1], [0, 5000, 0, 0, 2000, 0, 0]);
    expect(s.budgetByBucket.every((b) => b == 10000), isTrue);
  });

  test('year buckets are months with month budgets', () {
    final y = Period.containing(PeriodType.year, DateTime(2026, 5, 1));
    final s = PeriodStats.compute(
      period: y,
      txns: [_e(DateTime(2026, 10, 12), 118583), _e(DateTime(2025, 12, 31), 999)],
      toBase: (t) => t.amountMinor,
      monthBudget: (_) => 300000,
    );
    expect(s.budgetMinor, 3600000);
    expect(s.spentByBucket[9], 118583);
    expect(s.spentMinor, 118583);
    expect(s.budgetByBucket[0], 300000);
  });

  test('transactions without a rate are counted separately', () {
    final s = PeriodStats.compute(
      period: Period.containing(PeriodType.day, DateTime(2026, 10, 12)),
      txns: [_e(DateTime(2026, 10, 12, 9), 100), Txn(time: DateTime(2026, 10, 12, 10), amountMinor: 50000, currency: 'RUB', kind: TxnKind.expense)],
      toBase: (t) => t.currency == 'CNY' ? t.amountMinor : null,
      monthBudget: (_) => 310000,
    );
    expect(s.spentMinor, 100);
    expect(s.unconvertedCount, 1);
    expect(s.budgetMinor, 10000);
  });
}
