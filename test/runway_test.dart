import 'package:budget_app/domain/runway.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 14, 10);

  test('steady spending: 10 000 at 100/day lasts 100 days', () {
    final r = computeRunway(
        config: const RunwayConfig(), startMinor: 1000000, baseSpendPerDay: 10000, baseIncomePerDay: 0, now: now);
    expect(r.runsOutOn, DateTime(2026, 10, 14).add(const Duration(days: 101)));
    expect(r.daysLeft(now), 101);
    expect(r.projection.first.balanceMinor, 1000000);
  });

  test('reserve, % adjustment and planned items', () {
    final r = computeRunway(
      config: RunwayConfig(
        reserveMinor: 200000,
        adjustPercent: -20, // 100/day -> 80/day
        planned: [PlannedItem(name: 'Scholarship', amountMinor: 160000, date: DateTime(2026, 10, 20))],
      ),
      startMinor: 1000000,
      baseSpendPerDay: 10000,
      baseIncomePerDay: 0,
      now: now,
    );
    expect(r.spendPerDay, 8000);
    // (10 000 − 2 000 + 1 600) / 80 = 120 days -> drops below the reserve on day 121.
    expect(r.daysLeft(now), 121);
  });

  test('income covering spending never runs out', () {
    final r = computeRunway(
        config: const RunwayConfig(horizonMonths: 6), startMinor: 100, baseSpendPerDay: 5000, baseIncomePerDay: 6000, now: now);
    expect(r.runsOutOn, isNull);
    expect(r.projection.last.day, DateTime(2027, 4, 14));
  });

  test('allowed spending to last until a date', () {
    final r = computeRunway(
      config: RunwayConfig(targetDate: DateTime(2026, 11, 13), reserveMinor: 100000),
      startMinor: 400000,
      baseSpendPerDay: 20000,
      baseIncomePerDay: 0,
      now: now,
    );
    expect(r.daysToTarget, 30);
    expect(r.allowedPerDayForTarget, closeTo(10000, 0.01)); // (4 000 − 1 000) / 30 days
  });

  test('settings survive save/load and bad JSON falls back to defaults', () {
    final c = RunwayConfig(
      accountIds: {1, 3},
      includeGoalSavings: true,
      spendMode: SpendMode.custom,
      customSpendPerMonthMinor: 300000,
      excludedCategories: {7},
      incomeMode: IncomeMode.average,
      planned: [PlannedItem(name: 'Tuition', amountMinor: -500000, date: DateTime(2027, 1, 10))],
      targetDate: DateTime(2027, 6, 30),
    );
    final back = RunwayConfig.fromJsonString(c.toJsonString());
    expect(back.accountIds, {1, 3});
    expect(back.spendMode, SpendMode.custom);
    expect(back.planned.single.amountMinor, -500000);
    expect(back.targetDate, DateTime(2027, 6, 30));
    expect(RunwayConfig.fromJsonString('{oops').spendMode, SpendMode.average);
  });
}
