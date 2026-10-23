import 'dart:typed_data';

import '../data/models.dart';
import '../data/repository.dart';
import 'xlsx.dart';

/// Imports the user's own spreadsheet layout:
/// - expense sheets: row 1 = "Категория / дата" + day dates, rows below = categories until "Итого…",
///   cells = amounts, often formulas of individual purchases ("38+11+29.9"), notes in cell comments;
///   "Выделено на месяц" = month budget;
/// - income sheets: a header row with "Дата", "Сумма" (+ "Источник", "Комментарий") and one income per row.
class SheetImportPlan {
  final List<Txn> expenses;
  final List<Txn> incomes;

  /// month -> budget (minor units)
  final Map<DateTime, int> budgets;

  /// category names from the sheet that don't exist yet (will be created)
  final Set<String> newCategories;

  /// sheet name -> (count, total minor) for the preview
  final Map<String, (int, int)> perSheet;
  final String currency;

  SheetImportPlan({
    required this.expenses,
    required this.incomes,
    required this.budgets,
    required this.newCategories,
    required this.perSheet,
    required this.currency,
  });

  bool get isEmpty => expenses.isEmpty && incomes.isEmpty;
}

const excelSource = 'excel';

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'\(.*?\)'), '').replaceAll('ё', 'е').trim();

final _simpleSum = RegExp(r'^\s*\d+(?:[.,]\d+)?(?:\s*\+\s*\d+(?:[.,]\d+)?)*\s*$');

/// "38+11+29.9" -> [3800, 1100, 2990]; otherwise the cached cell value as one amount.
List<int> splitAmounts(XlsxCell cell) {
  final f = cell.formula;
  if (f != null && _simpleSum.hasMatch(f)) {
    return [
      for (final p in f.split('+'))
        if ((double.tryParse(p.trim().replaceAll(',', '.')) ?? 0) > 0) (double.parse(p.trim().replaceAll(',', '.')) * 100).round(),
    ];
  }
  final v = cell.number;
  if (v == null || v <= 0) return const [];
  return [(v * 100).round()];
}

Future<SheetImportPlan> planSheetImport(
  Uint8List bytes, {
  required List<Category> categories,
  required String currency,
}) async {
  final sheets = readXlsx(bytes);
  final expenseCats = {for (final c in categories.where((c) => c.kind == TxnKind.expense)) _norm(c.name): c};
  final incomeOther = categories.where((c) => c.kind == TxnKind.income && _norm(c.name) == 'другое').firstOrNull;

  final expenses = <Txn>[];
  final incomes = <Txn>[];
  final budgets = <DateTime, int>{};
  final newCategories = <String>{};
  final perSheet = <String, (int, int)>{};

  for (final sheet in sheets) {
    final header = sheet.text(1, 1)?.toLowerCase() ?? '';

    // --- Expense grid ---
    if (header.contains('категория') && header.contains('дата')) {
      final dates = <int, DateTime>{};
      for (var col = 2; col <= sheet.maxCol; col++) {
        final n = sheet.at(1, col)?.number;
        if (n != null && n > 20000 && n < 80000) dates[col] = excelDate(n);
      }
      if (dates.isEmpty) continue;

      var count = 0, total = 0;
      for (var row = 2; row <= sheet.maxRow; row++) {
        final name = sheet.text(row, 1)?.trim();
        if (name == null || name.isEmpty) continue;
        if (name.toLowerCase().startsWith('итого')) break;
        final cat = expenseCats[_norm(name)];
        final catName = cat?.name ?? name.replaceAll(RegExp(r'\s*\(.*?\)\s*'), '').trim();
        if (cat == null) newCategories.add(catName);

        for (final entry in dates.entries) {
          final cell = sheet.at(row, entry.key);
          if (cell == null) continue;
          final parts = splitAmounts(cell);
          if (parts.isEmpty) continue;
          final note = sheet.comments['${columnName(entry.key)}$row'];
          final day = entry.value;
          for (var i = 0; i < parts.length; i++) {
            expenses.add(Txn(
              // Order within the day as written; the real time is unknown.
              time: DateTime(day.year, day.month, day.day, 12, i),
              amountMinor: parts[i],
              currency: currency,
              kind: TxnKind.expense,
              categoryId: cat?.id,
              note: note,
              merchant: cat == null ? catName : null, // resolved to a new category on apply
              source: excelSource,
            ));
            count++;
            total += parts[i];
          }
        }
      }

      // "Выделено на месяц" -> budget of that month
      for (var row = 1; row <= sheet.maxRow; row++) {
        if ((sheet.text(row, 1) ?? '').toLowerCase().startsWith('выделено')) {
          for (var col = 2; col <= 6; col++) {
            final v = sheet.at(row, col)?.number;
            if (v != null && v > 0) {
              final first = dates.values.first;
              budgets[DateTime(first.year, first.month)] = (v * 100).round();
              break;
            }
          }
        }
      }
      if (count > 0) perSheet[sheet.name] = (count, total);
      continue;
    }

    // --- Income list ---
    for (var row = 1; row <= 10 && row <= sheet.maxRow; row++) {
      int? dateCol, amountCol, sourceCol, commentCol;
      for (var col = 1; col <= sheet.maxCol; col++) {
        final h = (sheet.text(row, col) ?? '').toLowerCase();
        if (h == 'дата') dateCol = col;
        if (h.startsWith('сумма')) amountCol = col;
        if (h.startsWith('источник')) sourceCol = col;
        if (h.startsWith('коммент')) commentCol = col;
      }
      if (dateCol == null || amountCol == null) continue;

      var count = 0, total = 0;
      for (var r = row + 1; r <= sheet.maxRow; r++) {
        final d = sheet.at(r, dateCol)?.number;
        final a = sheet.at(r, amountCol)?.number;
        if (d == null || a == null || a <= 0) continue;
        final day = excelDate(d);
        final minor = (a * 100).round();
        incomes.add(Txn(
          time: DateTime(day.year, day.month, day.day, 12),
          amountMinor: minor,
          currency: currency,
          kind: TxnKind.income,
          categoryId: incomeOther?.id,
          merchant: sourceCol == null ? null : sheet.text(r, sourceCol),
          note: commentCol == null ? null : sheet.text(r, commentCol),
          source: excelSource,
        ));
        count++;
        total += minor;
      }
      if (count > 0) perSheet[sheet.name] = (count, total);
      break;
    }
  }

  return SheetImportPlan(
    expenses: expenses,
    incomes: incomes,
    budgets: budgets,
    newCategories: newCategories,
    perSheet: perSheet,
    currency: currency,
  );
}

/// Replaces everything imported from Excel before with [plan] (so re-importing a newer file is safe).
Future<void> applySheetImport(Repository repo, SheetImportPlan plan) async {
  await repo.deleteBySource(excelSource);

  const palette = [0xFF6A6AD9, 0xFFC9A227, 0xFF2BA3B5, 0xFFD9506A, 0xFF4C9A6A];
  final created = <String, int>{};
  var i = 0;
  for (final name in plan.newCategories) {
    created[name] = await repo.addCategory(name, TxnKind.expense, 'more_horiz', palette[i++ % palette.length]);
  }

  final expenses = [
    for (final t in plan.expenses)
      t.categoryId != null
          ? t
          : t.copyWith(categoryId: () => created[t.merchant], merchant: () => null),
  ];
  await repo.insertTxns([...expenses, ...plan.incomes]);
  for (final e in plan.budgets.entries) {
    await repo.setBudget(e.key, e.value, plan.currency);
  }
}
