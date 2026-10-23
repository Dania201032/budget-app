import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:budget_app/data/database.dart';
import 'package:budget_app/data/models.dart';
import 'package:budget_app/data/repository.dart';
import 'package:budget_app/io/export.dart';
import 'package:budget_app/io/sheet_import.dart';
import 'package:budget_app/io/xlsx.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A small workbook in the same layout as the user's "Расходы (октябрь)" + "Доходы на месте".
Uint8List _fixture() {
  final a = Archive();
  void add(String n, String c) => a.addFile(ArchiveFile.bytes(n, utf8.encode(c)));
  const ns = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';
  add('xl/workbook.xml', '<workbook $ns><sheets>'
      '<sheet name="Расходы (октябрь)" sheetId="9" r:id="rId6"/>'
      '<sheet name="Доходы на месте" sheetId="4" r:id="rId4"/>'
      '</sheets></workbook>');
  add('xl/_rels/workbook.xml.rels', '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId6" Type="x" Target="worksheets/sheet6.xml"/>'
      '<Relationship Id="rId4" Type="x" Target="/xl/worksheets/sheet4.xml"/>'
      '<Relationship Id="rId12" Type="x" Target="sharedStrings.xml"/></Relationships>');
  const strings = ['Категория / дата', 'Еда', 'Транспорт', 'Другое (с комментарием)', 'Итого за день', 'Выделено на месяц',
      'Дата', 'Источник', 'Сумма (¥)', 'Комментарий', 'Сдача крови', 'Тренировка', 'Подарки'];
  add('xl/sharedStrings.xml', '<sst $ns>${strings.map((s) => '<si><t>$s</t></si>').join()}</sst>');
  String s(String ref, int i) => '<c r="$ref" t="s"><v>$i</v></c>';
  add('xl/worksheets/sheet6.xml', '<worksheet $ns><sheetData>'
      '<row r="1">${s('A1', 0)}<c r="B1"><v>46296</v></c><c r="C1"><f>IF(B1="","",B1+1)</f><v>46297</v></c></row>'
      '<row r="2">${s('A2', 1)}<c r="B2" s="46"><f>38+11+29.9</f><v>78.900000000000006</v></c><c r="C2"><v>27</v></c></row>'
      '<row r="3">${s('A3', 2)}<c r="C3"><f>4+4</f><v>8</v></c></row>'
      '<row r="4">${s('A4', 3)}<c r="B4"><v>4.49</v></c></row>'
      '<row r="5">${s('A5', 12)}<c r="C5"><v>100</v></c></row>'
      '<row r="6">${s('A6', 4)}<c r="B6"><f>SUM(B2:B5)</f><v>83.39</v></c></row>'
      '<row r="13">${s('A13', 5)}<c r="D13"><v>3000</v></c></row>'
      '</sheetData></worksheet>');
  add('xl/worksheets/_rels/sheet6.xml.rels', '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId2" Type="comments" Target="../comments1.xml"/></Relationships>');
  add('xl/comments1.xml', '<comments $ns><authors><author>Иван</author></authors><commentList>'
      '<comment ref="B4" authorId="0"><text><r><t>Иван:</t></r><r><t xml:space="preserve">\nСтирка\n</t></r></text></comment>'
      '</commentList></comments>');
  add('xl/worksheets/sheet4.xml', '<worksheet $ns><sheetData>'
      '<row r="4">${s('A4', 6)}${s('B4', 7)}${s('C4', 8)}${s('D4', 9)}</row>'
      '<row r="5"><c r="A5"><v>46308</v></c>${s('B5', 10)}<c r="C5"><v>200</v></c>${s('D5', 11)}</row>'
      '</sheetData></worksheet>');
  return ZipEncoder().encodeBytes(a);
}

void main() {
  sqfliteFfiInit();
  late Database db;
  late Repository repo;

  setUp(() async {
    db = await openAppDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    repo = Repository(db);
  });
  tearDown(() => db.close());

  test('reads cells, formulas and comments', () {
    final sheets = readXlsx(_fixture());
    expect(sheets.map((s) => s.name), ['Расходы (октябрь)', 'Доходы на месте']);
    final oct = sheets.first;
    expect(oct.at(2, 2)?.formula, '38+11+29.9');
    expect(oct.at(2, 2)?.number, closeTo(78.9, 1e-9));
    expect(oct.text(1, 1), 'Категория / дата');
    expect(oct.comments['B4'], 'Стирка');
    expect(excelDate(46296), DateTime(2026, 10, 1));
  });

  test('plans expenses per purchase, incomes, budgets and new categories', () async {
    final plan = await planSheetImport(_fixture(), categories: await repo.categories(), currency: 'CNY');

    final amounts = plan.expenses.map((t) => t.amountMinor).toList();
    expect(amounts, [3800, 1100, 2990, 2700, 400, 400, 449, 10000]);
    expect(plan.expenses.first.time, DateTime(2026, 10, 1, 12, 0));
    expect(plan.expenses.where((t) => t.note == 'Стирка').single.amountMinor, 449);
    expect(plan.newCategories, {'Подарки'});
    expect(plan.budgets, {DateTime(2026, 10): 300000});
    expect(plan.perSheet['Расходы (октябрь)'], (8, 21839));

    expect(plan.incomes.single.amountMinor, 20000);
    expect(plan.incomes.single.merchant, 'Сдача крови');
    expect(plan.incomes.single.time, DateTime(2026, 10, 13, 12));
  });

  test('apply creates categories and is idempotent', () async {
    final plan = await planSheetImport(_fixture(), categories: await repo.categories(), currency: 'CNY');
    await applySheetImport(repo, plan);
    await applySheetImport(repo, await planSheetImport(_fixture(), categories: await repo.categories(), currency: 'CNY'));

    final all = await repo.allTxns();
    expect(all.where((t) => t.kind == TxnKind.expense), hasLength(8));
    expect(all.where((t) => t.kind == TxnKind.income), hasLength(1));
    final gifts = (await repo.categories()).where((c) => c.name == 'Подарки');
    expect(gifts, hasLength(1));
    expect(all.where((t) => t.categoryId == gifts.single.id).single.amountMinor, 10000);
    expect(await repo.budgetFor(DateTime(2026, 10)), (300000, 'CNY'));
  });

  test('export: xlsx round-trips and CSV escapes', () {
    final rows = <List<Object?>>[
      ['Дата', 'Сумма', 'Где / кому'],
      ['2026-10-12', -50.0, '全家便利店'],
      ['2026-10-12', -7.5, 'a, "b"'],
    ];
    final back = readXlsx(writeXlsx({'Операции': rows})).single;
    expect(back.text(2, 3), '全家便利店');
    expect(back.at(3, 2)?.number, -7.5);
    final csv = toCsv(rows);
    expect(csv.startsWith('\uFEFF'), isTrue);
    expect(csv, contains('"a, ""b"""'));
  });

  // Optional check against a local copy of the user's real file (not committed).
  final real = File(r'D:\dev\tmp\sheet_copy.xlsx');
  test('real October sheet matches its own month total', () async {
    final bytes = real.readAsBytesSync();
    final sheetTotal = readXlsx(bytes).firstWhere((s) => s.name == 'Расходы (октябрь)').cells['AG7']!.number!;
    final plan = await planSheetImport(bytes, categories: await repo.categories(), currency: 'CNY');
    final october = plan.expenses.where((t) => t.time.month == 10).fold<int>(0, (s, t) => s + t.amountMinor);
    expect(october, (sheetTotal * 100).round()); // "Сумма за месяц" / "Итого за день" total
    expect(plan.budgets[DateTime(2026, 10)], 300000);
  }, skip: real.existsSync() ? false : 'no local copy');
}
