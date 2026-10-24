import 'package:xml/xml.dart';

import '../data/models.dart';
import 'statement.dart';

/// The two standard statement formats of European banks: CAMT.052/053/054 (ISO 20022 XML; Sparkasse,
/// DKB, ING, Rabobank, ABN AMRO export it) and MT940 (SWIFT text; older exports and FinTS HKKAZ).

Iterable<XmlElement> _all(XmlNode n, String name) => n.descendants.whereType<XmlElement>().where((e) => e.localName == name);
XmlElement? _child(XmlNode? n, String name) =>
    n?.children.whereType<XmlElement>().where((e) => e.localName == name).firstOrNull;
XmlElement? _path(XmlNode? n, List<String> names) {
  XmlNode? cur = n;
  for (final name in names) {
    cur = _child(cur, name);
    if (cur == null) return null;
  }
  return cur as XmlElement?;
}

String? _text(XmlNode? n) {
  final t = n?.innerText.trim();
  return t == null || t.isEmpty ? null : t;
}

bool looksLikeCamt(String text) => text.contains('urn:iso:std:iso:20022:tech:xsd:camt.05') || text.contains('<BkToCstmr');

Statement readCamt(String xml) {
  final doc = XmlDocument.parse(xml);
  final rows = <StatementRow>[];
  String? iban;
  for (final stmt in [..._all(doc, 'Stmt'), ..._all(doc, 'Rpt'), ..._all(doc, 'Ntfctn')]) {
    iban ??= _text(_path(stmt, ['Acct', 'Id', 'IBAN'])) ?? _text(_path(stmt, ['Acct', 'Id', 'Othr', 'Id']));
    for (final e in stmt.children.whereType<XmlElement>().where((e) => e.localName == 'Ntry')) {
      final amt = _child(e, 'Amt');
      final currency = amt?.getAttribute('Ccy') ?? 'EUR';
      final value = parseAmount(_text(amt), digits: minorDigits(currency));
      if (value == null || value == 0) continue;
      var debit = _text(_child(e, 'CdtDbtInd')) == 'DBIT';
      // A reversal is booked on the opposite side of what it reverses.
      final reversal = _text(_child(e, 'RvslInd')) == 'true';
      final status = _text(_path(e, ['Sts', 'Cd'])) ?? _text(_child(e, 'Sts')) ?? 'BOOK';
      final dateNode = _child(e, 'BookgDt') ?? _child(e, 'ValDt');
      final dt = _text(_child(dateNode, 'DtTm')) ?? _text(_child(dateNode, 'Dt'));
      final date = parseStatementDate(dt);
      if (date == null) continue;

      final tx = _all(e, 'TxDtls').firstOrNull;
      final parties = _child(tx, 'RltdPties');
      String? name(String role) =>
          _text(_path(parties, [role, 'Nm'])) ?? _text(_path(parties, [role, 'Pty', 'Nm'])) ?? _text(_path(parties, ['Ultmt$role', 'Nm']));
      final payee = debit ? name('Cdtr') : name('Dbtr');
      final purpose = [
        ..._all(e, 'Ustrd').map(_text).nonNulls,
      ].join(' ');
      final info = _text(_child(e, 'AddtlNtryInf'));
      final id = _text(_child(e, 'AcctSvcrRef')) ?? _text(_child(e, 'NtryRef')) ?? _text(_path(tx, ['Refs', 'AcctSvcrRef']));
      if (reversal) debit = !debit;
      rows.add(StatementRow(
        time: date.$1,
        hasTime: date.$2,
        kind: debit ? TxnKind.expense : TxnKind.income,
        amountMinor: value.abs(),
        currency: currency,
        payee: payee,
        details: purpose.isNotEmpty ? purpose : info,
        category: info,
        id: id == null || id == 'NONREF' ? null : id,
        skip: status == 'PDNG' ? 'pending' : null,
      ));
    }
  }
  return Statement(format: 'camt', app: null, accountRef: iban, rows: rows);
}

bool looksLikeMt940(String text) => text.contains(':61:') && (text.contains(':20:') || text.contains(':25:'));

/// MT940 (":61:" lines with ":86:" details). German banks put structured details in ":86:"
/// ("?20".."?29" purpose, "?32"/"?33" the other side's name).
Statement readMt940(String text) {
  final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  // Join continuation lines to their tag.
  final fields = <(String, String)>[];
  for (final l in lines) {
    final m = RegExp(r'^:(\d{2}[A-Z]?):(.*)$').firstMatch(l);
    if (m != null) {
      fields.add((m.group(1)!, m.group(2)!));
    } else if (fields.isNotEmpty && l.trim() != '-' && !l.startsWith('{')) {
      fields[fields.length - 1] = (fields.last.$1, '${fields.last.$2}\n$l');
    }
  }
  final rows = <StatementRow>[];
  String? account;
  var currency = 'EUR';
  for (var i = 0; i < fields.length; i++) {
    final (tag, value) = fields[i];
    if (tag == '25') account = value.trim();
    if (tag == '60F' || tag == '60M') {
      final m = RegExp(r'^[CD]\d{6}([A-Z]{3})').firstMatch(value);
      if (m != null) currency = m.group(1)!;
    }
    if (tag != '61') continue;
    // YYMMDD [MMDD] [R]C|D [funds code letter] amount N... reference
    final m = RegExp(r'^(\d{2})(\d{2})(\d{2})(\d{4})?(R?[CD])([A-Z])?(\d+,\d*)([A-Z]\w{3})?([^\n]*)').firstMatch(value);
    if (m == null) continue;
    final year = 2000 + int.parse(m.group(1)!);
    var date = DateTime(year, int.parse(m.group(2)!), int.parse(m.group(3)!));
    final booking = m.group(4);
    if (booking != null) {
      // The booking day may be in the next year when the value date is late December.
      var b = DateTime(year, int.parse(booking.substring(0, 2)), int.parse(booking.substring(2)));
      if (b.difference(date).inDays < -200) b = DateTime(year + 1, b.month, b.day);
      if (b.difference(date).inDays > 200) b = DateTime(year - 1, b.month, b.day);
      date = b;
    }
    final mark = m.group(5)!;
    final debit = mark == 'D' || mark == 'RC';
    final amount = parseAmount(m.group(7), digits: minorDigits(currency));
    if (amount == null || amount == 0) continue;
    final ref = m.group(9)?.split('//').first.trim();

    String? payee;
    String? purpose;
    String? note;
    if (i + 1 < fields.length && fields[i + 1].$1 == '86') {
      final d = fields[i + 1].$2.replaceAll('\n', '');
      if (RegExp(r'^\d{3}\?').hasMatch(d)) {
        final parts = <String, String>{};
        for (final p in RegExp(r'\?(\d{2})([^?]*)').allMatches(d)) {
          parts[p.group(1)!] = (parts[p.group(1)!] ?? '') + p.group(2)!;
        }
        note = parts['00'];
        purpose = [for (var k = 20; k <= 29; k++) parts['$k'] ?? '', for (var k = 60; k <= 63; k++) parts['$k'] ?? '']
            .join('')
            .replaceAll(RegExp(r'\b(SVWZ|EREF|KREF|MREF|CRED|ABWA|ABWE|IBAN|BIC)\+'), ' ')
            .trim();
        payee = '${parts['32'] ?? ''}${parts['33'] ?? ''}'.trim();
      } else {
        purpose = d.trim();
      }
    }
    rows.add(StatementRow(
      time: date,
      hasTime: false,
      kind: debit ? TxnKind.expense : TxnKind.income,
      amountMinor: amount.abs(),
      currency: currency,
      payee: payee == null || payee.isEmpty ? null : payee,
      details: purpose == null || purpose.isEmpty ? null : purpose,
      category: note,
      id: ref == null || ref.isEmpty || ref == 'NONREF' ? null : ref,
    ));
  }
  return Statement(format: 'mt940', app: null, accountRef: account, rows: rows);
}
