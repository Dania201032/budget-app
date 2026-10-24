import '../data/models.dart';

/// One operation as a bank or payment app lists it in an exported statement (or sends it over its API).
class StatementRow {
  final DateTime time;

  /// False when the statement gives only the day (most bank statements): matched by day, not by minute.
  final bool hasTime;
  final TxnKind kind;

  /// Positive, in minor units of [currency].
  final int amountMinor;
  final String currency;

  /// Shop or person on the other side.
  final String? payee;

  /// Purpose, comment, product ("Verwendungszweck", "商品说明", "Описание").
  final String? details;

  /// Category as the bank names it, and the card network's merchant category code, if given.
  final String? category;
  final String? mcc;

  /// How it was paid ("余额", "招商银行储蓄卡", card number).
  final String? method;

  /// The bank's own id of the operation, when it has one: re-importing the same file finds it.
  final String? id;

  /// Why this row is not an operation to record: `failed` (declined, closed, cancelled), `pending`,
  /// `neutral` (moved inside the same wallet: Alipay "不计收支", WeChat "/"). Null for a real one.
  final String? skip;

  const StatementRow({
    required this.time,
    this.hasTime = true,
    required this.kind,
    required this.amountMinor,
    required this.currency,
    this.payee,
    this.details,
    this.category,
    this.mcc,
    this.method,
    this.id,
    this.skip,
  });

  @override
  String toString() =>
      '${time.toIso8601String()} ${kind.name} $amountMinor $currency ${payee ?? ''} | ${details ?? ''}${skip == null ? '' : ' [$skip]'}';
}

/// A statement read from a file or downloaded from a bank.
class Statement {
  /// What it was read as: alipay, wechat, tbank, sber, vtb, camt, mt940, csv, bunq, fints…
  final String format;

  /// Whose operations these are, as an account type / bank key (alipay, wechat, sber, dkb…); null if unknown.
  final String? app;

  /// The account the statement is for, if it says (IBAN, last card digits).
  final String? accountRef;
  final List<StatementRow> rows;

  const Statement({required this.format, this.app, this.accountRef, required this.rows});

  String? get currency {
    final counts = <String, int>{};
    for (final r in rows) {
      counts[r.currency] = (counts[r.currency] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    return (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
  }

  DateTime? get from => rows.isEmpty ? null : rows.map((r) => r.time).reduce((a, b) => a.isBefore(b) ? a : b);
  DateTime? get to => rows.isEmpty ? null : rows.map((r) => r.time).reduce((a, b) => a.isAfter(b) ? a : b);
}

/// The file is not a statement this app can read.
class UnknownStatement implements Exception {
  final String reason;
  const UnknownStatement([this.reason = '']);
  @override
  String toString() => 'UnknownStatement($reason)';
}

/// The file is a password-protected archive (Alipay and WeChat send their statements so).
class StatementPasswordNeeded implements Exception {
  final bool wrong;
  const StatementPasswordNeeded({this.wrong = false});
}

// --- Numbers and dates as statements write them ---

const _zeroDecimals = {'JPY', 'KRW', 'VND', 'IDR', 'CLP', 'ISK', 'UGX', 'PYG'};

int minorDigits(String currency) => _zeroDecimals.contains(currency) ? 0 : 2;

/// "1 234,56", "-1.234,56", "1,234.56", "¥12.00", "+12,34", "−5", "(12.00)" -> signed amount in
/// minor units (2 digits after the point unless [digits]); null if there is no number.
int? parseAmount(String? text, {int digits = 2}) {
  if (text == null) return null;
  var s = text.trim().replaceAll(RegExp(r'[\s   ]'), '').replaceAll('−', '-').replaceAll('–', '-');
  var negative = false;
  if (s.startsWith('(') && s.endsWith(')')) {
    negative = true;
    s = s.substring(1, s.length - 1);
  }
  // Currency signs and codes around the number.
  s = s.replaceAll(RegExp(r'[^0-9.,+\-]'), '');
  if (s.startsWith('-')) {
    negative = !negative;
    s = s.substring(1);
  } else if (s.startsWith('+')) {
    s = s.substring(1);
  }
  if (s.endsWith('-')) {
    // "12,34-" (some German exports)
    negative = !negative;
    s = s.substring(0, s.length - 1);
  }
  if (s.isEmpty || !RegExp(r'\d').hasMatch(s)) return null;
  // With both "." and ",", the later one is the decimal point. With one of them: several are
  // thousands ("1.234.567"), one followed by exactly 3 digits is a thousand ("1.234"), else decimal.
  final lastDot = s.lastIndexOf('.');
  final lastComma = s.lastIndexOf(',');
  final last = lastDot > lastComma ? lastDot : lastComma;
  var whole = s;
  var frac = '';
  if (last >= 0) {
    final after = s.substring(last + 1);
    final both = lastDot >= 0 && lastComma >= 0;
    final repeated = s[last].allMatches(s).length > 1;
    if (both || (!repeated && after.length != 3)) {
      whole = s.substring(0, last);
      frac = after;
    }
  }
  whole = whole.replaceAll(RegExp(r'[.,+\-]'), '');
  if (whole.isEmpty) whole = '0';
  if (!RegExp(r'^\d+$').hasMatch(frac.isEmpty ? '0' : frac)) return null;
  if (frac.length > digits) frac = frac.substring(0, digits);
  frac = frac.padRight(digits, '0');
  final v = int.tryParse('$whole$frac');
  if (v == null) return null;
  return negative ? -v : v;
}

/// A date (and maybe time) as statements write it: "2026-10-12 13:45:00", "2026/10/12 13:45",
/// "12.10.2026 13:45", "12.10.26", "20261012", "2026-10-12T13:45:00+08:00", an Excel day number.
/// Returns the moment and whether a time was given.
(DateTime, bool)? parseStatementDate(String? text) {
  if (text == null) return null;
  final s = text.trim();
  if (s.isEmpty) return null;
  // Excel serial day (xlsx cells hold dates as numbers).
  final serial = double.tryParse(s);
  if (serial != null && serial > 20000 && serial < 80000 && !RegExp(r'^\d{8}$').hasMatch(s)) {
    final day = DateTime(1899, 12, 30).add(Duration(days: serial.floor()));
    final ms = ((serial - serial.floor()) * 86400000).round();
    return (day.add(Duration(milliseconds: ms)), ms > 0);
  }
  if (RegExp(r'^\d{4}-\d{2}-\d{2}T').hasMatch(s)) {
    final d = DateTime.tryParse(s);
    if (d != null) return (d.isUtc || RegExp(r'[+-]\d{2}:?\d{2}$|Z$').hasMatch(s) ? d.toLocal() : d, true);
  }
  int? y, mo, d;
  var m = RegExp(r'^(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})日?').firstMatch(s);
  if (m != null) {
    y = int.parse(m.group(1)!);
    mo = int.parse(m.group(2)!);
    d = int.parse(m.group(3)!);
  } else if ((m = RegExp(r'^(\d{1,2})[./-](\d{1,2})[./-](\d{4}|\d{2})(?!\d)').firstMatch(s)) != null) {
    d = int.parse(m!.group(1)!);
    mo = int.parse(m.group(2)!);
    y = int.parse(m.group(3)!);
    if (y < 100) y += 2000;
  } else if ((m = RegExp(r'^(\d{4})(\d{2})(\d{2})(?!\d)').firstMatch(s)) != null) {
    y = int.parse(m!.group(1)!);
    mo = int.parse(m.group(2)!);
    d = int.parse(m.group(3)!);
  }
  if (m == null || y == null || mo == null || d == null || mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  final time = RegExp(r'(\d{1,2}):(\d{2})(?::(\d{2}))?').firstMatch(s.substring(m.end));
  int h = 0, mi = 0, sec = 0;
  if (time != null) {
    h = int.parse(time.group(1)!);
    mi = int.parse(time.group(2)!);
    sec = int.tryParse(time.group(3) ?? '') ?? 0;
  }
  return (DateTime(y, mo, d, h, mi, sec), time != null);
}

/// Text of a cell without the quotes, tabs and "=" some exports wrap numbers in ("=\"0012\"", "\t2026-…").
String cleanCell(String? s) {
  if (s == null) return '';
  var t = s.replaceAll('\t', ' ').trim();
  if (t.startsWith('="') && t.endsWith('"')) t = t.substring(2, t.length - 1);
  return t.trim();
}
