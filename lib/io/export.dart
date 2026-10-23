import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/models.dart';
import '../l10n/strings.dart';
import 'xlsx.dart';

enum ExportFormat { xlsx, csv }

/// Flat list of transactions: one row per operation, headers in the app language.
List<List<Object?>> transactionRows({
  required List<Txn> txns,
  required String Function(int?) categoryName,
  required String Function(int?) accountName,
  required String baseCurrency,
  required int? Function(Txn) toBase,
}) {
  final date = DateFormat('yyyy-MM-dd');
  final time = DateFormat('HH:mm');
  return [
    [
      tr('col_date'), tr('col_time'), tr('col_type'), tr('col_amount'), tr('currency'), tr('col_my_share'),
      tr('col_amount_in', [baseCurrency]), tr('category'), tr('account'), tr('payee'), tr('comment'), tr('col_source'),
    ],
    for (final t in txns)
      [
        date.format(t.time),
        time.format(t.time),
        t.kind == TxnKind.income ? tr('income_one') : tr('expense'),
        (t.kind == TxnKind.income ? 1 : -1) * t.amountMinor / 100,
        t.currency,
        t.isSplit ? -t.shareMinor! / 100 : null,
        t.excluded ? null : switch (toBase(t)) { null => null, final v => (t.kind == TxnKind.income ? 1 : -1) * v / 100 },
        categoryName(t.categoryId),
        accountName(t.accountId),
        t.merchant ?? '',
        [if (t.excluded) tr('debt_repaid'), t.note ?? ''].where((s) => s.isNotEmpty).join('; '),
        switch (t.source) {
          'manual' => tr('src_manual'),
          'excel' => tr('src_excel'),
          final s => tr('src_auto', [s]),
        },
      ],
  ];
}

String toCsv(List<List<Object?>> rows) {
  String cell(Object? v) {
    if (v == null) return '';
    final s = v is double ? v.toStringAsFixed(2) : v.toString();
    return RegExp(r'[",\n\r]').hasMatch(s) ? '"${s.replaceAll('"', '""')}"' : s;
  }

  // BOM so Excel opens UTF-8 (Chinese merchant names, Cyrillic) correctly.
  return '﻿${rows.map((r) => r.map(cell).join(',')).join('\r\n')}\r\n';
}

/// Writes the file to the temp dir and opens the system share sheet
/// (save to Files/Drive, send to WeChat/Telegram/e-mail…).
Future<void> shareExport({
  required List<List<Object?>> rows,
  required ExportFormat format,
  required String fileBaseName,
}) async {
  final dir = await getTemporaryDirectory();
  final Uint8List bytes;
  final String ext;
  final String mime;
  switch (format) {
    case ExportFormat.xlsx:
      bytes = writeXlsx({'Transactions': rows}, columnWidths: {
        'Transactions': [11, 7, 9, 11, 7, 11, 13, 18, 12, 24, 30, 18],
      });
      ext = 'xlsx';
      mime = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    case ExportFormat.csv:
      bytes = Uint8List.fromList(utf8.encode(toCsv(rows)));
      ext = 'csv';
      mime = 'text/csv';
  }
  final file = File('${dir.path}/$fileBaseName.$ext');
  await file.writeAsBytes(bytes);
  await SharePlus.instance.share(ShareParams(files: [XFile(file.path, mimeType: mime)], subject: fileBaseName));
}
