import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'xlsx.dart' show columnName;

/// A styled workbook for the computer's Excel export: formulas with cached values, fills,
/// frozen headers, filters, column widths and protected formulas.

enum XStyle { text, header, label, totalLabel, number, total, over, input, heat1, heat2, heat3, date, muted }

class XCell {
  final Object? value;
  final String? formula;
  final XStyle style;
  const XCell(this.value, {this.formula, this.style = XStyle.text});
}

class XSheet {
  final String name;
  final List<List<XCell?>> rows;
  final List<double> widths;
  final int freezeRows;
  final int freezeCols;
  final bool autoFilter;
  final bool protect;
  const XSheet(this.name, this.rows,
      {this.widths = const [], this.freezeRows = 0, this.freezeCols = 0, this.autoFilter = false, this.protect = false});
}

class XTheme {
  final String headerFill;
  final String headerFont;
  final String totalFill;
  final List<String> heat;
  const XTheme(this.headerFill, this.headerFont, this.totalFill, this.heat);

  static const ledger = XTheme('0E3B34', 'FFFFFF', 'E3F0E9', ['E3F0E9', 'BFE3D1', '8FCBB0']);
  static const neutral = XTheme('E4E4E4', '1B2422', 'EDEDED', ['EEF4FB', 'D3E3F5', 'A9C8EC']);
  static const plain = XTheme('FFFFFF', '1B2422', 'FFFFFF', ['F2F2F2', 'E0E0E0', 'C8C8C8']);
}

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');

/// [numberFormat] e.g. '#,##0.00' or '#,##0 "¥"'; [dateFormat] e.g. 'dd.mm.yyyy'.
Uint8List writeBook(List<XSheet> sheets, {required XTheme theme, required String numberFormat, required String dateFormat}) {
  final archive = Archive();
  void add(String name, String content) => archive.addFile(ArchiveFile.string(name, content));
  final n = sheets.length;
  add('[Content_Types].xml', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
${[for (var i = 0; i < n; i++) '<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'].join('\n')}
</Types>''');
  add('_rels/.rels', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>''');
  final names = <String>{};
  String sheetName(String s) {
    var base = s.replaceAll(RegExp(r'[\\/?*\[\]:]'), ' ').trim();
    if (base.isEmpty) base = 'Sheet';
    if (base.length > 31) base = base.substring(0, 31);
    var name = base;
    for (var k = 2; names.contains(name.toLowerCase()); k++) {
      name = '${base.substring(0, base.length.clamp(0, 28))} $k';
    }
    names.add(name.toLowerCase());
    return name;
  }

  final sheetNames = [for (final s in sheets) sheetName(s.name)];
  add('xl/workbook.xml', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets>${[for (var i = 0; i < n; i++) '<sheet name="${_esc(sheetNames[i])}" sheetId="${i + 1}" r:id="rId${i + 1}"/>'].join()}</sheets>
<calcPr calcId="191029" fullCalcOnLoad="1"/>
</workbook>''');
  add('xl/_rels/workbook.xml.rels', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
${[for (var i = 0; i < n; i++) '<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>'].join('\n')}
<Relationship Id="rId${n + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>''');

  // Fonts: 0 normal, 1 bold, 2 header, 3 blue (input), 4 dark red bold (over), 5 grey.
  // Fills: 0 none, 1 gray125, 2 header, 3 total, 4 over, 5–7 heat.
  // Number formats: 164 numbers, 165 dates.
  String fill(String rgb) => '<fill><patternFill patternType="solid"><fgColor rgb="FF$rgb"/><bgColor indexed="64"/></patternFill></fill>';
  final xfs = <XStyle, String>{
    XStyle.text: '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>',
    XStyle.header: '<xf numFmtId="0" fontId="2" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/>',
    XStyle.label: '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>',
    XStyle.totalLabel: '<xf numFmtId="0" fontId="1" fillId="3" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/>',
    XStyle.number: '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>',
    XStyle.total: '<xf numFmtId="164" fontId="1" fillId="3" borderId="1" xfId="0" applyNumberFormat="1" applyFont="1" applyFill="1" applyBorder="1"/>',
    XStyle.over: '<xf numFmtId="164" fontId="4" fillId="4" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1" applyFill="1"/>',
    XStyle.input:
        '<xf numFmtId="164" fontId="3" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1" applyProtection="1"><protection locked="0"/></xf>',
    XStyle.heat1: '<xf numFmtId="164" fontId="0" fillId="5" borderId="0" xfId="0" applyNumberFormat="1" applyFill="1"/>',
    XStyle.heat2: '<xf numFmtId="164" fontId="0" fillId="6" borderId="0" xfId="0" applyNumberFormat="1" applyFill="1"/>',
    XStyle.heat3: '<xf numFmtId="164" fontId="0" fillId="7" borderId="0" xfId="0" applyNumberFormat="1" applyFill="1"/>',
    XStyle.date: '<xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>',
    XStyle.muted: '<xf numFmtId="0" fontId="5" fillId="0" borderId="0" xfId="0" applyFont="1"/>',
  };
  final order = XStyle.values;
  add('xl/styles.xml', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<numFmts count="2"><numFmt numFmtId="164" formatCode="${_esc(numberFormat)}"/><numFmt numFmtId="165" formatCode="${_esc(dateFormat)}"/></numFmts>
<fonts count="6"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><color rgb="FF${theme.headerFont}"/><name val="Calibri"/></font><font><sz val="11"/><color rgb="FF1F4FB4"/><name val="Calibri"/></font><font><b/><sz val="11"/><color rgb="FF9A3F1C"/><name val="Calibri"/></font><font><sz val="11"/><color rgb="FF5E6763"/><name val="Calibri"/></font></fonts>
<fills count="8"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>${fill(theme.headerFill)}${fill(theme.totalFill)}${fill('FBE0D2')}${fill(theme.heat[0])}${fill(theme.heat[1])}${fill(theme.heat[2])}</fills>
<borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border><left/><right/><top/><bottom style="thin"><color rgb="FF1B2422"/></bottom><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="${order.length}">${order.map((s) => xfs[s]).join()}</cellXfs>
</styleSheet>''');

  for (var i = 0; i < n; i++) {
    final sh = sheets[i];
    final sb = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">');
    if (sh.freezeRows > 0 || sh.freezeCols > 0) {
      final tl = '${columnName(sh.freezeCols + 1)}${sh.freezeRows + 1}';
      final pane = sh.freezeRows > 0 && sh.freezeCols > 0 ? 'bottomRight' : sh.freezeRows > 0 ? 'bottomLeft' : 'topRight';
      sb.write('<sheetViews><sheetView workbookViewId="0"${i == 0 ? ' tabSelected="1"' : ''}><pane'
          '${sh.freezeCols > 0 ? ' xSplit="${sh.freezeCols}"' : ''}${sh.freezeRows > 0 ? ' ySplit="${sh.freezeRows}"' : ''}'
          ' topLeftCell="$tl" activePane="$pane" state="frozen"/></sheetView></sheetViews>');
    }
    if (sh.widths.isNotEmpty) {
      sb.write('<cols>');
      for (var c = 0; c < sh.widths.length; c++) {
        sb.write('<col min="${c + 1}" max="${c + 1}" width="${sh.widths[c]}" customWidth="1"/>');
      }
      sb.write('</cols>');
    }
    sb.write('<sheetData>');
    var maxCol = 0;
    for (var r = 0; r < sh.rows.length; r++) {
      sb.write('<row r="${r + 1}">');
      final row = sh.rows[r];
      if (row.length > maxCol) maxCol = row.length;
      for (var c = 0; c < row.length; c++) {
        final cell = row[c];
        if (cell == null) continue;
        final ref = '${columnName(c + 1)}${r + 1}';
        final s = ' s="${order.indexOf(cell.style)}"';
        final v = cell.value;
        if (cell.formula != null) {
          final cached = v is num ? '<v>$v</v>' : '';
          sb.write('<c r="$ref"$s><f>${_esc(cell.formula!)}</f>$cached</c>');
        } else if (v is num) {
          sb.write('<c r="$ref"$s><v>$v</v></c>');
        } else if (v is DateTime) {
          final serial = v.difference(DateTime(1899, 12, 30)).inMinutes / 1440;
          sb.write('<c r="$ref"$s><v>$serial</v></c>');
        } else if (v != null) {
          sb.write('<c r="$ref" t="inlineStr"$s><is><t xml:space="preserve">${_esc(v.toString())}</t></is></c>');
        } else {
          sb.write('<c r="$ref"$s/>');
        }
      }
      sb.write('</row>');
    }
    sb.write('</sheetData>');
    if (sh.protect) sb.write('<sheetProtection sheet="1" objects="1" scenarios="1" formatColumns="0" formatRows="0" sort="0" autoFilter="0"/>');
    if (sh.autoFilter && sh.rows.isNotEmpty && maxCol > 0) {
      sb.write('<autoFilter ref="A1:${columnName(maxCol)}${sh.rows.length}"/>');
    }
    sb.write('</worksheet>');
    add('xl/worksheets/sheet${i + 1}.xml', sb.toString());
  }
  return ZipEncoder().encodeBytes(archive);
}
