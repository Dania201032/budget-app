import 'package:budget_app/capture/receipt.dart';
import 'package:flutter_test/flutter_test.dart';

/// Receipts: the Russian tax service's QR code and receipts read as text. Made-up shops.
void main() {
  test('the fiscal QR code of a Russian receipt', () {
    final g = parseFiscalQr('t=20261024T1530&s=450.00&fn=9999078900000000&i=12345&fp=1234567890&n=1')!;
    expect(g.amountMinor, 45000);
    expect(g.currency, 'RUB');
    expect(g.time, DateTime(2026, 10, 24, 15, 30));
    expect(g.refund, isFalse);
    expect(parseFiscalQr('t=20261024T153012&s=99.90&fn=1&i=1&fp=1&n=2')!.refund, isTrue);
    expect(parseFiscalQr('https://example.com'), isNull);
  });

  test('a Chinese receipt: the paid total, not the subtotal', () {
    final g = parseReceiptText('全家便利店\n上海某某店\n2026-10-20 12:30\n饭团 8.50\n饮料 6.00\n合计 14.50\n优惠 -2.00\n实付 ¥12.50');
    expect(g.amountMinor, 1250);
    expect(g.currency, 'CNY');
    expect(g.time, DateTime(2026, 10, 20, 12, 30));
    expect(g.shop, '全家便利店');
  });

  test('a German receipt and one without a total line', () {
    final g = parseReceiptText('Bäckerei Beispiel\nBrot 3,20\nKaffee 2,80\nSUMME EUR 6,00\n24.10.2026 09:15');
    expect(g.amountMinor, 600);
    expect(g.time, DateTime(2026, 10, 24, 9, 15));
    expect(parseReceiptText('Shop\nA 2.00\nB 13.40').amountMinor, 1340);
  });
}
