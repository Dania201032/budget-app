import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../io/xlsx.dart';
import 'bank_formats.dart';
import 'pdf_statement.dart';
import 'pdf_text.dart';
import 'statement.dart';
import 'table_statement.dart';
import 'text_codec.dart';

/// Reads a statement file of any supported kind: CSV/TXT, Excel (.xlsx), PDF, CAMT XML, MT940, or a
/// ZIP of those (Alipay and WeChat send a password-protected ZIP; Sparkasse a ZIP of CAMT files).
/// Throws [StatementPasswordNeeded] for a protected ZIP without (or with a wrong) [password], and
/// [UnknownStatement] when nothing in the file looks like a statement.
///
/// [readPdf] turns a PDF into text; tests pass their own.
Future<List<Statement>> readStatementFile(
  String fileName,
  Uint8List bytes, {
  String? password,
  Future<String> Function(Uint8List) readPdf = pdfText,
}) async {
  final name = fileName.toLowerCase();
  if (_starts(bytes, [0x50, 0x4B])) {
    Archive zip;
    try {
      zip = ZipDecoder().decodeBytes(bytes, password: password);
    } on ArchiveException catch (e) {
      if (e.message.toLowerCase().contains('password')) throw StatementPasswordNeeded(wrong: password != null);
      throw UnknownStatement('zip: $e');
    }
    // An Excel workbook is a ZIP too.
    if (zip.files.any((f) => f.name == 'xl/workbook.xml')) return _xlsx(fileName, bytes);
    final out = <Statement>[];
    for (final f in zip.files.where((f) => f.isFile && !f.name.startsWith('__MACOSX'))) {
      Uint8List? content;
      try {
        content = f.readBytes();
      } on ArchiveException catch (e) {
        if (e.message.toLowerCase().contains('password')) throw StatementPasswordNeeded(wrong: password != null);
        rethrow;
      } catch (_) {
        if (password != null) throw const StatementPasswordNeeded(wrong: true);
        rethrow;
      }
      if (content == null) continue;
      try {
        out.addAll(await readStatementFile(f.name, content, password: password, readPdf: readPdf));
      } on UnknownStatement {
        continue; // a readme or a picture next to the statement
      }
    }
    if (out.isEmpty) {
      // A wrong ZipCrypto password gives garbage rather than an error.
      if (password != null) throw const StatementPasswordNeeded(wrong: true);
      throw const UnknownStatement('zip without statements');
    }
    return out;
  }
  if (_starts(bytes, [0xD0, 0xCF, 0x11, 0xE0])) throw const UnknownStatement('xls');
  if (_starts(bytes, [0x25, 0x50, 0x44, 0x46]) || name.endsWith('.pdf')) {
    final text = await readPdf(bytes);
    final s = readPdfStatement(text, fileName: fileName);
    if (s == null) {
      // A real statement of a period without operations (VTB lists none under «Операции по карте»).
      final empty = RegExp(r'выписк|kontoauszug|statement', caseSensitive: false).hasMatch(text);
      throw UnknownStatement(empty ? 'empty' : 'pdf');
    }
    return [s];
  }
  final text = decodeStatementText(bytes);
  if (looksLikeCamt(text)) {
    final s = readCamt(text);
    if (s.rows.isEmpty) throw const UnknownStatement('camt without entries');
    return [s];
  }
  if (looksLikeMt940(text)) {
    final s = readMt940(text);
    if (s.rows.isEmpty) throw const UnknownStatement('mt940 without entries');
    return [s];
  }
  final s = readTableStatement(parseCsv(text), fileName: fileName);
  if (s == null) throw const UnknownStatement('table');
  return [s];
}

bool _starts(Uint8List b, List<int> magic) {
  if (b.length < magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (b[i] != magic[i]) return false;
  }
  return true;
}

List<Statement> _xlsx(String fileName, Uint8List bytes) {
  final out = <Statement>[];
  for (final sheet in readXlsx(bytes)) {
    final table = <List<String>>[
      for (var r = 1; r <= sheet.maxRow; r++) [for (var c = 1; c <= sheet.maxCol; c++) sheet.text(r, c) ?? ''],
    ];
    final s = readTableStatement(table, fileName: fileName);
    if (s != null) out.add(s);
  }
  if (out.isEmpty) throw const UnknownStatement('xlsx');
  return out;
}

/// For tests and the developer: what a file was read as, one line per row.
String describeStatements(List<Statement> list) => const LineSplitter()
    .convert(list.map((s) => '${s.format} ${s.app ?? '-'} ${s.accountRef ?? ''}\n${s.rows.join('\n')}').join('\n'))
    .join('\n');
