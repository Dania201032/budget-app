import '../data/models.dart';
import '../import/statement.dart' show parseAmount;

/// What a text shared to the app ("Share → Budget": an SMS, a notification, the text of a payment
/// screenshot) says about a payment, as far as it can be told. The editor opens with it filled in.
class SharedGuess {
  /// Null when no amount was found.
  final int? amountMinor;
  final String? currency;
  final TxnKind kind;
  final String? merchant;

  /// The text itself (shortened), kept as the operation's note.
  final String note;
  const SharedGuess({this.amountMinor, this.currency, this.kind = TxnKind.expense, this.merchant, required this.note});
}

// An amount with its currency on either side: "¥12.00", "1 234,56 ₽", "450р", "12,50 EUR", "€3".
final _withCurrency = RegExp(
  r'(?:([¥￥€$₽]|CNY|RMB|RUB|EUR|USD|KZT|₸)\s?([+\-−]?\d[\d\s ]*(?:[.,]\d{1,2})?))'
  r'|(?:([+\-−]?\d[\d\s ]*(?:[.,]\d{1,2})?)\s?(₽|руб\.?|р\.?(?![а-яё])|元|CNY|RMB|RUB|EUR|€|USD|\$|KZT|₸|тг))',
  caseSensitive: false,
);

// A bare amount with cents ("-12.00" on a payment screen).
final _bare = RegExp(r'(?<![\d.,])([+\-−]?\d{1,3}(?:[\s ,]?\d{3})*[.,]\d{2})(?![\d])');

final _income = RegExp(
  r'зачисл|поступ|пополн|получен|перевод от|возврат|кешбэк|кэшбэк|refund|received|incoming|收款|收入|退款|到账|入账|'
  r'gutschrift|eingang|erhalten|ontvangen|bijgeschreven',
  caseSensitive: false,
);

// Lines that name the other side.
final _payeeLine = RegExp(
  r'(?:收款方|商户名称|商户|商家|对方|Получатель|Магазин|Payee|Merchant|Empfänger|Begünstigter|Ontvanger|Naar)\s*[:：]?\s*(.+)',
  caseSensitive: false,
);

// "Покупка 450р PYATEROCHKA", "Оплата в KFC", "at Starbucks", "bei REWE", "bij Albert Heijn".
final _payeeAfter = RegExp(r'(?:\s(?:в|у|at|bei|bij)\s)([A-Za-zА-Яа-яЁё0-9\x27&.\- ]{2,40}?)(?=[.,;\n]|\s(?:Баланс|Доступно|Остаток|Balance|bezahlt|betaald|paid|оплачен)|$)');

String _currency(String s) {
  final c = s.toLowerCase();
  if (c.contains('¥') || c.contains('￥') || c == 'cny' || c == 'rmb' || c == '元') return 'CNY';
  if (c.contains('€') || c == 'eur') return 'EUR';
  if (c.contains('\$') || c == 'usd') return 'USD';
  if (c == 'kzt' || c == '₸' || c == 'тг') return 'KZT';
  return 'RUB';
}

SharedGuess parseSharedText(String text) {
  final clean = text.replaceAll('\r', '').trim();
  final note = clean.replaceAll(RegExp(r'\s+'), ' ');
  int? amount;
  String? currency;
  final m = _withCurrency.firstMatch(clean);
  if (m != null) {
    final number = m.group(2) ?? m.group(3);
    final cur = m.group(1) ?? m.group(4) ?? '';
    amount = parseAmount(number)?.abs();
    currency = _currency(cur.trim());
  } else {
    final b = _bare.firstMatch(clean);
    if (b != null) amount = parseAmount(b.group(1))?.abs();
  }
  final kind = _income.hasMatch(clean) ? TxnKind.income : TxnKind.expense;
  String? merchant = _payeeLine.firstMatch(clean)?.group(1)?.split('\n').first.trim();
  merchant ??= _payeeAfter.firstMatch(note)?.group(1)?.trim();
  if (merchant != null && (merchant.isEmpty || merchant.length > 40)) merchant = null;
  return SharedGuess(
    amountMinor: amount == 0 ? null : amount,
    currency: currency,
    kind: kind,
    merchant: merchant,
    note: note.length > 140 ? '${note.substring(0, 140)}…' : note,
  );
}
