import '../data/models.dart';
import '../data/repository.dart' show bankKeyForName;
import 'statement.dart';

/// Statements that are tables (CSV, Excel): Alipay, WeChat, T-Bank and most European banks
/// (DKB, Sparkasse, ING, bunq, N26, Revolut, Rabobank…). The header row is found by its column
/// names, so preambles ("支付宝交易明细", "Kontostand vom…") and column order don't matter.

/// Column names per meaning, the preferred one first. Compared lowercased, without spaces around.
const _roles = <String, List<String>>{
  'date': [
    '交易时间', '交易日期', '记账日期', '交易创建时间', '付款时间', '日期',
    'дата операции', 'дата и время операции', 'дата', 'дата проводки',
    'buchungstag', 'buchungsdatum', 'buchung', 'datum', 'boekingsdatum', 'transactiedatum',
    'date', 'transaction date', 'started date', 'completed date', 'booking date',
  ],
  'time': ['время', 'время операции', 'time', 'uhrzeit', 'tijd', '时间'],
  'amount': [
    '金额', '金额(元)', '金额（元）', '交易金额', '金额（元)', '金额(元）',
    'сумма платежа', 'сумма в валюте счета', 'сумма операции', 'сумма',
    'betrag', 'betrag (€)', 'betrag (eur)', 'umsatz', 'umsatz in eur', 'bedrag', 'bedrag (eur)',
    'amount', 'amount (eur)', 'transaction amount',
  ],
  'out': ['支出', 'расход', 'списание', 'дебет', 'soll', 'debit', 'af', 'money out', 'paid out'],
  'in': ['收入', 'приход', 'поступление', 'зачисление', 'кредит', 'haben', 'credit', 'bij', 'money in', 'paid in'],
  'sign': ['收/支', '收支', 'af bij', 'af/bij', 'debit/credit', 'soll/haben', 's/h', 'credit/debit'],
  'currency': [
    '币种', '货币', 'валюта платежа', 'валюта счета', 'валюта операции', 'валюта',
    'währung', 'waehrung', 'munt', 'currency',
  ],
  'payee': [
    '交易对方', '对方', '收款方', 'контрагент', 'получатель', 'получатель/плательщик', 'наименование',
    'zahlungsempfänger*in', 'zahlungsempfänger', 'beguenstigter/zahlungspflichtiger', 'begünstigter/zahlungspflichtiger',
    'auftraggeber/empfänger', 'auftraggeber / begünstigter', 'empfänger', 'name zahlungsbeteiligter',
    'naam / omschrijving', 'naam tegenpartij', 'tegenpartij', 'payee', 'name', 'merchant', 'counterparty',
  ],
  'payer': ['zahlungspflichtige*r', 'zahlungspflichtiger', 'auftraggeber', 'плательщик', 'отправитель'],
  'details': [
    '商品说明', '商品', '商品名称', 'описание', 'назначение платежа', 'назначение', 'комментарий',
    'verwendungszweck', 'mededelingen', 'omschrijving', 'omschrijving-1', 'payment reference', 'description', 'reference',
  ],
  'note': ['备注', 'buchungstext', 'umsatztyp', 'mutatiesoort', 'transaction type', 'type'],
  'category': ['交易分类', '交易类型', 'категория', 'kategorie', 'categorie', 'category'],
  'mcc': ['mcc'],
  'status': ['交易状态', '当前状态', 'статус', 'status', 'state'],
  'id': ['交易订单号', '交易单号', 'номер операции', 'transaction id', 'referenz', 'kundenreferenz (end-to-end)'],
  'method': ['收/付款方式', '支付方式', '收付款方式', 'способ оплаты', 'номер карты', 'карта', 'product'],
};

String _norm(String s) =>
    cleanCell(s).toLowerCase().replaceAll(RegExp(r'\s+'), ' ').replaceAll('"', '').replaceAll(RegExp(r'\s*([/()（）])\s*'), r'$1').trim();

/// Which column holds each meaning, by the header row's names.
Map<String, int> _columns(List<String> header) {
  final names = header.map(_norm).toList();
  final out = <String, int>{};
  final taken = <int>{};
  for (final role in _roles.entries) {
    for (final want in role.value) {
      final i = names.indexWhere((n) => n == _norm(want));
      if (i >= 0 && !taken.contains(i)) {
        out[role.key] = i;
        taken.add(i);
        break;
      }
    }
  }
  // Names with a unit or note: "Betrag (€)", "Сумма операции с округлением" is not the amount.
  if (!out.containsKey('amount')) {
    for (final want in ['金额', 'сумма', 'betrag', 'bedrag', 'amount']) {
      final i = names.indexWhere((n) => n.startsWith(want) && !n.contains('округл') && !n.contains('бонус') && !taken.contains(names.indexOf(n)));
      if (i >= 0) {
        out['amount'] = i;
        taken.add(i);
        break;
      }
    }
  }
  return out;
}

bool _isHeader(Map<String, int> c) =>
    c.containsKey('date') && (c.containsKey('amount') || c.containsKey('out') || c.containsKey('in')) && c.length >= 3;

/// The currency a header names: "Betrag (€)", "金额(元)", "Bedrag (EUR)".
String? _currencyInHeader(String name) {
  final n = name.toLowerCase();
  if (n.contains('元') || n.contains('cny') || n.contains('rmb')) return 'CNY';
  if (n.contains('€') || n.contains('eur')) return 'EUR';
  if (n.contains('₽') || n.contains('rub') || n.contains('руб')) return 'RUB';
  if (n.contains('\$') || n.contains('usd')) return 'USD';
  return null;
}

const _failed = ['fail', 'declin', 'revert', 'cancel', 'reject', 'отклон', 'отмен', 'ошибк', 'неуспеш', '关闭', '失败', '已撤销', 'abgelehnt', 'storniert', 'geweigerd', 'mislukt'];
const _pending = ['pending', 'в обработке', 'ожидан', 'холд', 'hold', 'vorgemerkt', 'vormerkung', 'in behandeling', '处理中', '等待', '待支付'];

/// Reads a table; the text above its header row (and [fileName]) tells whose statement it is.
Statement? readTableStatement(List<List<String>> table, {String fileName = ''}) {
  for (var h = 0; h < table.length && h < 60; h++) {
    final cols = _columns(table[h]);
    if (!_isHeader(cols)) continue;
    final header = table[h].map(_norm).toList();
    final preamble = table.take(h).expand((r) => r).join(' ');
    final context = '$fileName $preamble ${header.join(' ')}';

    String format = 'csv';
    String? app;
    if (context.contains('支付宝') || header.contains('交易订单号') || header.contains('收/付款方式')) {
      format = app = 'alipay';
    } else if (context.contains('微信') || header.contains('交易单号') || header.contains('当前状态')) {
      format = app = 'wechat';
    } else if (header.contains('дата платежа') && header.contains('номер карты')) {
      format = app = 'tbank';
    } else {
      app = bankKeyForName(context);
    }
    final defaultCurrency = switch (format) {
      'alipay' || 'wechat' => 'CNY',
      'tbank' => 'RUB',
      _ => cols['amount'] == null ? null : _currencyInHeader(table[h][cols['amount']!]),
    };

    String? cell(List<String> r, String role) {
      final i = cols[role];
      if (i == null || i >= r.length) return null;
      final v = cleanCell(r[i]);
      return v.isEmpty || v == '/' ? null : v;
    }

    final rows = <StatementRow>[];
    for (final r in table.skip(h + 1)) {
      var parsed = parseStatementDate(cell(r, 'date'));
      if (parsed == null) continue; // footers, totals, blank lines
      final timeText = cell(r, 'time');
      if (!parsed.$2 && timeText != null) {
        final t = RegExp(r'(\d{1,2}):(\d{2})(?::(\d{2}))?').firstMatch(timeText);
        if (t != null) {
          final d = parsed.$1;
          parsed = (DateTime(d.year, d.month, d.day, int.parse(t.group(1)!), int.parse(t.group(2)!), int.tryParse(t.group(3) ?? '') ?? 0), true);
        }
      }
      final currency = (cell(r, 'currency') ?? defaultCurrency ?? '').toUpperCase().replaceAll('RUR', 'RUB');
      final digits = minorDigits(currency);

      // Direction: a 收/支 or Af/Bij column, separate out/in columns, or the amount's sign.
      TxnKind? kind;
      String? skip;
      int? amount;
      final sign = cell(r, 'sign')?.toLowerCase();
      if (cols.containsKey('sign')) {
        amount = parseAmount(cell(r, 'amount'), digits: digits)?.abs();
        if (sign == null || sign.contains('不计')) {
          skip = 'neutral';
          kind = (parseAmount(cell(r, 'amount'), digits: digits) ?? 0) < 0 ? TxnKind.expense : TxnKind.income;
        } else if (const ['支出', 'af', 'debit', 'd', 's', 'soll', 'расход', 'списание', 'dbit'].contains(sign)) {
          kind = TxnKind.expense;
        } else if (const ['收入', 'bij', 'credit', 'c', 'h', 'haben', 'приход', 'зачисление', 'crdt'].contains(sign)) {
          kind = TxnKind.income;
        } else {
          skip = 'neutral';
          kind = TxnKind.expense;
        }
      } else if (cols.containsKey('amount')) {
        final v = parseAmount(cell(r, 'amount'), digits: digits);
        if (v == null) continue;
        amount = v.abs();
        kind = v < 0 ? TxnKind.expense : TxnKind.income;
      } else {
        final out = parseAmount(cell(r, 'out'), digits: digits)?.abs() ?? 0;
        final inc = parseAmount(cell(r, 'in'), digits: digits)?.abs() ?? 0;
        if (out == 0 && inc == 0) continue;
        kind = out > 0 ? TxnKind.expense : TxnKind.income;
        amount = out > 0 ? out : inc;
      }
      if (amount == null || amount == 0) continue;

      final status = cell(r, 'status')?.toLowerCase() ?? '';
      if (skip == null && status.isNotEmpty) {
        if (_failed.any(status.contains)) {
          skip = 'failed';
        } else if (_pending.any(status.contains)) {
          skip = 'pending';
        }
      }
      // T-Bank: "OK" / "FAILED"; Alipay "交易关闭" also when a payment was refunded before it settled.

      final details = cell(r, 'details');
      var payee = kind == TxnKind.income && cols.containsKey('payer') ? cell(r, 'payer') ?? cell(r, 'payee') : cell(r, 'payee');
      // Revolut and some banks only describe: a short description is the shop's name.
      if (payee == null && details != null && details.length <= 40) payee = details;
      rows.add(StatementRow(
        time: parsed.$1,
        hasTime: parsed.$2,
        kind: kind,
        amountMinor: amount,
        currency: currency,
        payee: payee,
        details: details == payee ? cell(r, 'note') : details,
        category: cell(r, 'category'),
        mcc: cell(r, 'mcc'),
        method: cell(r, 'method'),
        id: cell(r, 'id'),
        skip: skip,
      ));
    }
    if (rows.isEmpty) continue;
    return Statement(format: format, app: app, rows: rows);
  }
  return null;
}
