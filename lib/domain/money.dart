import 'package:intl/intl.dart';

import '../l10n/strings.dart';
import 'currencies.dart';

/// 123450 -> "1 234,50 ¥", 123400 -> "1 234 ¥" (grouping and decimal mark follow the app
/// language): whole amounts without decimals, the rest always with two.
String formatMoney(int minor, String currency, {bool signed = false}) {
  final abs = NumberFormat(minor % 100 == 0 ? '#,##0' : '#,##0.00', intlLocale).format(minor.abs() / 100);
  final sign = minor < 0 ? '−' : (signed && minor > 0 ? '+' : '');
  return '$sign$abs ${currencySymbol(currency)}';
}

/// Number only, for table cells: 123450 -> "1 234,5". Negative with a real minus (−), as everywhere.
String formatAmount(int minor, {String pattern = '#,##0.#'}) =>
    NumberFormat(pattern, intlLocale).format(minor / 100).replaceFirst('-', '−');

/// "12,5" / "12.50" / "1 234" -> minor units; null if not a positive number.
int? parseAmountToMinor(String input) {
  final cleaned = input.replaceAll(RegExp(r'[\s ]'), '').replaceAll(',', '.');
  final value = double.tryParse(cleaned);
  if (value == null || value <= 0) return null;
  return (value * 100).round();
}

/// "12.4379" -> "12,44" (rates shown with up to 4 significant decimals).
String formatRate(double r) => NumberFormat(r >= 100 ? '#,##0.##' : '#,##0.####', intlLocale).format(r);
