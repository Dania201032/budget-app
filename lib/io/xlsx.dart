import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Minimal .xlsx reader/writer: enough to import the user's budget sheets
/// (cached cell values, simple formulas like "38+11+29.9", cell comments) and to export tables.

class XlsxCell {
  /// Cached value as text (numbers as written by Excel, strings resolved).
  final String? value;

  /// Formula without "=", if any.
  final String? formula;
  final bool isString;
  const XlsxCell(this.value, this.formula, this.isString);

  double? get number => isString ? null : double.tryParse(value ?? '');
}

class XlsxSheet {
  final String name;

  /// "B2" -> cell
  final Map<String, XlsxCell> cells;

  /// "F6" -> comment text (author prefix removed)
  final Map<String, String> comments;
  const XlsxSheet(this.name, this.cells, this.comments);

  XlsxCell? at(int row, int col) => cells['${columnName(col)}$row'];
  String? text(int row, int col) => at(row, col)?.value;

  int get maxRow => cells.keys.map((k) => cellRow(k)).fold(0, (a, b) => a > b ? a : b);
  int get maxCol => cells.keys.map((k) => cellCol(k)).fold(0, (a, b) => a > b ? a : b);
}

/// 1 -> "A", 27 -> "AA"
String columnName(int col) {
  var n = col;
  var s = '';
  while (n > 0) {
    final r = (n - 1) % 26;
    s = String.fromCharCode(65 + r) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

int cellCol(String ref) {
  var col = 0;
  for (final ch in ref.codeUnits) {
    if (ch < 65 || ch > 90) break;
    col = col * 26 + (ch - 64);
  }
  return col;
}

int cellRow(String ref) => int.parse(ref.replaceAll(RegExp(r'^[A-Z]+'), ''));

/// Excel 1900 date system serial -> date.
DateTime excelDate(double serial) => DateTime(1899, 12, 30).add(Duration(days: serial.floor()));

List<XlsxSheet> readXlsx(Uint8List bytes) {
  final zip = ZipDecoder().decodeBytes(bytes);
  XmlDocument? doc(String path) {
    final f = zip.findFile(path);
    if (f == null) return null;
    return XmlDocument.parse(utf8.decode(f.content));
  }

  String resolve(String baseDir, String target) {
    if (target.startsWith('/')) return target.substring(1);
    final parts = [...baseDir.split('/').where((p) => p.isNotEmpty)];
    for (final p in target.split('/')) {
      if (p == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else if (p != '.') {
        parts.add(p);
      }
    }
    return parts.join('/');
  }

  Map<String, String> rels(String relsPath, String baseDir) {
    final d = doc(relsPath);
    if (d == null) return {};
    return {
      for (final r in d.findAllElements('Relationship'))
        r.getAttribute('Id')!: resolve(baseDir, r.getAttribute('Target')!),
    };
  }

  final shared = <String>[];
  final sst = doc('xl/sharedStrings.xml');
  if (sst != null) {
    for (final si in sst.findAllElements('si')) {
      // Rich text: concatenate <t> of runs, skipping phonetic hints (<rPh>).
      shared.add(si.findAllElements('t').where((t) => t.parentElement?.name.local != 'rPh').map((t) => t.innerText).join());
    }
  }

  final wbRels = rels('xl/_rels/workbook.xml.rels', 'xl');
  final sheets = <XlsxSheet>[];
  for (final s in doc('xl/workbook.xml')!.findAllElements('sheet')) {
    final rid = s.attributes.firstWhere((a) => a.name.local == 'id').value; // r:id (any prefix)
    final path = wbRels[rid];
    if (path == null) continue;
    final sheetDoc = doc(path);
    if (sheetDoc == null) continue;

    final cells = <String, XlsxCell>{};
    for (final c in sheetDoc.findAllElements('c')) {
      final ref = c.getAttribute('r');
      if (ref == null) continue;
      final t = c.getAttribute('t');
      final f = c.getElement('f')?.innerText;
      String? v = c.getElement('v')?.innerText;
      var isString = false;
      if (t == 's' && v != null) {
        v = shared[int.parse(v)];
        isString = true;
      } else if (t == 'inlineStr') {
        v = c.findAllElements('t').map((e) => e.innerText).join();
        isString = true;
      } else if (t == 'str') {
        isString = true;
      }
      cells[ref] = XlsxCell(v, (f == null || f.isEmpty) ? null : f, isString);
    }

    final comments = <String, String>{};
    final dir = path.substring(0, path.lastIndexOf('/'));
    final file = path.substring(path.lastIndexOf('/') + 1);
    final sheetRels = rels('$dir/_rels/$file.rels', dir);
    for (final target in sheetRels.values.where((p) => p.contains('comments'))) {
      final cd = doc(target);
      if (cd == null) continue;
      for (final cm in cd.findAllElements('comment')) {
        var text = cm.findAllElements('t').map((e) => e.innerText).join();
        // Excel prefixes notes with "Author:" in the first run.
        text = text.replaceFirst(RegExp(r'^[^:\n]{1,40}:\s*'), '').trim();
        if (text.isNotEmpty) comments[cm.getAttribute('ref')!] = text;
      }
    }

    sheets.add(XlsxSheet(s.getAttribute('name')!, cells, comments));
  }
  return sheets;
}

// --- Writer ---

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');

/// Writes one or more sheets. Cell values: String, num, or null. First row is styled as a header.
Uint8List writeXlsx(Map<String, List<List<Object?>>> sheets, {Map<String, List<double>>? columnWidths}) {
  final archive = Archive();
  void add(String name, String content) => archive.addFile(ArchiveFile.string(name, content));

  final names = sheets.keys.toList();
  add('[Content_Types].xml', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
${[for (var i = 0; i < names.length; i++) '<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'].join('\n')}
</Types>''');
  add('_rels/.rels', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>''');
  add('xl/workbook.xml', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets>${[for (var i = 0; i < names.length; i++) '<sheet name="${_esc(names[i])}" sheetId="${i + 1}" r:id="rId${i + 1}"/>'].join()}</sheets>
</workbook>''');
  add('xl/_rels/workbook.xml.rels', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
${[for (var i = 0; i < names.length; i++) '<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>'].join('\n')}
<Relationship Id="rId${names.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>''');
  // Style 0: default, 1: bold header, 2: number with 2 decimals.
  add('xl/styles.xml', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<numFmts count="1"><numFmt numFmtId="164" formatCode="#,##0.00"/></numFmts>
<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>
<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs>
</styleSheet>''');

  for (var i = 0; i < names.length; i++) {
    final rows = sheets[names[i]]!;
    final widths = columnWidths?[names[i]];
    final sb = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">');
    if (rows.isNotEmpty) {
      sb.write('<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>');
    }
    if (widths != null && widths.isNotEmpty) {
      sb.write('<cols>');
      for (var c = 0; c < widths.length; c++) {
        sb.write('<col min="${c + 1}" max="${c + 1}" width="${widths[c]}" customWidth="1"/>');
      }
      sb.write('</cols>');
    }
    sb.write('<sheetData>');
    for (var r = 0; r < rows.length; r++) {
      sb.write('<row r="${r + 1}">');
      for (var c = 0; c < rows[r].length; c++) {
        final v = rows[r][c];
        if (v == null) continue;
        final ref = '${columnName(c + 1)}${r + 1}';
        final style = r == 0 ? ' s="1"' : '';
        if (v is num) {
          sb.write('<c r="$ref"${r == 0 ? style : ' s="2"'}><v>$v</v></c>');
        } else {
          sb.write('<c r="$ref" t="inlineStr"$style><is><t xml:space="preserve">${_esc(v.toString())}</t></is></c>');
        }
      }
      sb.write('</row>');
    }
    sb.write('</sheetData></worksheet>');
    add('xl/worksheets/sheet${i + 1}.xml', sb.toString());
  }
  return ZipEncoder().encodeBytes(archive);
}
