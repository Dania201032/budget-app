import '../data/models.dart';
import '../data/repository.dart' show bankKeyForName;
import 'statement.dart';

/// Statements that banks only give as PDF (Sber, VTB, T-Bank's "Справка о движении средств"):
/// the text of the pages, line by line. An operation is a line that starts with a date and has a
/// money amount; the lines after it, up to the next operation, describe it.
///
/// Sber writes expenses without a sign and incomes with "+"; VTB and T-Bank put "-" before expenses.

final _date = RegExp(r'^(\d{2}\.\d{2}\.\d{4})(?:\s+(\d{1,2}:\d{2}(?::\d{2})?))?');
final _money = RegExp(r'(?<![\d.,])([+\-–−]\s?)?\d{1,3}(?:[   ]\d{3})*[.,]\d{2}(?![\d])(?:\s?(?:₽|RUB|руб\.?|р\.|CNY|¥|USD|\$|EUR|€))?');

String _currencyOf(String s) {
  if (s.contains('CNY') || s.contains('¥')) return 'CNY';
  if (s.contains('USD') || s.contains('\$')) return 'USD';
  if (s.contains('EUR') || s.contains('€')) return 'EUR';
  return 'RUB';
}

Statement? readPdfStatement(String text, {String fileName = ''}) {
  final head = text.length > 3000 ? text.substring(0, 3000) : text;
  final lower = '$fileName $head'.toLowerCase();
  final app = lower.contains('сбербанк') || lower.contains('сбер')
      ? 'sber'
      : lower.contains('втб')
          ? 'vtb'
          : lower.contains('т-банк') || lower.contains('тинькофф') || lower.contains('tbank')
              ? 'tbank'
              : bankKeyForName(lower);
  final unsignedIsExpense = app == 'sber';
  final lines = text.replaceAll('\r', '').split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

  final rows = <StatementRow>[];
  StatementRow? current;
  final extra = <String>[];

  void flush() {
    final c = current;
    if (c == null) return;
    // Continuation lines: Sber's second line is "date auth-code description".
    final more = extra
        .map((l) => l.replaceFirst(_date, '').replaceFirst(RegExp(r'^\s*\d{6}\s+'), '').trim())
        // Footnote marks ("*") and the like are no description.
        .where((l) => RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(l) && !_isHeaderLine(l))
        .join(' ');
    final details = [c.details, more].where((s) => s != null && s.isNotEmpty).join(' ').trim();
    rows.add(StatementRow(
      time: c.time,
      hasTime: c.hasTime,
      kind: c.kind,
      amountMinor: c.amountMinor,
      currency: c.currency,
      payee: _payeeIn(details),
      details: details.isEmpty ? null : details,
      category: c.category,
    ));
    current = null;
    extra.clear();
  }

  for (final line in lines) {
    final d = _date.firstMatch(line);
    // A second date (the day it was processed) follows the operation's date in VTB/T-Bank. Money
    // is looked for after the dates: "21.09" of a date is no amount.
    final rest = d == null
        ? ''
        : line.substring(d.end).trim().replaceFirst(RegExp(r'^\d{2}\.\d{2}\.\d{4}(\s+\d{1,2}:\d{2}(:\d{2})?)?\s*'), '');
    final first = _money.firstMatch(rest);
    if (d != null && first != null && !line.toLowerCase().contains('остаток на')) {
      final date = parseStatementDate('${d.group(1)} ${d.group(2) ?? ''}');
      if (date != null) {
        flush();
        final amountText = first.group(0)!;
        final value = parseAmount(amountText);
        if (value == null || value == 0) continue;
        final signed = RegExp(r'^[+\-–−]').hasMatch(amountText.trim());
        final income = signed ? value > 0 : !unsignedIsExpense;
        final before = rest.substring(0, first.start).trim();
        final after = rest.substring(first.end).replaceAll(_money, '').trim();
        current = StatementRow(
          time: date.$1,
          hasTime: date.$2,
          kind: income ? TxnKind.income : TxnKind.expense,
          amountMinor: value.abs(),
          currency: _currencyOf(amountText),
          // Sber: the category stands between the date and the amount; VTB/T-Bank: the description after it.
          category: app == 'sber' && before.isNotEmpty ? before : null,
          details: app == 'sber' ? (after.isEmpty ? null : after) : [before, after].where((s) => s.isNotEmpty).join(' '),
        );
        continue;
      }
    }
    if (current != null) {
      if (_isHeaderLine(line) || extra.length >= 3) {
        flush();
      } else {
        extra.add(line);
      }
    }
  }
  flush();
  if (rows.isEmpty) return null;
  return Statement(format: app == null ? 'pdf' : '$app-pdf', app: app, rows: rows);
}

bool _isHeaderLine(String l) {
  final s = l.toLowerCase();
  return s.startsWith('дата') ||
      s.startsWith('итого') ||
      s.startsWith('страница') ||
      s.contains('остаток') ||
      s.contains('продолжение на следующей') ||
      RegExp(r'^\d+\s+из\s+\d+$').hasMatch(s);
}

/// "Операция по карте ****1234. PYATEROCHKA 1234 Moscow RUS" -> the shop part, when it's clear.
String? _payeeIn(String details) {
  if (details.isEmpty) return null;
  var s = details
      .replaceAll(RegExp(r'Операция по (карте|счету|счёту)\s*\*+\d{4}\.?', caseSensitive: false), '')
      .replaceAll(RegExp(r'(Оплата|Покупка|Перевод)\s+(товаров и услуг|в|по)\.?\s*', caseSensitive: false), '')
      .replaceAll(RegExp(r'\b(RUS|RU|CHN|CN)\b\.?$'), '')
      .trim();
  if (s.isEmpty) return null;
  if (s.length > 40) s = s.substring(0, 40).trim();
  // "ВТБ." (a transfer from another bank) -> "ВТБ"
  s = s.replaceFirst(RegExp(r'[.,;]+$'), '').trim();
  if (s.isEmpty) return null;
  return s;
}

