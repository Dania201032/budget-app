import 'package:budget_app/capture/shared_text.dart';
import 'package:budget_app/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Texts shared to the app. All names and numbers are made up.
void main() {
  test('a Russian bank SMS: amount, currency, shop', () {
    final g = parseSharedText('Покупка 450р PYATEROCHKA 1234. Баланс 10 000р');
    expect(g.amountMinor, 45000);
    expect(g.currency, 'RUB');
    expect(g.kind, TxnKind.expense);
    expect(g.merchant, isNull); // no "в"/"at": the editor shows the text as a note
    final g2 = parseSharedText('Оплата 1 234,56 ₽ в KFC Moscow. Доступно 5 000 ₽');
    expect(g2.amountMinor, 123456);
    expect(g2.merchant, 'KFC Moscow');
  });

  test('an incoming transfer is an income', () {
    final g = parseSharedText('Зачисление 5 000 ₽ от Иван Петрович С.');
    expect(g.kind, TxnKind.income);
    expect(g.amountMinor, 500000);
  });

  test('the text of an Alipay payment screenshot', () {
    final g = parseSharedText('支付成功\n¥38.50\n收款方 上海某某餐厅\n付款方式 余额');
    expect(g.amountMinor, 3850);
    expect(g.currency, 'CNY');
    expect(g.merchant, '上海某某餐厅');
  });

  test('a bare amount with cents, a European card push', () {
    expect(parseSharedText('Zahlung -12,50\nREWE Markt').amountMinor, 1250);
    final g = parseSharedText('Du hast 23,45 EUR bei REWE bezahlt.');
    expect(g.amountMinor, 2345);
    expect(g.currency, 'EUR');
    expect(g.merchant, 'REWE');
  });

  test('no amount at all', () {
    final g = parseSharedText('Привет, как дела?');
    expect(g.amountMinor, isNull);
    expect(g.note, 'Привет, как дела?');
  });
}
