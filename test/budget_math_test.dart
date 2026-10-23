import 'package:budget_app/data/models.dart';
import 'package:budget_app/domain/budget_math.dart';
import 'package:flutter_test/flutter_test.dart';

Txn _expense(int day, double amount, {int? categoryId, String currency = 'CNY'}) => Txn(
      time: DateTime(2026, 10, day, 12),
      amountMinor: (amount * 100).round(),
      currency: currency,
      kind: TxnKind.expense,
      categoryId: categoryId,
    );

void main() {
  // Daily totals from the user's sheet "Расходы (октябрь)", days 1–12, budget 3000.
  const octoberDaily = <double>[105.6, 378.5, 186.34, 49.3, 107.19, 28, 52.4, 44.5, 42.5, 82, 77, 32.5];
  final txns = [for (var i = 0; i < octoberDaily.length; i++) _expense(i + 1, octoberDaily[i])];

  MonthStats stats({List<Txn>? list}) => MonthStats.compute(
        month: DateTime(2026, 10),
        now: DateTime(2026, 10, 12, 20),
        budgetMinor: 300000,
        txns: list ?? txns,
        baseCurrency: 'CNY',
      );

  test('matches the spreadsheet summary on Oct 12', () {
    final s = stats();
    expect(s.daysInMonth, 31);
    expect(s.daysPassed, 12);
    expect(s.spentMinor, 118583); // Потрачено 1185.83
    expect(s.remainingMinor, 181417); // Остаток 1814.17
    expect(s.daysLeftAfterToday, 19);
    expect(s.perDayFromTomorrow / 100, closeTo(95.4826, 0.001)); // Можно тратить в день (с завтра)
    expect(s.averagePerDay / 100, closeTo(98.8192, 0.001)); // Средний расход в день
    expect(s.forecastSpent / 100, closeTo(3063.394, 0.01)); // Прогноз расходов на месяц
    expect(s.forecastRemainder / 100, closeTo(-63.394, 0.01)); // Прогноз остатка
    expect(s.runningBalance / 100, closeTo(-24.5397, 0.001)); // Остаток нарастающим итогом, день 12
    expect(s.dailyLimit / 100, closeTo(96.7742, 0.001));
  });

  test('today allowance spreads what was left this morning over the remaining days', () {
    final s = stats();
    // Before today: 1185.83 − 32.5 = 1153.33 spent; (3000 − 1153.33) / 20 days.
    expect(s.todayAllowance / 100, closeTo(92.3335, 0.001));
    expect(s.todayLeft / 100, closeTo(59.8335, 0.001));
  });

  test('the usual daily limit, if chosen, is the same every day', () {
    final s = MonthStats.compute(
      month: DateTime(2026, 10),
      now: DateTime(2026, 10, 12, 20),
      budgetMinor: 300000,
      txns: txns,
      baseCurrency: 'CNY',
      fixedDaily: true,
    );
    // 3000 / 31, whatever was spent on the days before.
    expect(s.todayAllowance / 100, closeTo(96.7742, 0.001));
    expect(s.todayLeft / 100, closeTo(64.2742, 0.001));
    // The other way stays at hand for the hint on Home.
    expect(s.evenAllowance / 100, closeTo(92.3335, 0.001));
  });

  test('income and other currencies do not count as spending', () {
    final s = stats(list: [
      ...txns,
      Txn(time: DateTime(2026, 10, 5), amountMinor: 500000, currency: 'CNY', kind: TxnKind.income),
      _expense(6, 1000, currency: 'RUB'),
    ]);
    expect(s.spentMinor, 118583);
    expect(s.incomeMinor, 500000);
  });

  test('groups spending by category and day', () {
    final s = stats(list: [_expense(3, 10, categoryId: 1), _expense(3, 5, categoryId: 2), _expense(4, 1)]);
    expect(s.spentByCategory, {1: 1000, 2: 500, null: 100});
    expect(s.spentByDay[2], 1500);
    expect(s.spentByDay[3], 100);
  });

  test('past and future months', () {
    final past = MonthStats.compute(
        month: DateTime(2026, 9), now: DateTime(2026, 10, 12), budgetMinor: 300000, txns: const [], baseCurrency: 'CNY');
    expect(past.daysPassed, 30);
    expect(past.isCurrentMonth, isFalse);
    final future = MonthStats.compute(
        month: DateTime(2026, 11), now: DateTime(2026, 10, 12), budgetMinor: 300000, txns: const [], baseCurrency: 'CNY');
    expect(future.daysPassed, 0);
    expect(future.averagePerDay, 0);
  });
}
