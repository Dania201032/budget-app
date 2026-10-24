import 'dart:convert';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';

/// Words that statement headers start with, in the encodings banks use: the decoding that shows
/// them is the right one (Alipay writes GBK, Russian banks Windows-1251, German ones Latin-1).
const _headerWords = [
  '交易', '金额', '日期', '收/支', '账单', '支付宝', '微信',
  'Дата', 'Сумма', 'Операци', 'Описание', 'Валюта', 'Статус', 'Карт',
  'Buchung', 'Betrag', 'Datum', 'Empf', 'Verwendungszweck', 'Währung', 'Waehrung', 'Bedrag', 'Omschrijving',
  'Date', 'Amount', 'Description', 'Currency',
];

/// Text of a statement file whatever its encoding: UTF-8/16 (with or without a BOM), GBK,
/// Windows-1251 or Latin-1.
String decodeStatementText(Uint8List bytes) {
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) return _utf16(bytes.sublist(2), little: true);
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) return _utf16(bytes.sublist(2), little: false);
  // UTF-16 without a BOM: every other byte is zero in the ASCII parts.
  if (bytes.length > 8 && bytes[1] == 0 && bytes[3] == 0) return _utf16(bytes, little: true);
  try {
    return utf8.decode(bytes);
  } on FormatException {
    // Not UTF-8: one of the legacy encodings.
  }
  // Latin header words read the same in every encoding: only a Chinese or Russian word that shows
  // up proves GBK or Windows-1251.
  final head = bytes.length > 6000 ? bytes.sublist(0, 6000) : bytes;
  if (_chineseWords.any(_gbk(head).contains)) return _gbk(bytes);
  if (_russianWords.any(cp1251Decode(head).contains) || _looksCyrillic(head)) return cp1251Decode(bytes);
  return latin1Decode(bytes);
}

final _chineseWords = _headerWords.where((w) => w.codeUnits.any((c) => c > 0x2E80)).toList();
final _russianWords = _headerWords.where((w) => w.codeUnits.any((c) => c >= 0x0400 && c <= 0x04FF)).toList();

String _gbk(Uint8List b) {
  try {
    return gbk.decode(b);
  } catch (_) {
    return '';
  }
}

String _utf16(Uint8List b, {required bool little}) {
  final out = StringBuffer();
  for (var i = 0; i + 1 < b.length; i += 2) {
    out.writeCharCode(little ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1]);
  }
  return out.toString();
}

/// Windows-1251 letters are 0xC0–0xFF; in Latin-1 text those are rare accented letters.
bool _looksCyrillic(Uint8List b) {
  var high = 0, letters = 0;
  for (final c in b) {
    if (c >= 0x80) high++;
    if (c >= 0xC0) letters++;
  }
  return high > 20 && letters > high * 0.7;
}

/// Windows-1252 is what "Latin-1" CSV files really are (the euro sign is 0x80).
String latin1Decode(Uint8List b) {
  final out = StringBuffer();
  for (final c in b) {
    if (c >= 0x80 && c < 0xA0) {
      out.writeCharCode(_cp1252High[c - 0x80]);
    } else {
      out.writeCharCode(c);
    }
  }
  return out.toString();
}

const _cp1252High = [
  0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
  0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178,
];

String cp1251Decode(Uint8List b) {
  final out = StringBuffer();
  for (final c in b) {
    if (c < 0x80) {
      out.writeCharCode(c);
    } else if (c >= 0xC0) {
      out.writeCharCode(0x0410 + c - 0xC0);
    } else {
      out.writeCharCode(_cp1251High[c - 0x80]);
    }
  }
  return out.toString();
}

const _cp1251High = [
  0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021, 0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
  0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0xFFFD, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
  0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7, 0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
  0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7, 0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
];

/// Rows of a CSV/TSV text; the separator (",", ";", tab, "|") is the one that splits the header-like
/// lines most evenly. Quotes ("a;b", "say ""hi""") are honoured; empty lines are dropped.
List<List<String>> parseCsv(String text) {
  final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final sep = _guessSeparator(lines);
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < lines.length; i++) {
    final c = lines[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < lines.length && lines[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(c);
      }
    } else if (c == '"' && cell.toString().trim().isEmpty) {
      quoted = true;
      cell.clear();
    } else if (c == sep) {
      row.add(cell.toString());
      cell.clear();
    } else if (c == '\n') {
      row.add(cell.toString());
      cell.clear();
      if (row.any((s) => s.trim().isNotEmpty)) rows.add(row);
      row = <String>[];
    } else {
      cell.write(c);
    }
  }
  row.add(cell.toString());
  if (row.any((s) => s.trim().isNotEmpty)) rows.add(row);
  return rows;
}

String _guessSeparator(String text) {
  final sample = text.split('\n').where((l) => l.trim().isNotEmpty).take(40).toList();
  var best = ',';
  var bestScore = -1;
  for (final sep in [';', ',', '\t', '|']) {
    // The most common count of separators per line, and on how many lines it occurs.
    final counts = <int, int>{};
    for (final l in sample) {
      final n = sep.allMatches(l).length;
      if (n > 0) counts[n] = (counts[n] ?? 0) + 1;
    }
    if (counts.isEmpty) continue;
    final top = counts.entries.reduce((a, b) => b.value > a.value || (b.value == a.value && b.key > a.key) ? b : a);
    final score = top.value * 100 + top.key;
    if (score > bestScore) {
      bestScore = score;
      best = sep;
    }
  }
  return best;
}
