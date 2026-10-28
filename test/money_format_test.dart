import 'package:budget_app/domain/money.dart';
import 'package:budget_app/l10n/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

/// Money reads the same everywhere: whole amounts without decimals, the rest with two, a real minus.
void main() {
  setUpAll(() async {
    currentLanguage = 'ru';
    await initializeDateFormatting();
  });

  test('two decimals or none', () {
    expect(formatMoney(249030, 'CNY'), '2\u00a0490,30 ¥');
    expect(formatMoney(250000, 'CNY'), '2\u00a0500 ¥');
    expect(formatMoney(970, 'CNY'), '9,70 ¥');
    expect(formatMoney(-150, 'CNY'), '−1,50 ¥');
    expect(formatMoney(150, 'CNY', signed: true), '+1,50 ¥');
  });

  test('table amounts use a real minus', () {
    expect(formatAmount(-10641, pattern: '#,##0.00'), '−106,41');
    expect(formatAmount(4930), '49,3');
  });
}
