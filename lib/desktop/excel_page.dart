import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../domain/currencies.dart';
import '../io/xlsx.dart' show columnName;
import '../io/xlsx_book.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../ui/ledger.dart';
import 'documents_page.dart' show documentsDir, openPath;
import 'kit.dart';
import 'shell.dart';

/// Everything the Excel builder lets the user choose; saved so the nightly update repeats it.
class XOpts {
  String layout = 'days'; // days | ops | months | all
  String period = 'month'; // month | quarter | year | all
  bool perMonth = true, perAccount = false, summary = true;
  bool freeze = true, filter = false, totals = true, limit = true, over = true, heat = false;
  bool formulas = true, weeks = false, protect = true;
  String theme = 'ledger'; // ledger | neutral | plain
  bool decimals = true;
  String dateStyle = 'dmy'; // dmy | iso | mdy | short
  String money = 'sym'; // sym | code | none
  String lang = currentLanguage;
  List<String> cols = ['date', 'payee', 'category', 'account', 'amount', 'base', 'note'];
  String fileName = '';
  bool auto = false;
  String preset = 'budget';

  Map<String, Object?> toJson() => {
        'layout': layout, 'period': period, 'perMonth': perMonth, 'perAccount': perAccount, 'summary': summary,
        'freeze': freeze, 'filter': filter, 'totals': totals, 'limit': limit, 'over': over, 'heat': heat,
        'formulas': formulas, 'weeks': weeks, 'protect': protect, 'theme': theme, 'decimals': decimals,
        'dateStyle': dateStyle, 'money': money, 'lang': lang, 'cols': cols, 'fileName': fileName, 'auto': auto, 'preset': preset,
      };

  static XOpts fromJson(String s) {
    final o = XOpts();
    if (s.isEmpty) return o;
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      o
        ..layout = j['layout'] as String? ?? o.layout
        ..period = j['period'] as String? ?? o.period
        ..perMonth = j['perMonth'] as bool? ?? o.perMonth
        ..perAccount = j['perAccount'] as bool? ?? o.perAccount
        ..summary = j['summary'] as bool? ?? o.summary
        ..freeze = j['freeze'] as bool? ?? o.freeze
        ..filter = j['filter'] as bool? ?? o.filter
        ..totals = j['totals'] as bool? ?? o.totals
        ..limit = j['limit'] as bool? ?? o.limit
        ..over = j['over'] as bool? ?? o.over
        ..heat = j['heat'] as bool? ?? o.heat
        ..formulas = j['formulas'] as bool? ?? o.formulas
        ..weeks = j['weeks'] as bool? ?? o.weeks
        ..protect = j['protect'] as bool? ?? o.protect
        ..theme = j['theme'] as String? ?? o.theme
        ..decimals = j['decimals'] as bool? ?? o.decimals
        ..dateStyle = j['dateStyle'] as String? ?? o.dateStyle
        ..money = j['money'] as String? ?? o.money
        ..lang = j['lang'] as String? ?? o.lang
        ..cols = ((j['cols'] as List?) ?? o.cols).whereType<String>().toList()
        ..fileName = j['fileName'] as String? ?? ''
        ..auto = j['auto'] as bool? ?? false
        ..preset = j['preset'] as String? ?? '';
    } catch (_) {}
    return o;
  }

  void applyPreset(String p) {
    preset = p;
    switch (p) {
      case 'budget':
        layout = 'days';
        perMonth = true;
        perAccount = false;
        summary = true;
        freeze = totals = limit = over = formulas = protect = true;
        filter = heat = weeks = false;
        theme = 'ledger';
        money = 'sym';
      case 'accountant':
        layout = 'ops';
        perMonth = perAccount = summary = false;
        freeze = filter = totals = formulas = true;
        limit = over = heat = weeks = protect = false;
        theme = 'plain';
        dateStyle = 'iso';
        money = 'code';
        cols = ['date', 'time', 'payee', 'category', 'account', 'amount', 'base', 'rate', 'note', 'source'];
      case 'totals':
        layout = 'months';
        perMonth = perAccount = false;
        summary = true;
        freeze = totals = limit = over = heat = formulas = protect = true;
        filter = weeks = false;
        theme = 'neutral';
        decimals = false;
        money = 'none';
    }
  }

  String get numberFormat {
    final n = decimals ? '#,##0.00' : '#,##0';
    return n;
  }

  String numberFormatFor(String currency) => switch (money) {
        'code' => '$n "$currency"',
        'sym' => '$n "${currencySymbol(currency)}"',
        _ => n,
      };

  String get n => decimals ? '#,##0.00' : '#,##0';

  String get excelDate => switch (dateStyle) { 'iso' => 'yyyy-mm-dd', 'mdy' => 'mm/dd/yyyy', 'short' => 'd mmm', _ => 'dd.mm.yyyy' };

  XTheme get xtheme => switch (theme) { 'neutral' => XTheme.neutral, 'plain' => XTheme.plain, _ => XTheme.ledger };
}

/// The period the options cover.
(DateTime, DateTime)? _range(XOpts o) {
  final now = DateTime.now();
  return switch (o.period) {
    'month' => (DateTime(now.year, now.month), DateTime(now.year, now.month + 1)),
    'quarter' => (DateTime(now.year, now.month - 2), DateTime(now.year, now.month + 1)),
    'year' => (DateTime(now.year), DateTime(now.year + 1)),
    _ => null,
  };
}

Future<List<Txn>> _txnsFor(AppState s, XOpts o) async {
  final r = _range(o);
  if (r == null) return s.txnsForExport(null);
  return (await s.txnsForExport(null)).where((t) => !t.time.isBefore(r.$1) && t.time.isBefore(r.$2)).toList();
}

/// Builds the workbook in the options' language.
List<XSheet> buildBook(AppState s, DeskController desk, XOpts o, List<Txn> txns) {
  final saved = currentLanguage;
  currentLanguage = o.lang;
  try {
    return _Book(s, desk, o, txns).sheets();
  } finally {
    currentLanguage = saved;
  }
}

class _Book {
  final AppState s;
  final DeskController desk;
  final XOpts o;
  final List<Txn> txns;
  _Book(this.s, this.desk, this.o, this.txns);

  double? base(Txn t) => switch (s.toBase(t)) { null => null, final v => v / 100 };

  String cat(int? id) => id == null ? tr('d_uncategorized') : (s.categoryById[id] == null ? '—' : s.categoryName(s.categoryById[id]!));

  List<DateTime> get months {
    final r = _range(o);
    var from = r?.$1, to = r?.$2;
    if (r == null) {
      if (txns.isEmpty) return [DateTime(DateTime.now().year, DateTime.now().month)];
      final times = txns.map((t) => t.time).toList()..sort();
      from = DateTime(times.first.year, times.first.month);
      to = DateTime(times.last.year, times.last.month + 1);
    }
    return [for (var m = from!; m.isBefore(to!); m = DateTime(m.year, m.month + 1)) m];
  }

  List<XSheet> sheets() {
    final out = <XSheet>[];
    final ms = months;
    if (o.summary || o.layout == 'all') out.add(summary(ms));
    switch (o.layout) {
      case 'days':
        if (o.perAccount) {
          for (final a in s.accounts) {
            final list = txns.where((t) => t.accountId == a.id).toList();
            if (list.isNotEmpty) out.add(days(ms.last, list, s.accountName(a)));
          }
        } else if (o.perMonth) {
          for (final m in ms) {
            out.add(days(m, txns, DateFormat.yMMM(o.lang).format(m)));
          }
        } else {
          out.add(days(ms.last, txns, tr('d_x_spending')));
        }
      case 'ops':
        if (o.perAccount) {
          for (final a in s.accounts) {
            final list = txns.where((t) => t.accountId == a.id).toList();
            if (list.isNotEmpty) out.add(ops(list, s.accountName(a)));
          }
        } else if (o.perMonth) {
          for (final m in ms) {
            out.add(ops(txns.where((t) => t.time.year == m.year && t.time.month == m.month).toList(), DateFormat.yMMM(o.lang).format(m)));
          }
        } else {
          out.add(ops(txns, tr('d_x_operations')));
        }
      case 'months':
        out.add(monthsSheet(ms));
      default:
        for (final m in ms.reversed.take(12).toList().reversed) {
          out.add(days(m, txns, DateFormat.yMMM(o.lang).format(m)));
        }
        out.add(ops(txns, tr('d_x_operations')));
        out.add(monthsSheet(ms));
    }
    return out;
  }

  XSheet summary(List<DateTime> ms) {
    final rows = <List<XCell?>>[
      [XCell(tr('d_x_month'), style: XStyle.header), XCell(tr('d_spent'), style: XStyle.header), XCell(tr('d_incomes'), style: XStyle.header),
        XCell(tr('d_difference'), style: XStyle.header), XCell(tr('d_budget'), style: XStyle.header)],
    ];
    for (final m in ms) {
      var sp = 0.0, inc = 0.0;
      for (final t in txns) {
        if (t.excluded || t.time.year != m.year || t.time.month != m.month) continue;
        final v = base(t) ?? 0;
        t.kind == TxnKind.income ? inc += v : sp += v;
      }
      final r = rows.length + 1;
      rows.add([
        XCell(DateFormat.yMMMM(o.lang).format(m), style: XStyle.label),
        XCell(_r(sp), style: XStyle.number),
        XCell(_r(inc), style: XStyle.number),
        o.formulas ? XCell(_r(inc - sp), formula: 'C$r-B$r', style: XStyle.number) : XCell(_r(inc - sp), style: XStyle.number),
        XCell(s.rawMonthBudget(m) / 100, style: o.protect ? XStyle.input : XStyle.number),
      ]);
    }
    if (o.totals && ms.length > 1) {
      final last = rows.length;
      rows.add([
        XCell(tr('d_total'), style: XStyle.totalLabel),
        for (final c in ['B', 'C', 'D', 'E'])
          XCell(null, formula: o.formulas ? 'SUM(${c}2:$c$last)' : null, style: XStyle.total),
      ]);
    }
    return XSheet(tr('d_x_summary'), rows, widths: [22, 14, 14, 14, 14], freezeRows: o.freeze ? 1 : 0, protect: o.protect && o.formulas);
  }

  /// Categories × days of [m] (or weeks), with day totals, the daily limit and what is left.
  XSheet days(DateTime m, List<Txn> list, String name) {
    final n = DateTime(m.year, m.month + 1, 0).day;
    final groups = o.weeks
        ? () {
            final g = <(String, List<int>)>[];
            var start = 1;
            while (start <= n) {
              final wd = DateTime(m.year, m.month, start).weekday;
              final end = (start + 7 - wd).clamp(start, n);
              g.add(('$start–$end', [for (var d = start; d <= end; d++) d]));
              start = end + 1;
            }
            return g;
          }()
        : [for (var d = 1; d <= n; d++) ('$d', [d])];
    final sums = <int?, List<double>>{};
    final dayTotal = List.filled(groups.length, 0.0);
    for (final t in list) {
      if (t.excluded || t.kind != TxnKind.expense || t.time.year != m.year || t.time.month != m.month) continue;
      final gi = groups.indexWhere((g) => g.$2.contains(t.time.day));
      final v = base(t) ?? 0;
      sums.putIfAbsent(t.categoryId, () => List.filled(groups.length, 0.0))[gi] += v;
      dayTotal[gi] += v;
    }
    final cats = [
      for (final c in s.categoriesOf(TxnKind.expense)) if (sums.containsKey(c.id) || desk.profile.categoryPlan.containsKey(c.id)) c.id,
      if (sums.containsKey(null)) null,
    ];
    final lastCol = columnName(groups.length + 1);
    final totalCol = columnName(groups.length + 2);
    final budget = s.rawMonthBudget(m) / 100;
    final perDay = budget / n;
    final maxCell = sums.values.expand((l) => l).fold<double>(1, (a, b) => b > a ? b : a);
    XStyle heat(double v) {
      if (!o.heat || v == 0) return XStyle.number;
      final k = v / maxCell;
      return k > .66 ? XStyle.heat3 : k > .33 ? XStyle.heat2 : XStyle.heat1;
    }

    final rows = <List<XCell?>>[
      [XCell(tr('category'), style: XStyle.header), for (final g in groups) XCell(g.$1, style: XStyle.header), if (o.totals) XCell(tr('d_total'), style: XStyle.header)],
    ];
    for (final id in cats) {
      final r = rows.length + 1;
      final v = sums[id] ?? List.filled(groups.length, 0.0);
      rows.add([
        XCell(cat(id), style: XStyle.label),
        for (final x in v) x == 0 ? null : XCell(_r(x), style: heat(x)),
        if (o.totals) XCell(_r(v.fold(0.0, (a, b) => a + b)), formula: o.formulas ? 'SUM(B$r:$lastCol$r)' : null, style: XStyle.total),
      ]);
    }
    final catRows = rows.length;
    final totalRow = rows.length + 1;
    if (o.totals) {
      rows.add([
        XCell(tr('d_x_day_total'), style: XStyle.totalLabel),
        for (var g = 0; g < groups.length; g++)
          XCell(_r(dayTotal[g]),
              formula: o.formulas ? 'SUM(${columnName(g + 2)}2:${columnName(g + 2)}$catRows)' : null,
              style: o.over && budget > 0 && dayTotal[g] > perDay * groups[g].$2.length ? XStyle.over : XStyle.total),
        XCell(_r(dayTotal.fold(0.0, (a, b) => a + b)), formula: o.formulas ? 'SUM(B$totalRow:$lastCol$totalRow)' : null, style: XStyle.total),
      ]);
    }
    if (o.limit && budget > 0) {
      final lr = rows.length + 1;
      rows.add([
        XCell(tr('d_x_limit'), style: XStyle.label),
        for (final g in groups)
          XCell(_r(perDay * g.$2.length),
              formula: o.formulas && o.totals ? '\$$totalCol\$$lr/$n*${g.$2.length}' : null, style: XStyle.number),
        if (o.totals) XCell(budget, style: XStyle.input),
      ]);
      if (o.totals) {
        var cum = 0.0;
        rows.add([
          XCell(tr('d_x_left'), style: XStyle.label),
          for (var g = 0; g < groups.length; g++)
            () {
              cum += dayTotal[g];
              return XCell(_r(budget - cum),
                  formula: o.formulas ? '\$$totalCol\$$lr-SUM(\$B\$$totalRow:${columnName(g + 2)}\$$totalRow)' : null,
                  style: budget - cum < 0 ? XStyle.over : XStyle.number);
            }(),
          XCell(_r(budget - cum), formula: o.formulas ? '$totalCol$lr-$totalCol$totalRow' : null, style: XStyle.total),
        ]);
      }
    }
    return XSheet(name, rows,
        widths: [22, for (final _ in groups) o.weeks ? 12 : 8, 12],
        freezeRows: o.freeze ? 1 : 0,
        freezeCols: o.freeze ? 1 : 0,
        protect: o.protect && o.formulas);
  }

  XSheet ops(List<Txn> list, String name) {
    final cols = [
      for (final c in ['date', 'time', 'payee', 'category', 'account', 'amount', 'currency', 'base', 'rate', 'note', 'source'])
        if (o.cols.contains(c) || (c == 'currency' && o.cols.contains('amount'))) c,
    ];
    final label = {
      'date': tr('col_date'), 'time': tr('col_time'), 'payee': tr('payee'), 'category': tr('category'), 'account': tr('account'),
      'amount': tr('col_amount'), 'currency': tr('currency'), 'base': tr('d_x_in_base', [s.baseCurrency]), 'rate': tr('d_x_rate'),
      'note': tr('comment'), 'source': tr('d_source'),
    };
    final sorted = [...list]..sort((a, b) => a.time.compareTo(b.time));
    final large = (s.todayStats?.dailyLimit ?? 0) > 0 ? s.todayStats!.dailyLimit * 3 / 100 : 200.0;
    final rows = <List<XCell?>>[
      [for (final c in cols) XCell(label[c], style: XStyle.header)],
    ];
    for (final t in sorted) {
      final sign = t.kind == TxnKind.income ? 1 : -1;
      final b = base(t);
      final big = o.over && t.kind == TxnKind.expense && (b ?? 0) >= large;
      rows.add([
        for (final c in cols)
          switch (c) {
            'date' => XCell(DateTime(t.time.year, t.time.month, t.time.day), style: XStyle.date),
            'time' => XCell(DateFormat.Hm().format(t.time), style: XStyle.muted),
            'payee' => XCell(t.merchant ?? ''),
            'category' => XCell(t.categoryId == null ? '' : cat(t.categoryId)),
            'account' => XCell(t.accountId == null || s.accountById[t.accountId] == null ? '' : s.accountName(s.accountById[t.accountId]!)),
            'amount' => XCell(sign * t.amountMinor / 100, style: big ? XStyle.over : XStyle.number),
            'currency' => XCell(t.currency, style: XStyle.muted),
            'base' => XCell(t.excluded || b == null ? null : _r(sign * b), style: big ? XStyle.over : XStyle.number),
            'rate' => XCell(b == null || b == 0 ? null : double.parse((t.effectiveMinor / 100 / b).toStringAsFixed(4)), style: XStyle.muted),
            'note' => XCell(t.note ?? ''),
            _ => XCell(t.source),
          },
      ]);
    }
    if (o.totals) {
      final bi = cols.indexOf('base');
      if (bi >= 0) {
        final col = columnName(bi + 1);
        final sum = sorted.where((t) => !t.excluded).fold<double>(0, (a, t) => a + (t.kind == TxnKind.income ? 1 : -1) * (base(t) ?? 0));
        rows.add([
          for (var i = 0; i < cols.length; i++)
            i == 0
                ? XCell(tr('d_total'), style: XStyle.totalLabel)
                : i == bi
                    ? XCell(_r(sum), formula: o.formulas ? 'SUBTOTAL(9,${col}2:$col${rows.length})' : null, style: XStyle.total)
                    : const XCell(null, style: XStyle.total),
        ]);
      }
    }
    return XSheet(name, rows,
        widths: [for (final c in cols) switch (c) { 'payee' || 'note' => 26.0, 'category' || 'account' => 18.0, 'time' || 'currency' || 'rate' => 8.0, _ => 13.0 }],
        freezeRows: o.freeze ? 1 : 0,
        autoFilter: o.filter);
  }

  XSheet monthsSheet(List<DateTime> ms) {
    final shown = ms.length > 24 ? ms.sublist(ms.length - 24) : ms;
    final sums = <int?, List<double>>{};
    for (final t in txns) {
      if (t.excluded || t.kind != TxnKind.expense) continue;
      final i = shown.indexWhere((m) => m.year == t.time.year && m.month == t.time.month);
      if (i < 0) continue;
      sums.putIfAbsent(t.categoryId, () => List.filled(shown.length, 0.0))[i] += base(t) ?? 0;
    }
    final plan = desk.profile.categoryPlan;
    final last = columnName(shown.length + 1);
    final rows = <List<XCell?>>[
      [
        XCell(tr('category'), style: XStyle.header),
        for (final m in shown) XCell(DateFormat.yMMM(o.lang).format(m), style: XStyle.header),
        if (o.totals) ...[XCell(tr('d_total'), style: XStyle.header), XCell(tr('d_x_avg'), style: XStyle.header)],
        if (o.limit) XCell(tr('d_plan'), style: XStyle.header),
      ],
    ];
    final ids = [for (final c in s.categoriesOf(TxnKind.expense)) if (sums.containsKey(c.id)) c.id, if (sums.containsKey(null)) null];
    final maxCell = sums.values.expand((l) => l).fold<double>(1, (a, b) => b > a ? b : a);
    for (final id in ids) {
      final r = rows.length + 1;
      final v = sums[id]!;
      final p = id == null ? 0.0 : (plan[id] ?? 0) / 100;
      rows.add([
        XCell(cat(id), style: XStyle.label),
        for (final x in v)
          XCell(x == 0 ? null : _r(x),
              style: o.over && o.limit && p > 0 && x > p
                  ? XStyle.over
                  : o.heat && x > 0
                      ? (x / maxCell > .66 ? XStyle.heat3 : x / maxCell > .33 ? XStyle.heat2 : XStyle.heat1)
                      : XStyle.number),
        if (o.totals) ...[
          XCell(_r(v.fold(0.0, (a, b) => a + b)), formula: o.formulas ? 'SUM(B$r:$last$r)' : null, style: XStyle.total),
          XCell(_r(v.fold(0.0, (a, b) => a + b) / v.length), formula: o.formulas ? 'AVERAGE(B$r:$last$r)' : null, style: XStyle.total),
        ],
        if (o.limit) XCell(p == 0 ? null : p, style: XStyle.input),
      ]);
    }
    if (o.totals) {
      final end = rows.length;
      rows.add([
        XCell(tr('d_total'), style: XStyle.totalLabel),
        for (var i = 0; i < shown.length + 2 + (o.limit ? 1 : 0); i++)
          XCell(null, formula: o.formulas ? 'SUM(${columnName(i + 2)}2:${columnName(i + 2)}$end)' : null, style: XStyle.total),
      ]);
    }
    return XSheet(tr('d_x_by_month'), rows,
        widths: [22, for (final _ in shown) 11, 12, 12, 12], freezeRows: o.freeze ? 1 : 0, freezeCols: o.freeze ? 1 : 0, protect: o.protect && o.formulas);
  }

  static double _r(double v) => (v * 100).roundToDouble() / 100;
}

/// Nightly: rewrites the user's Excel file with the saved options (once a day).
Future<void> autoUpdateExcel(DeskController desk) async {
  final o = XOpts.fromJson(desk.profile.excelOptions);
  if (o.fileName.isEmpty) return;
  final dir = await documentsDir(desk);
  final f = File('${dir.path}${Platform.pathSeparator}${o.fileName}');
  if (await f.exists()) {
    final m = (await f.stat()).modified;
    final now = DateTime.now();
    if (m.year == now.year && m.month == now.month && m.day == now.day) return;
  }
  final s = desk.state;
  final txns = await _txnsFor(s, o);
  final book = buildBook(s, desk, o, txns);
  await f.writeAsBytes(writeBook(book, theme: o.xtheme, numberFormat: o.numberFormatFor(s.baseCurrency), dateFormat: o.excelDate));
}

class ExcelPage extends StatefulWidget {
  const ExcelPage({super.key});
  @override
  State<ExcelPage> createState() => _ExcelPageState();
}

class _ExcelPageState extends State<ExcelPage> {
  late XOpts o;
  List<Txn>? txns;
  String? _loadedPeriod;
  int sheet = 0;
  (int, int) selCell = (1, 1);
  late final name = TextEditingController();

  @override
  void initState() {
    super.initState();
    final desk = context.read<DeskController>();
    o = XOpts.fromJson(desk.profile.excelOptions);
    if (desk.profile.excelOptions.isEmpty) o.applyPreset('budget');
    name.text = o.fileName.isEmpty ? '${tr('d_x_file')} ${DateFormat('yyyy-MM').format(DateTime.now())}.xlsx' : o.fileName;
    HardwareKeyboard.instance.addHandler(_key);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    name.dispose();
    super.dispose();
  }

  bool _key(KeyEvent e) {
    if (e is KeyDownEvent && HardwareKeyboard.instance.isControlPressed && e.logicalKey == LogicalKeyboardKey.keyS) {
      _save();
      return true;
    }
    return false;
  }

  void _set(VoidCallback f) => setState(() {
        f();
        o.preset = '';
      });

  Future<void> _ensureTxns(AppState s) async {
    if (_loadedPeriod == o.period) return;
    _loadedPeriod = o.period;
    final list = await _txnsFor(s, o);
    if (mounted) setState(() => txns = list);
  }

  Future<void> _save() async {
    final desk = context.read<DeskController>();
    final s = desk.state;
    final list = txns ?? await _txnsFor(s, o);
    var file = name.text.trim();
    if (file.isEmpty) file = 'budget.xlsx';
    if (!file.toLowerCase().endsWith('.xlsx')) file = '$file.xlsx';
    o.fileName = file;
    desk.profile.excelOptions = jsonEncode(o.toJson());
    desk.profile.autoExcel = o.auto;
    await desk.saveProfile(refold: false);
    final dir = await documentsDir(desk);
    final path = '${dir.path}${Platform.pathSeparator}$file';
    try {
      await File(path).writeAsBytes(writeBook(buildBook(s, desk, o, list),
          theme: o.xtheme, numberFormat: o.numberFormatFor(s.baseCurrency), dateFormat: o.excelDate));
      await openPath(path);
    } on FileSystemException {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('d_x_file_busy'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final desk = context.watch<DeskController>();
    _ensureTxns(s);
    final book = txns == null ? <XSheet>[] : buildBook(s, desk, o, txns!);
    if (sheet >= book.length) sheet = 0;
    return DeskPage(
      crumb: InkWell(
        onTap: () => desk.go(DeskPages.documents),
        child: Text('${tr('d_nav_documents')} ›', style: sans(context, size: 13, color: Ledger.accentOf(context))),
      ),
      title: tr('d_excel_title'),
      subtitle: tr('d_excel_sub'),
      actions: [
        SizedBox(
          width: 280,
          child: TextField(controller: name, decoration: InputDecoration(isDense: true, labelText: tr('d_x_file_name'))),
        ),
        DeskButton(tr('d_x_save'), primary: true, shortcut: 'Ctrl S', onTap: _save),
      ],
      children: [
        SplitRow([
          (2, 340, _options(context)),
          (3, 560, _preview(context, book)),
        ]),
      ],
    );
  }

  Widget _group(BuildContext c, String title, List<Widget> children) => Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(border: Border(top: BorderSide(color: Ledger.trackOf(c)))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title.toUpperCase(), style: mono(size: 11.5, weight: FontWeight.w600, color: Ledger.mutedOf(c), spacing: .6)),
          const SizedBox(height: 8),
          ...children,
        ]),
      );

  Widget _check(BuildContext c, bool v, String label, String sub, ValueChanged<bool> onChanged) => CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        controlAffinity: ListTileControlAffinity.leading,
        value: v,
        onChanged: (x) => _set(() => onChanged(x ?? false)),
        title: Text(label, style: sans(c, size: 13.5)),
        subtitle: Text(sub, style: sans(c, size: 12, color: Ledger.mutedOf(c))),
      );

  Widget _options(BuildContext c) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr('d_x_start').toUpperCase(), style: mono(size: 11.5, weight: FontWeight.w600, color: Ledger.mutedOf(c), spacing: .6)),
      const SizedBox(height: 8),
      AutoGrid(minWidth: 150, spacing: 8, children: [
        for (final p in ['budget', 'accountant', 'totals'])
          _Card(
            title: tr('d_x_preset_$p'),
            sub: tr('d_x_preset_${p}_d'),
            selected: o.preset == p,
            onTap: () => setState(() => o.applyPreset(p)),
          ),
      ]),
      const SizedBox(height: 6),
      _group(c, tr('d_x_layout'), [
        AutoGrid(minWidth: 150, spacing: 8, children: [
          for (final l in ['days', 'ops', 'months', 'all'])
            _Card(title: tr('d_x_layout_$l'), sub: tr('d_x_layout_${l}_d'), selected: o.layout == l, onTap: () => _set(() {
                  o.layout = l;
                  sheet = 0;
                })),
        ]),
      ]),
      _group(c, tr('d_period'), [
        Choice(
          options: [('month', tr('d_x_p_month')), ('quarter', tr('d_x_p_quarter')), ('year', tr('d_x_p_year')), ('all', tr('d_all_time'))],
          value: o.period,
          onChanged: (v) => _set(() => o.period = v),
        ),
      ]),
      _group(c, tr('d_x_sheets'), [
        _check(c, o.perMonth, tr('d_x_per_month'), tr('d_x_per_month_d'), (v) => o.perMonth = v),
        _check(c, o.perAccount, tr('d_x_per_account'), tr('d_x_per_account_d'), (v) => o.perAccount = v),
        _check(c, o.summary, tr('d_x_summary_sheet'), tr('d_x_summary_sheet_d'), (v) => o.summary = v),
      ]),
      if (o.layout == 'ops' || o.layout == 'all')
        _group(c, tr('d_x_columns'), [
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final col in ['date', 'time', 'payee', 'category', 'account', 'amount', 'base', 'rate', 'note', 'source'])
              Pill(tr('d_x_col_$col'), selected: o.cols.contains(col), onTap: () => _set(() => o.cols.contains(col) ? o.cols.remove(col) : o.cols.add(col))),
          ]),
        ]),
      _group(c, tr('d_x_comfort'), [
        _check(c, o.freeze, tr('d_x_freeze'), tr('d_x_freeze_d'), (v) => o.freeze = v),
        _check(c, o.filter, tr('d_x_filter'), tr('d_x_filter_d'), (v) => o.filter = v),
        _check(c, o.totals, tr('d_x_totals'), tr('d_x_totals_d'), (v) => o.totals = v),
        _check(c, o.limit, tr('d_x_limit_opt'), tr('d_x_limit_opt_d'), (v) => o.limit = v),
        _check(c, o.over, tr('d_x_over'), tr('d_x_over_d'), (v) => o.over = v),
        _check(c, o.heat, tr('d_x_heat'), tr('d_x_heat_d'), (v) => o.heat = v),
        _check(c, o.weeks, tr('d_x_weeks'), tr('d_x_weeks_d'), (v) => o.weeks = v),
        _check(c, o.formulas, tr('d_x_formulas'), tr('d_x_formulas_d'), (v) => o.formulas = v),
        _check(c, o.protect, tr('d_x_protect'), tr('d_x_protect_d'), (v) => o.protect = v),
      ]),
      _group(c, tr('d_x_look'), [
        Text(tr('d_x_colors'), style: sans(c, size: 13)),
        const SizedBox(height: 6),
        Choice(options: [('ledger', tr('d_x_theme_ledger')), ('neutral', tr('d_x_theme_neutral')), ('plain', tr('d_x_theme_plain'))], value: o.theme, onChanged: (v) => _set(() => o.theme = v), dense: true),
        const SizedBox(height: 10),
        Text(tr('d_x_numbers'), style: sans(c, size: 13)),
        const SizedBox(height: 6),
        Choice(options: [(true, '1 234,50'), (false, '1 234')], value: o.decimals, onChanged: (v) => _set(() => o.decimals = v), dense: true),
        const SizedBox(height: 10),
        Text(tr('d_x_dates'), style: sans(c, size: 13)),
        const SizedBox(height: 6),
        Choice(options: [('dmy', '24.10.2026'), ('iso', '2026-10-24'), ('mdy', '10/24/2026'), ('short', '24 Oct')], value: o.dateStyle, onChanged: (v) => _set(() => o.dateStyle = v), dense: true),
        const SizedBox(height: 10),
        Text(tr('d_x_money'), style: sans(c, size: 13)),
        const SizedBox(height: 6),
        Choice(
          options: [('sym', '118 ${currencySymbol(context.read<AppState>().baseCurrency)}'), ('code', '118 ${context.read<AppState>().baseCurrency}'), ('none', '118')],
          value: o.money,
          onChanged: (v) => _set(() => o.money = v),
          dense: true,
        ),
      ]),
      _group(c, tr('d_x_lang'), [
        Choice(options: [for (final l in supportedLanguages) (l, languageNames[l]!)], value: o.lang, onChanged: (v) => _set(() => o.lang = v), dense: true),
        const SizedBox(height: 6),
        Text(tr('d_x_lang_note'), style: sans(c, size: 12, color: Ledger.mutedOf(c))),
      ]),
      _group(c, tr('d_x_update'), [
        _check(c, o.auto, tr('d_x_auto'), tr('d_x_auto_d'), (v) => o.auto = v),
      ]),
    ]);
  }

  Widget _preview(BuildContext context, List<XSheet> book) {
    final s = context.read<AppState>();
    if (txns == null) return const Panel(child: Center(child: CircularProgressIndicator()));
    final sh = book.isEmpty ? null : book[sheet];
    final th = o.xtheme;
    Color hex(String h) => Color(int.parse('FF$h', radix: 16));
    final fmt = NumberFormat(o.decimals ? '#,##0.00' : '#,##0', intlLocale);
    String show(XCell? c) {
      if (c == null || c.value == null) return '';
      final v = c.value;
      if (v is DateTime) {
        return switch (o.dateStyle) {
          'iso' => DateFormat('yyyy-MM-dd').format(v),
          'mdy' => DateFormat('MM/dd/yyyy').format(v),
          'short' => DateFormat('d MMM', intlLocale).format(v),
          _ => DateFormat('dd.MM.yyyy').format(v),
        };
      }
      if (v is num && c.style != XStyle.muted) {
        final n = fmt.format(v);
        return switch (o.money) { 'code' => '$n ${s.baseCurrency}', 'sym' => '$n ${currencySymbol(s.baseCurrency)}', _ => n };
      }
      return '$v';
    }

    const maxCols = 13, maxRows = 18;
    final rows = sh == null ? <List<XCell?>>[] : sh.rows.take(maxRows).toList();
    final ncols = rows.fold<int>(0, (a, r) => r.length > a ? r.length : a).clamp(0, maxCols);
    final selected = rows.length > selCell.$1 && rows[selCell.$1].length > selCell.$2 ? rows[selCell.$1][selCell.$2] : null;
    final formulasCount = book.fold<int>(0, (a, b) => a + b.rows.fold<int>(0, (x, r) => x + r.where((c) => c?.formula != null).length));

    Widget cell(XCell? c, int r, int col) {
      final st = c?.style ?? XStyle.text;
      Color? bg;
      Color fg = Ledger.ink;
      var w = FontWeight.w400;
      switch (st) {
        case XStyle.header:
          bg = hex(th.headerFill);
          fg = hex(th.headerFont);
          w = FontWeight.w600;
        case XStyle.total || XStyle.totalLabel:
          bg = hex(th.totalFill);
          w = FontWeight.w600;
        case XStyle.over:
          bg = softWarn;
          fg = warnDark;
          w = FontWeight.w600;
        case XStyle.input:
          fg = const Color(0xFF1F4FB4);
        case XStyle.heat1:
          bg = hex(th.heat[0]);
        case XStyle.heat2:
          bg = hex(th.heat[1]);
        case XStyle.heat3:
          bg = hex(th.heat[2]);
        case XStyle.label:
          w = FontWeight.w600;
        case XStyle.muted:
          fg = Ledger.muted;
        default:
      }
      final numeric = c?.value is num || c?.value is DateTime || c?.formula != null;
      final on = selCell == (r, col);
      return GestureDetector(
        onTap: () => setState(() => selCell = (r, col)),
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: numeric && st != XStyle.header ? Alignment.centerRight : Alignment.centerLeft,
          decoration: BoxDecoration(
            color: bg ?? Colors.white,
            border: Border(
              right: BorderSide(color: o.freeze && col == 0 && o.layout != 'ops' ? Ledger.emerald : const Color(0xFFE3E3E3), width: o.freeze && col == 0 && o.layout != 'ops' ? 2 : 1),
              bottom: BorderSide(color: o.freeze && r == 0 ? Ledger.emerald : const Color(0xFFE3E3E3), width: o.freeze && r == 0 ? 2 : 1),
            ),
          ),
          foregroundDecoration: on ? BoxDecoration(border: Border.all(color: const Color(0xFF107C41), width: 2)) : null,
          child: Text(
            st == XStyle.header && o.filter && o.layout != 'days' ? '${show(c)}  ▾' : show(c),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontFamily: numeric ? Ledger.monoFamily : Ledger.sansFamily, fontSize: 12, color: fg, fontWeight: w),
          ),
        ),
      );
    }

    final widths = [for (var i = 0; i < ncols; i++) i == 0 ? 150.0 : (sh!.widths.length > i ? sh.widths[i] * 7.5 : 80.0).clamp(56.0, 190.0)];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text(tr('d_x_preview_hint'), style: sans(context, size: 12.5, color: Ledger.mutedOf(context)))),
        Text(tr('d_x_stats', [book.length, o.formulas ? formulasCount : 0]), style: mono(size: 12, color: Ledger.mutedOf(context))),
      ]),
      const SizedBox(height: 8),
      Container(
        decoration: BoxDecoration(border: Border.all(color: const Color(0xFFB9B9B9)), borderRadius: BorderRadius.circular(6), color: Colors.white),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            height: 32,
            color: const Color(0xFFF7F7F7),
            child: Row(children: [
              Container(
                width: 64,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: const BoxDecoration(border: Border(right: BorderSide(color: Color(0xFFD4D4D4)))),
                child: Text('${columnName(selCell.$2 + 1)}${selCell.$1 + 1}', style: mono(size: 12, color: Ledger.ink)),
              ),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 10), child: Text('fx', style: TextStyle(fontStyle: FontStyle.italic, color: Ledger.muted))),
              Expanded(
                child: Text(
                  selected == null ? '' : (o.formulas && selected.formula != null ? '=${selected.formula}' : show(selected)),
                  overflow: TextOverflow.ellipsis,
                  style: mono(size: 12, color: Ledger.ink),
                ),
              ),
              if (o.protect && o.formulas && selected?.formula != null)
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: const Color(0xFFECE7DA), borderRadius: BorderRadius.circular(4)),
                  child: Text(tr('d_x_protected'), style: const TextStyle(fontSize: 11.5, color: Ledger.muted)),
                ),
            ]),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(width: 36, height: 22, color: const Color(0xFFF0F0F0)),
                for (var i = 0; i < ncols; i++)
                  Container(
                    width: widths[i],
                    height: 22,
                    alignment: Alignment.center,
                    color: const Color(0xFFF0F0F0),
                    child: Text(columnName(i + 1), style: mono(size: 11, color: Ledger.muted)),
                  ),
              ]),
              for (var r = 0; r < rows.length; r++)
                Row(children: [
                  Container(
                    width: 36,
                    height: 28,
                    alignment: Alignment.center,
                    color: const Color(0xFFF0F0F0),
                    child: Text('${r + 1}', style: mono(size: 11, color: Ledger.muted)),
                  ),
                  for (var col = 0; col < ncols; col++)
                    SizedBox(width: widths[col], child: cell(col < rows[r].length ? rows[r][col] : null, r, col)),
                ]),
            ]),
          ),
          Container(
            height: 32,
            color: const Color(0xFFF3F3F3),
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (var i = 0; i < book.length; i++)
                InkWell(
                  onTap: () => setState(() {
                    sheet = i;
                    selCell = (1, 1);
                  }),
                  child: Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: i == sheet ? Colors.white : null,
                      border: Border(
                        right: const BorderSide(color: Color(0xFFD4D4D4)),
                        bottom: BorderSide(color: i == sheet ? const Color(0xFF107C41) : Colors.transparent, width: 2),
                      ),
                    ),
                    child: Text(book[i].name,
                        style: TextStyle(fontSize: 12.5, color: i == sheet ? const Color(0xFF107C41) : Ledger.ink, fontWeight: i == sheet ? FontWeight.w600 : FontWeight.w400)),
                  ),
                ),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      AutoGrid(minWidth: 180, spacing: 10, children: [
        _note(context, tr('d_x_note1_t'), tr('d_x_note1')),
        _note(context, tr('d_x_note2_t'), o.formulas ? tr('d_x_note2') : tr('d_x_note2_values')),
        _note(context, tr('d_x_note3_t'), tr('d_x_note3')),
      ]),
    ]);
  }

  Widget _note(BuildContext c, String k, String v) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(border: Border.all(color: Ledger.trackOf(c)), borderRadius: BorderRadius.circular(6), color: panelOf(c)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(k, style: sans(c, size: 12, color: Ledger.mutedOf(c))),
          Text(v, style: sans(c, size: 13.5)),
        ]),
      );
}

class _Card extends StatelessWidget {
  final String title;
  final String sub;
  final bool selected;
  final VoidCallback onTap;
  const _Card({required this.title, required this.sub, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          constraints: const BoxConstraints(minHeight: 66),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: selected ? Ledger.withinOf(context) : panelOf(context),
            border: Border.all(color: selected ? Ledger.accentOf(context) : Ledger.ruleOf(context), width: selected ? 1.5 : 1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: sans(context, size: 13.5, weight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(sub, style: sans(context, size: 12, color: Ledger.mutedOf(context))),
          ]),
        ),
      );
}
