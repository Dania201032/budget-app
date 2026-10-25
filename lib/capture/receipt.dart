import '../import/statement.dart' show parseAmount, parseStatementDate;

/// What a photo of a receipt says: the total, when, where. Russian receipts carry the tax
/// service's QR code ("t=20261024T1530&s=450.00&fn=…&i=…&fp=…&n=1") with the exact total and time;
/// others are read from their text (the line with the total: ИТОГ, TOTAL, 合计, Summe…).
class ReceiptGuess {
  final int? amountMinor;
  final String? currency;
  final DateTime? time;
  final String? shop;

  /// A refund (the QR's n=2) rather than a purchase.
  final bool refund;
  const ReceiptGuess({this.amountMinor, this.currency, this.time, this.shop, this.refund = false});

  bool get isEmpty => amountMinor == null && time == null && shop == null;
}

/// The Russian fiscal QR code, or null when [qr] isn't one.
ReceiptGuess? parseFiscalQr(String qr) {
  if (!qr.contains('fn=') || !qr.contains('s=')) return null;
  final q = {
    for (final p in qr.trim().split('&'))
      if (p.contains('=')) p.substring(0, p.indexOf('=')).toLowerCase(): p.substring(p.indexOf('=') + 1),
  };
  final amount = parseAmount(q['s']);
  DateTime? time;
  final t = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})?').firstMatch(q['t'] ?? '');
  if (t != null) {
    time = DateTime(int.parse(t[1]!), int.parse(t[2]!), int.parse(t[3]!), int.parse(t[4]!), int.parse(t[5]!),
        int.tryParse(t[6] ?? '') ?? 0);
  }
  return ReceiptGuess(amountMinor: amount?.abs(), currency: 'RUB', time: time, refund: q['n'] == '2' || q['n'] == '4');
}

final _totalLine = RegExp(
  r'(?:ИТОГО?|ВСЕГО|К ОПЛАТЕ|TOTAL|AMOUNT DUE|合\s*计|总\s*计|实\s*付|应\s*付|实收|SUMME|GESAMT|ZU ZAHLEN|TOTAAL|TE BETALEN)\s*[:：=]?\s*'
  r'(?:[¥￥€$₽]|RMB|CNY|EUR|RUB)?\s*([+\-]?\d[\d\s ]*[.,]\d{2})',
  caseSensitive: false,
);
final _anyAmount = RegExp(r'(?<![\d.,])(\d{1,3}(?:[\s ]?\d{3})*[.,]\d{2})(?![\d])');
final _dateIn = RegExp(r'(\d{4}[-/.年]\d{1,2}[-/.月]\d{1,2}日?(?:\s+\d{1,2}:\d{2}(?::\d{2})?)?|\d{1,2}[./-]\d{1,2}[./-]\d{2,4}(?:\s+\d{1,2}:\d{2}(?::\d{2})?)?)');

String? _currencyIn(String text) {
  if (RegExp(r'[¥￥元]|RMB|CNY').hasMatch(text)) return 'CNY';
  if (RegExp(r'₽|руб|RUB', caseSensitive: false).hasMatch(text)) return 'RUB';
  if (RegExp(r'€|EUR').hasMatch(text)) return 'EUR';
  return null;
}

/// A receipt's text as read from the photo (lines).
ReceiptGuess parseReceiptText(String text) {
  final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  int? amount;
  // The last total line wins: "ИТОГ" after "ПОДЫТОГ", "实付" after "合计".
  for (final l in lines) {
    final m = _totalLine.firstMatch(l);
    if (m != null) amount = parseAmount(m[1])?.abs() ?? amount;
  }
  // No total line: the largest amount on the receipt.
  if (amount == null) {
    for (final m in _anyAmount.allMatches(text)) {
      final v = parseAmount(m[1]);
      if (v != null && (amount == null || v > amount)) amount = v;
    }
  }
  DateTime? time;
  final d = _dateIn.firstMatch(text);
  if (d != null) {
    final p = parseStatementDate(d[1]!.replaceAll('年', '-').replaceAll('月', '-').replaceAll('日', ''));
    if (p != null && p.$1.isAfter(DateTime(2000)) && !p.$1.isAfter(DateTime.now().add(const Duration(days: 1)))) time = p.$1;
  }
  // The shop: the first line with letters that isn't a heading word.
  final shop = lines
      .where((l) => RegExp(r'[A-Za-zА-Яа-яЁё一-鿿]{2}').hasMatch(l))
      .where((l) => !RegExp(r'кассов|чек|receipt|小票|发票|quittung|bon\b|welcome|добро пожаловать', caseSensitive: false).hasMatch(l))
      .firstOrNull;
  return ReceiptGuess(
    amountMinor: amount,
    currency: _currencyIn(text),
    time: time,
    shop: shop == null || shop.length > 40 ? null : shop,
  );
}
