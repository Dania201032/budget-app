import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../domain/money.dart';
import '../domain/periods.dart';
import '../io/export.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../ui/ledger.dart';
import 'excel_page.dart' show autoUpdateExcel;
import 'kit.dart';
import 'shell.dart';

/// Where documents are saved: the folder from Settings, or Documents\Budget.
Future<Directory> documentsDir(DeskController desk) async {
  final custom = desk.profile.documentsFolder;
  final dir = custom != null && custom.isNotEmpty
      ? Directory(custom)
      : Directory('${(await getApplicationDocumentsDirectory()).path}${Platform.pathSeparator}${tr('d_folder_name')}');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

/// Opens a file or folder with the system's default program.
Future<void> openPath(String path) async {
  try {
    if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [path]);
    } else {
      await Process.run('xdg-open', [path]);
    }
  } catch (_) {}
}

/// On start: last month's report on the 1st (if switched on) and the nightly Excel update.
Future<void> runAutoDocuments(BuildContext context, DeskController desk) async {
  final p = desk.profile;
  final now = DateTime.now();
  final last = DateTime(now.year, now.month - 1);
  final key = DateFormat('yyyy-MM').format(last);
  try {
    if (p.autoMonthReport && p.lastAutoReport != key) {
      final html = _Docs(desk, [currentLanguage]).month(Period.containing(PeriodType.month, last));
      final dir = await documentsDir(desk);
      await File('${dir.path}${Platform.pathSeparator}${tr('d_file_month', [key])}.html').writeAsString(html);
      p.lastAutoReport = key;
      await desk.saveProfile(refold: false);
    }
    if (p.autoExcel) await autoUpdateExcel(desk);
  } catch (e) {
    debugPrint('auto documents: $e');
  }
}

class DocumentsPage extends StatefulWidget {
  const DocumentsPage({super.key});
  @override
  State<DocumentsPage> createState() => _DocumentsPageState();
}

class _DocumentsPageState extends State<DocumentsPage> {
  String sel = 'month';
  final langs = <String, List<String>>{};
  final bilingual = <String, bool>{};
  int periodChoice = 1;
  List<FileSystemEntity> recent = [];

  static const templates = ['month', 'funds', 'friends', 'plan', 'year', 'csv'];

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  Future<void> _loadRecent() async {
    try {
      final dir = await documentsDir(context.read<DeskController>());
      final files = (await dir.list().toList()).whereType<File>().toList()
        ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      if (mounted) setState(() => recent = files.take(8).toList());
    } catch (e) {
      // No documents folder (yet): the list stays empty.
      debugPrint('documents folder: $e');
    }
  }

  List<String> _langsOf(String t) => langs[t] ?? [t == 'funds' && currentLanguage != 'en' ? 'en' : currentLanguage];

  @override
  Widget build(BuildContext context) {
    final desk = context.watch<DeskController>();
    final l = _langsOf(sel);
    final bi = (bilingual[sel] ?? false) && l.length > 1;
    final docs = _Docs(desk, l, bilingual: bi);
    final preview = docs.preview(sel, periodChoice);
    return DeskPage(
      title: tr('d_nav_documents'),
      subtitle: tr('d_docs_sub'),
      actions: [
        DeskButton(tr('d_open_folder'), icon: Icons.folder_open_outlined, onTap: () async => openPath((await documentsDir(desk)).path)),
      ],
      children: [
        SplitRow([
          (
            3,
            280,
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              InkWell(
                onTap: () => desk.go(DeskPages.excel),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: Ledger.emerald, borderRadius: BorderRadius.circular(10)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                        decoration: BoxDecoration(color: Ledger.mint, borderRadius: BorderRadius.circular(4)),
                        child: Text('XLSX', style: mono(size: 11, weight: FontWeight.w600, color: Ledger.emerald)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(tr('d_excel_title'), style: sans(context, size: 15, weight: FontWeight.w600, color: Ledger.paper))),
                    ]),
                    const SizedBox(height: 8),
                    Text(tr('d_excel_card'), style: sans(context, size: 13, color: const Color(0xFFCFE6DC), height: 1.45)),
                    const SizedBox(height: 8),
                    Text(tr('d_open_builder'), style: sans(context, size: 13, weight: FontWeight.w600, color: Ledger.mint)),
                  ]),
                ),
              ),
              const SizedBox(height: 14),
              for (final t in templates)
                _TemplateTile(
                  id: t,
                  selected: t == sel,
                  onTap: () => setState(() {
                    sel = t;
                    periodChoice = 1;
                  }),
                ),
            ]),
          ),
          (
            4,
            340,
            Panel(
              title: tr('d_doc_${sel}_t'),
              subtitle: tr('d_doc_${sel}_long'),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(tr('d_period'), style: sans(context, size: 12.5, color: Ledger.mutedOf(context))),
                const SizedBox(height: 6),
                Choice(
                  options: [for (var i = 0; i < docs.periods(sel).length; i++) (i, docs.periods(sel)[i])],
                  value: periodChoice,
                  onChanged: (v) => setState(() => periodChoice = v),
                ),
                const SizedBox(height: 14),
                if (sel != 'csv') ...[
                  Text(tr('d_doc_langs'), style: sans(context, size: 12.5, color: Ledger.mutedOf(context))),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (var i = 0; i < l.length; i++)
                      Pill(
                        '${i == 0 ? tr('d_main_lang') : tr('d_second_lang')}: ${languageNames[l[i]]}',
                        selected: i == 0,
                        trailing: l.length > 1
                            ? InkWell(
                                onTap: () => setState(() => langs[sel] = [...l]..removeAt(i)),
                                child: Icon(Icons.close, size: 14, color: i == 0 ? Ledger.paper : Ledger.mutedOf(context)),
                              )
                            : null,
                      ),
                    PopupMenuButton<String>(
                      tooltip: tr('d_add_lang'),
                      onSelected: (v) => setState(() => langs[sel] = [...l, v]),
                      itemBuilder: (_) => [
                        for (final code in supportedLanguages)
                          if (!l.contains(code)) PopupMenuItem(value: code, child: Text(languageNames[code]!)),
                      ],
                      child: Pill(tr('d_add_lang'), dashed: true),
                    ),
                  ]),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: bi,
                    onChanged: l.length < 2 ? null : (v) => setState(() => bilingual[sel] = v ?? false),
                    title: Text(tr('d_bilingual')),
                    subtitle: Text(l.length < 2 ? tr('d_bilingual_need') : tr('d_bilingual_sub')),
                  ),
                ],
                if (sel == 'funds')
                  Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: Ledger.overOf(context), borderRadius: BorderRadius.circular(6)),
                    child: Text(tr('d_funds_warn'), style: sans(context, size: 12.5, height: 1.45)),
                  ),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  DeskButton(sel == 'csv' ? tr('d_save_csv') : tr('d_save_open'), primary: true, onTap: () => _save(docs)),
                  if (sel == 'friends')
                    DeskButton(tr('d_copy_text'), onTap: () {
                      Clipboard.setData(ClipboardData(text: docs.friendsText()));
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('d_copied'))));
                    }),
                ]),
                if (sel != 'csv') ...[
                  const SizedBox(height: 8),
                  Text(tr('d_pdf_hint'), style: sans(context, size: 12, color: Ledger.mutedOf(context))),
                ],
                if (sel == 'month') ...[
                  const SizedBox(height: 10),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: desk.profile.autoMonthReport,
                    onChanged: (v) {
                      desk.profile.autoMonthReport = v ?? false;
                      desk.saveProfile(refold: false);
                    },
                    title: Text(tr('d_auto_month')),
                    subtitle: Text(tr('d_auto_month_sub')),
                  ),
                ],
              ]),
            ),
          ),
          (
            5,
            380,
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('${tr('d_preview')} · ${l.map((x) => x.toUpperCase()).join(bi ? ' + ' : ' / ')}', style: sans(context, size: 12.5, color: Ledger.mutedOf(context))),
              const SizedBox(height: 8),
              _Paper(preview),
              const SizedBox(height: 14),
              Panel(
                title: tr('d_recent'),
                child: Column(children: [
                  if (recent.isEmpty) Text(tr('d_no_recent'), style: sans(context, color: Ledger.mutedOf(context))),
                  for (final f in recent)
                    InkWell(
                      onTap: () => openPath(f.path),
                      child: LineItem(f.uri.pathSegments.last, DateFormat.MMMd(intlLocale).add_Hm().format(f.statSync().modified)),
                    ),
                ]),
              ),
            ]),
          ),
        ]),
      ],
    );
  }

  Future<void> _save(_Docs docs) async {
    final desk = context.read<DeskController>();
    final dir = await documentsDir(desk);
    final (name, content) = await docs.build(sel, periodChoice);
    final f = File('${dir.path}${Platform.pathSeparator}$name');
    await f.writeAsString(content, encoding: utf8);
    await openPath(f.path);
    await _loadRecent();
  }
}

class _TemplateTile extends StatelessWidget {
  final String id;
  final bool selected;
  final VoidCallback onTap;
  const _TemplateTile({required this.id, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected ? panelOf(context) : null,
            border: Border.all(color: selected ? Ledger.inkOf(context) : Colors.transparent),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 44,
              padding: const EdgeInsets.symmetric(vertical: 5),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: selected ? Ledger.emerald : Ledger.trackOf(context), borderRadius: BorderRadius.circular(4)),
              child: Text(id == 'csv' ? 'CSV' : 'HTML',
                  style: mono(size: 10, weight: FontWeight.w600, color: selected ? Ledger.paper : Ledger.inkOf(context))),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('d_doc_${id}_t'), style: sans(context, size: 14, weight: FontWeight.w600)),
                Text(tr('d_doc_${id}_d'), style: sans(context, size: 12.5, color: Ledger.mutedOf(context))),
              ]),
            ),
          ]),
        ),
      );
}

/// What the preview shows: title, subtitle, key figures and rows.
class _Preview {
  final String title;
  final String sub;
  final List<(String, String)> kpis;
  final String tableTitle;
  final List<(String, String, bool)> rows;
  final String foot;
  const _Preview(this.title, this.sub, this.kpis, this.tableTitle, this.rows, this.foot);
}

class _Paper extends StatelessWidget {
  final _Preview p;
  const _Paper(this.p);
  @override
  Widget build(BuildContext context) {
    const ink = Ledger.ink;
    return AspectRatio(
      aspectRatio: 210 / 297,
      child: Container(
        padding: const EdgeInsets.fromLTRB(32, 30, 32, 24),
        decoration: BoxDecoration(color: Colors.white, border: Border.all(color: const Color(0xFFCFC8B8))),
        child: ClipRect(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              padding: const EdgeInsets.only(bottom: 10),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: ink, width: 2))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.title, style: const TextStyle(fontFamily: Ledger.sansFamily, fontSize: 20, fontWeight: FontWeight.w600, color: ink)),
                Text(p.sub, style: const TextStyle(fontFamily: Ledger.sansFamily, fontSize: 11, color: Ledger.muted)),
              ]),
            ),
            const SizedBox(height: 12),
            Row(children: [
              for (final (k, v) in p.kpis)
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.all(8),
                    color: const Color(0xFFF5F1E7),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(k, style: const TextStyle(fontSize: 10, color: Ledger.muted)),
                      FittedBox(child: Text(v, style: mono(size: 14, weight: FontWeight.w600, color: ink))),
                    ]),
                  ),
                ),
            ]),
            const SizedBox(height: 12),
            Text(p.tableTitle.toUpperCase(), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Ledger.muted)),
            const SizedBox(height: 4),
            for (final (a, b, bold) in p.rows.take(14))
              Container(
                padding: const EdgeInsets.symmetric(vertical: 4),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: bold ? ink : const Color(0xFFECE7DA)))),
                child: Row(children: [
                  Expanded(child: Text(a, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: ink, fontWeight: bold ? FontWeight.w600 : FontWeight.w400))),
                  Text(b, style: mono(size: 11, color: ink, weight: bold ? FontWeight.w600 : FontWeight.w400)),
                ]),
              ),
            const Spacer(),
            Text(p.foot, style: const TextStyle(fontSize: 9.5, color: Ledger.muted)),
          ]),
        ),
      ),
    );
  }
}

/// Builds the documents (HTML for printing to PDF, CSV) from the app's data, in one or two languages.
class _Docs {
  final DeskController desk;
  final List<String> langs;
  final bool bilingual;
  _Docs(this.desk, this.langs, {this.bilingual = false});

  AppState get s => desk.state;
  String get base => s.baseCurrency;

  /// A string in the document's language(s).
  String t(String key, [List<Object?> args = const []]) {
    final saved = currentLanguage;
    try {
      String one(String l) {
        currentLanguage = l;
        return tr(key, args);
      }

      return bilingual ? '${one(langs[0])} / ${one(langs[1])}' : one(langs.first);
    } finally {
      currentLanguage = saved;
    }
  }

  String money(int v) => formatMoney(v, base);

  List<String> periods(String id) {
    final now = DateTime.now();
    return switch (id) {
      'month' => [monthTitle(DateTime(now.year, now.month - 1)), monthTitle(DateTime(now.year, now.month))],
      'funds' => [tr('d_3m'), tr('d_6m'), tr('d_12m')],
      'friends' => [tr('d_open_debts'), tr('d_all_debts')],
      'plan' => [tr('d_n_months', [3]), tr('d_n_months', [6]), tr('d_n_months', [12])],
      'year' => ['${now.year - 1}', '${now.year}'],
      _ => [monthTitle(DateTime(now.year, now.month)), '${now.year}', tr('d_all_time')],
    };
  }

  Period _monthPeriod(int choice) {
    final now = DateTime.now();
    return Period.containing(PeriodType.month, DateTime(now.year, now.month - 1 + choice));
  }

  int _monthsOf(int choice) => [3, 6, 12][choice.clamp(0, 2)];

  _Preview preview(String id, int choice) {
    final d = desk.data;
    final now = DateTime.now();
    switch (id) {
      case 'month':
        final p = _monthPeriod(choice);
        final i = d.monthIndex(p.start);
        final rows = _catRows(i);
        return _Preview(t('d_doc_month_t'), p.label(), [
          (t('d_spent'), money(d.spentByMonth[i])),
          (t('d_budget'), money(s.rawMonthBudget(p.start))),
          (t('d_incomes'), money(d.incomeByMonth[i])),
        ], t('d_categories'), [for (final r in rows) (r.$1, money(r.$2), false), (t('d_total'), money(d.spentByMonth[i]), true)], t('d_made_by', [DateFormat.yMMMd(langs.first).format(now)]));
      case 'funds':
        final m = _monthsOf(choice);
        final inc = d.incomeByMonth.sublist(13 - m).fold<int>(0, (a, b) => a + b);
        final sp = d.spentByMonth.sublist(13 - m).fold<int>(0, (a, b) => a + b);
        return _Preview(t('d_funds_title'), t('d_funds_period', [DateFormat.yMMMd(langs.first).format(now), m]), [
          (t('d_total_balance'), money(s.totalBalance + desk.countedHoldings())),
          (t('d_avg_inflow'), money(inc ~/ m)),
          (t('d_avg_spending'), money(sp ~/ m)),
        ], t('d_balances'), [
          for (final a in s.accounts.where((a) => s.balances.containsKey(a.id)))
            ('${s.accountName(a)}${a.currency == base ? '' : ' · ${formatMoney(s.balances[a.id]!, a.currency)}'}', money(s.toBaseAmount(s.balances[a.id]!, a.currency, now) ?? 0), false),
          (t('d_total'), money(s.totalBalance + desk.countedHoldings()), true),
        ], t('d_funds_foot'));
      case 'friends':
        final by = _debtsByPerson(all: choice == 1);
        final total = by.values.fold<int>(0, (a, l) => a + l.fold<int>(0, (x, dbt) => x + (s.toBaseAmount(dbt.openMinor, dbt.currency, now) ?? 0)));
        return _Preview(t('d_doc_friends_t'), DateFormat.yMMMd(langs.first).format(now), [
          (t('d_owed_to_you'), money(total)),
          (t('d_people'), '${by.length}'),
          (t('d_items'), '${by.values.fold<int>(0, (a, l) => a + l.length)}'),
        ], t('d_by_person'), [
          for (final e in by.entries) ...[
            (e.key, money(e.value.fold<int>(0, (x, dbt) => x + (s.toBaseAmount(dbt.openMinor, dbt.currency, now) ?? 0))), true),
            for (final dbt in e.value) ('  ${DateFormat.MMMd(langs.first).format(dbt.createdAt)}', formatMoney(dbt.openMinor, dbt.currency), false),
          ],
        ], t('d_friends_foot'));
      case 'plan':
        final m = _monthsOf(choice);
        final rows = _planRows();
        final perMonth = rows.fold<int>(0, (a, r) => a + r.$2);
        final income = _regularIncome();
        return _Preview(t('d_doc_plan_t'), t('d_plan_period', [monthTitle(DateTime(now.year, now.month + 1)), m]), [
          (t('d_per_month'), money(perMonth)),
          (t('d_for_period'), money(perMonth * m)),
          (t('d_shortfall'), money((perMonth - income) * m > 0 ? (perMonth - income) * m : 0)),
        ], t('d_per_month'), [for (final r in rows) (r.$1, money(r.$2), false), (t('d_total'), money(perMonth), true)], t('d_plan_foot', [money(income)]));
      case 'year':
        final y = now.year - 1 + choice;
        final idx = [for (var i = 0; i < 13; i++) if (d.months[i].year == y) i];
        final sp = idx.fold<int>(0, (a, i) => a + d.spentByMonth[i]);
        final inc = idx.fold<int>(0, (a, i) => a + d.incomeByMonth[i]);
        final cats = <int?, int>{};
        for (final e in d.spentByCategory.entries) {
          cats[e.key] = idx.fold<int>(0, (a, i) => a + e.value[i]);
        }
        final top = cats.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
        return _Preview(t('d_doc_year_t'), '$y', [
          (t('d_spent'), money(sp)),
          (t('d_incomes'), money(inc)),
          (t('d_difference'), formatMoney(inc - sp, base, signed: true)),
        ], t('d_categories'), [for (final e in top.take(10)) (_cat(e.key), money(e.value), false), (t('d_total'), money(sp), true)], t('d_year_foot'));
      default:
        return _Preview('operations.csv', tr('d_csv_sub'), [(tr('d_rows'), '${d.txns.length}+'), ('UTF-8', ','), (tr('currency'), base)],
            tr('d_columns'), [for (final c in ['col_date', 'col_time', 'col_type', 'col_amount', 'currency', 'category', 'account', 'payee', 'comment']) (tr(c), '', false)], tr('d_csv_foot'));
    }
  }

  String _cat(int? id) => id == null ? t('d_uncategorized') : (s.categoryById[id] == null ? '—' : s.categoryName(s.categoryById[id]!));

  List<(String, int)> _catRows(int i) {
    final d = desk.data;
    final list = [for (final e in d.spentByCategory.entries) if (e.value[i] > 0) (_cat(e.key), e.value[i])]..sort((a, b) => b.$2.compareTo(a.$2));
    return list;
  }

  List<(String, int)> _planRows() {
    final d = desk.data;
    final plan = desk.profile.categoryPlan;
    return [
      for (final c in s.categoriesOf(TxnKind.expense))
        if ((plan[c.id] ?? d.median3(c.id)) > 0) (s.categoryName(c), plan[c.id] ?? d.median3(c.id)),
    ];
  }

  int _regularIncome() {
    final now = DateTime.now();
    var sum = 0.0;
    for (final r in s.recurring.where((r) => r.kind == TxnKind.income)) {
      final v = s.toBaseAmount(r.amountMinor, r.currency, now) ?? 0;
      sum += switch (r.every) { Every.week => v * 52 / 12, Every.month => v.toDouble(), Every.year => v / 12 };
    }
    return sum.round();
  }

  Map<String, List<Debt>> _debtsByPerson({required bool all}) {
    final by = <String, List<Debt>>{};
    for (final dbt in s.openDebts) {
      if (!all && dbt.settled) continue;
      by.putIfAbsent(dbt.person ?? t('d_someone'), () => []).add(dbt);
    }
    return by;
  }

  String friendsText() {
    final now = DateTime.now();
    final sb = StringBuffer('${t('d_doc_friends_t')} · ${DateFormat.yMMMd(langs.first).format(now)}\n');
    for (final e in _debtsByPerson(all: false).entries) {
      final sum = e.value.fold<int>(0, (x, dbt) => x + (s.toBaseAmount(dbt.openMinor, dbt.currency, now) ?? 0));
      sb.writeln('${e.key}: ${money(sum)}');
    }
    return sb.toString();
  }

  /// Builds the file: (name, content).
  Future<(String, String)> build(String id, int choice) async {
    final stamp = DateFormat('yyyy-MM-dd').format(DateTime.now());
    if (id == 'csv') {
      final now = DateTime.now();
      final p = switch (choice) {
        0 => Period.containing(PeriodType.month, now),
        1 => Period.containing(PeriodType.year, now),
        _ => null,
      };
      final txns = await s.txnsForExport(p);
      final rows = transactionRows(
        txns: txns,
        categoryName: (id) => id == null ? '' : (s.categoryById[id] == null ? '' : s.categoryName(s.categoryById[id]!)),
        accountName: (id) => id == null ? '' : (s.accountById[id] == null ? '' : s.accountName(s.accountById[id]!)),
        baseCurrency: base,
        toBase: s.toBase,
      );
      return ('operations_$stamp.csv', '﻿${toCsv(rows)}');
    }
    final p = preview(id, choice);
    final html = id == 'month' ? month(_monthPeriod(choice)) : _html(p);
    return ('${tr('d_doc_${id}_t')} $stamp.html'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '-'), html);
  }

  /// The month report with a day chart, as a printable page.
  String month(Period p) {
    final d = desk.data;
    final i = d.monthIndex(p.start);
    final pv = preview('month', p.start.month == DateTime.now().month ? 1 : 0);
    final days = <int>[];
    for (final t in d.txns) {
      if (t.kind != TxnKind.expense || t.excluded || d.monthIndex(t.time) != i) continue;
      while (days.length < t.time.day) {
        days.add(0);
      }
      days[t.time.day - 1] += s.toBase(t) ?? 0;
    }
    final n = DateTime(p.start.year, p.start.month + 1, 0).day;
    while (days.length < n) {
      days.add(0);
    }
    final maxV = days.fold<int>(1, (a, b) => a > b ? a : b);
    final limit = s.rawMonthBudget(p.start) / n;
    final bars = StringBuffer();
    for (var k = 0; k < n; k++) {
      final h = days[k] / maxV * 120;
      bars.write('<rect x="${k * 22 + 2}" y="${(130 - h).toStringAsFixed(1)}" width="16" height="${h.toStringAsFixed(1)}" '
          'fill="${limit > 0 && days[k] > limit ? '#B4532A' : '#0E3B34'}"/>');
    }
    final chart = '<svg viewBox="0 0 ${n * 22} 140" width="100%" role="img">$bars<line x1="0" y1="130" x2="${n * 22}" y2="130" stroke="#1B2422"/></svg>';
    final insights = desk.data.insights.take(4).map((x) => '<li>${_esc(x.title)} — ${_esc(x.body)}</li>').join();
    return _html(pv, extra: '<h2>${_esc(t('d_by_day'))}</h2>$chart${insights.isEmpty ? '' : '<h2>${_esc(t('d_highlights'))}</h2><ul>$insights</ul>'}');
  }

  static String _esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  String _html(_Preview p, {String extra = ''}) {
    final kpis = p.kpis.map((k) => '<div class="k"><span>${_esc(k.$1)}</span><b>${_esc(k.$2)}</b></div>').join();
    final rows = p.rows.map((r) => '<tr${r.$3 ? ' class="b"' : ''}><td>${_esc(r.$1)}</td><td class="n">${_esc(r.$2)}</td></tr>').join();
    return '''<!doctype html><html lang="${langs.first}"><head><meta charset="utf-8"><title>${_esc(p.title)}</title>
<style>
@page{size:A4;margin:16mm}
body{font-family:"IBM Plex Sans","Segoe UI","Microsoft YaHei",sans-serif;color:#1B2422;max-width:780px;margin:24px auto;padding:0 24px}
header{border-bottom:2px solid #1B2422;padding-bottom:10px;margin-bottom:18px}
h1{font-size:28px;margin:0 0 4px}header p{margin:0;color:#5E6763;font-size:13px}
.ks{display:flex;gap:10px;margin:0 0 18px}.k{flex:1;background:#F5F1E7;padding:10px 12px}.k span{display:block;font-size:12px;color:#5E6763}.k b{font-family:"IBM Plex Mono",Consolas,monospace;font-size:20px}
h2{font-size:15px;margin:22px 0 8px}
table{width:100%;border-collapse:collapse;font-size:13.5px}td{padding:6px 0;border-bottom:1px solid #D9D4C7}td.n{text-align:right;font-family:"IBM Plex Mono",Consolas,monospace}
tr.b td{font-weight:600;border-bottom:1.5px solid #1B2422}
ul{padding-left:18px;line-height:1.55;font-size:13.5px}
footer{margin-top:26px;padding-top:10px;border-top:1px solid #D9D4C7;font-size:12px;color:#5E6763}
</style></head><body>
<header><h1>${_esc(p.title)}</h1><p>${_esc(p.sub)}</p></header>
<div class="ks">$kpis</div>
<h2>${_esc(p.tableTitle)}</h2><table>$rows</table>
$extra
<footer>${_esc(p.foot)}</footer>
</body></html>''';
  }
}
