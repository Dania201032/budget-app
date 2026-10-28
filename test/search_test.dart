import 'package:budget_app/data/models.dart';
import 'package:budget_app/domain/search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t = Txn(
      time: DateTime(2026, 10, 18, 12), amountMinor: 4550, currency: 'CNY', kind: TxnKind.expense,
      categoryId: 1, accountId: 1, merchant: '罗森(财经大学店)', note: 'кофе');
  String cat(int? id) => id == 1 ? 'Еда' : '';
  bool m(TxnFilter f) => matchesFilter(t, f, cat);

  test('text finds payee, comment and category name', () {
    expect(m(const TxnFilter(query: '罗森')), isTrue);
    expect(m(const TxnFilter(query: 'КОФЕ')), isTrue);
    expect(m(const TxnFilter(query: 'еда')), isTrue);
    expect(m(const TxnFilter(query: 'такси')), isFalse);
  });

  test('a number finds the amount', () {
    expect(m(const TxnFilter(query: '45')), isTrue);
    expect(m(const TxnFilter(query: '45,5')), isTrue);
    expect(m(const TxnFilter(query: '45.6')), isFalse);
    expect(m(const TxnFilter(query: '46')), isFalse);
  });

  test('filters: direction, period, categories, account', () {
    expect(m(const TxnFilter(kind: TxnKind.income)), isFalse);
    expect(m(TxnFilter(from: DateTime(2026, 10, 18), to: DateTime(2026, 10, 19))), isTrue);
    expect(m(TxnFilter(from: DateTime(2026, 10, 19))), isFalse);
    expect(m(const TxnFilter(categories: {2})), isFalse);
    expect(m(const TxnFilter(categories: {1, 2}, accountId: 1)), isTrue);
    expect(m(const TxnFilter(accountId: 2)), isFalse);
  });

  test('the account and the app it was recorded from are found too', () {
    final w = Txn(time: DateTime(2026, 10, 27, 16), amountMinor: 1800, currency: 'CNY', kind: TxnKind.expense,
        accountId: 7, source: 'wechat:notification');
    String acc(int? id) => id == 7 ? 'WeChat' : '';
    expect(matchesFilter(w, const TxnFilter(query: 'wechat'), cat, accountName: acc), isTrue);
    expect(matchesFilter(w, const TxnFilter(query: 'WeCh'), cat), isTrue, reason: 'by the app even without the account name');
    expect(matchesFilter(w, const TxnFilter(query: 'alipay'), cat, accountName: acc), isFalse);
  });
}
