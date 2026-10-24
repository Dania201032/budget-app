import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../domain/money.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../ui/ledger.dart';
import 'documents_page.dart' show documentsDir, openPath, saveWithDialog;
import 'charts.dart';
import 'kit.dart';
import 'profile.dart';
import 'shell.dart';
import 'tax_rules.dart';

String countryName(String code) => tr('d_c_$code');

class TaxesPage extends StatefulWidget {
  const TaxesPage({super.key});
  @override
  State<TaxesPage> createState() => _TaxesPageState();
}

class _TaxesPageState extends State<TaxesPage> {
  String? salaryCountry;
  bool nonResident = false;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final desk = context.watch<DeskController>();
    final p = desk.profile;
    final mine = [for (final c in p.countries) c.code];
    // Only the countries chosen in Settings: the others are noise for this person.
    final withRules = [...mine.where(taxRules.containsKey)];
    final sal = _Salary.compute(s, desk.data, salaryCountry, mine);

    return DeskPage(
      title: tr('d_taxes_title', [DateTime.now().year]),
      subtitle: tr('d_taxes_sub'),
      actions: [
        DeskButton(tr('d_to_calendar'), icon: Icons.event_outlined, onTap: () => _addToCalendar(context, desk, _Payments.items(desk, sal, nonResident))),
        DeskButton(tr('d_for_return'), primary: true, onTap: () => desk.go(DeskPages.documents)),
      ],
      children: [
        _Kpis(sal: sal, nonResident: nonResident),
        if (withRules.isEmpty)
          Panel(
            title: tr('d_calculator'),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('d_calc_no_rules', [taxRules.keys.where((k) => appCountries.any((c) => c.code == k)).map(countryName).join(', ')]), style: sans(context, size: 13, color: Ledger.mutedOf(context), height: 1.45)),
              const SizedBox(height: 10),
              DeskButton(tr('d_open_settings'), onTap: () => desk.go(DeskPages.settings)),
            ]),
          )
        else
          _Calculator(countries: withRules, sal: sal),
        if (sal != null)
          _SalaryPanel(
            sal: sal,
            nonResident: nonResident,
            countries: {...sal.options},
            onCountry: (c) => setState(() => salaryCountry = c),
            onResident: (v) => setState(() => nonResident = !v),
          )
        else
          Panel(title: tr('d_salary_tax'), child: Text(tr('d_no_salary'), style: sans(context, color: Ledger.mutedOf(context)))),
        _Payments(mine: mine, sal: sal, nonResident: nonResident),
        _OtherTaxes(mine: mine),
        AutoGrid(minWidth: 300, children: [_InterestCard(mine: mine), _BrokerCard(mine: mine), _OtherIncomeCard(sal: sal)]),
        _VatPanel(mine: mine),
        _Residency(days: desk.data.daysByCountry, mine: mine),
        Panel(
          color: Ledger.overOf(context),
          borderColor: Ledger.overOf(context),
          title: tr('d_not_advice'),
          child: Text(tr('d_not_advice_body'), style: sans(context, size: 13, height: 1.5)),
        ),
      ],
    );
  }
}

/// Tax dates as an iCalendar file: one all-day event each, with a reminder two weeks before.
String _ics(List<_PayItem> items) {
  String esc(String v) => v.replaceAll(r'\', r'\\').replaceAll(';', r'\;').replaceAll(',', r'\,').replaceAll('\n', r'\n');
  final stamp = '${DateFormat('yyyyMMdd').format(DateTime.now().toUtc())}T${DateFormat('HHmmss').format(DateTime.now().toUtc())}Z';
  final sb = StringBuffer('BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Budget//Taxes//EN\r\nCALSCALE:GREGORIAN\r\nMETHOD:PUBLISH\r\n');
  for (final i in items) {
    final title = i.sum == null ? i.what : '${i.what} — ${i.sum}';
    sb.write('BEGIN:VEVENT\r\n'
        'UID:${DateFormat('yyyyMMdd').format(i.date)}-${i.what.hashCode.toUnsigned(32)}@budget\r\n'
        'DTSTAMP:$stamp\r\n'
        'DTSTART;VALUE=DATE:${DateFormat('yyyyMMdd').format(i.date)}\r\n'
        'DTEND;VALUE=DATE:${DateFormat('yyyyMMdd').format(i.date.add(const Duration(days: 1)))}\r\n'
        'SUMMARY:${esc(title)}\r\n'
        'BEGIN:VALARM\r\nTRIGGER:-P14D\r\nACTION:DISPLAY\r\nDESCRIPTION:${esc(title)}\r\nEND:VALARM\r\n'
        'END:VEVENT\r\n');
  }
  sb.write('END:VCALENDAR\r\n');
  return sb.toString();
}

/// Puts the dates into the computer's calendar: the .ics file is written to the documents folder
/// and opened with the calendar program (Outlook, Calendar…), which offers to add the events.
Future<void> _addToCalendar(BuildContext context, DeskController desk, List<_PayItem> items) async {
  final messenger = ScaffoldMessenger.of(context);
  if (items.isEmpty) {
    messenger.showSnackBar(SnackBar(content: Text(tr('d_no_payments'))));
    return;
  }
  final body = _ics(items);
  final name = items.length == 1 ? 'tax-${DateFormat('yyyy-MM-dd').format(items.first.date)}.ics' : 'taxes-${DateTime.now().year}.ics';
  final dir = await documentsDir(desk);
  final f = File('${dir.path}${Platform.pathSeparator}$name');
  await f.writeAsString(body, encoding: utf8);
  await openPath(f.path);
  messenger.showSnackBar(SnackBar(
    duration: const Duration(seconds: 10),
    content: Text(tr('d_cal_opened', [items.length, f.path])),
    action: context.mounted ? SnackBarAction(label: tr('d_save_as'), onPressed: () => saveWithDialog(context, desk, name, utf8.encode(body))) : null,
  ));
}

/// Salary tax worked out from the salary that arrived: net amounts by month, gross restored with
/// the country's rules, the rest of the year forecast from regular incomes or the recent average.
class _Salary {
  final String country;
  final TaxRules rules;
  final List<String> options;

  /// Net per month (whole units of the country's currency), index 0 = January; null = no data yet.
  final List<double?> net;
  final List<bool> forecast;
  final double ratio;
  final double grossYear;
  final double taxYear;
  final double withheld;
  final double future;

  _Salary(this.country, this.rules, this.options, this.net, this.forecast, this.ratio, this.grossYear, this.taxYear, this.withheld,
      this.future);

  static _Salary? compute(AppState s, dynamic data, String? preferred, List<String> mine) {
    final now = DateTime.now();
    final salaryCats = {for (final c in s.categories) if (c.key == 'salary') c.id};
    final txns = (data.txns as List<Txn>)
        .where((t) => t.kind == TxnKind.income && !t.excluded && salaryCats.contains(t.categoryId) && t.time.year == now.year)
        .toList();
    if (txns.isEmpty) return null;
    final byCurrency = <String, int>{};
    for (final t in txns) {
      byCurrency[t.currency] = (byCurrency[t.currency] ?? 0) + 1;
    }
    final options = [
      for (final r in taxRules.values)
        if (byCurrency.containsKey(r.currency) && mine.contains(r.country)) r.country,
    ];
    if (options.isEmpty) return null;
    final country = preferred != null && options.contains(preferred)
        ? preferred
        : options.firstWhere(mine.contains, orElse: () => options.first);
    final rules = taxRules[country]!;
    final net = List<double?>.filled(12, null);
    for (final t in txns) {
      final v = t.currency == rules.currency ? t.amountMinor : s.rates.convert(t.amountMinor, t.currency, rules.currency, t.time);
      if (v == null) continue;
      net[t.time.month - 1] = (net[t.time.month - 1] ?? 0) + v / 100;
    }
    final known = [for (var m = 0; m < now.month; m++) net[m]].whereType<double>().toList();
    final recent = known.length >= 3 ? known.sublist(known.length - 3) : known;
    var monthly = recent.isEmpty ? 0.0 : recent.reduce((a, b) => a + b) / recent.length;
    final rec = s.recurring.where((r) => r.kind == TxnKind.income && salaryCats.contains(r.categoryId)).firstOrNull;
    if (rec != null) {
      final v = rec.currency == rules.currency ? rec.amountMinor : s.rates.convert(rec.amountMinor, rec.currency, rules.currency, now);
      if (v != null) monthly = v / 100;
    }
    final forecast = List<bool>.filled(12, false);
    for (var m = now.month; m < 12; m++) {
      if (net[m] == null) {
        net[m] = monthly;
        forecast[m] = true;
      }
    }
    final netYear = net.whereType<double>().fold(0.0, (a, b) => a + b);
    final grossYear = rules.grossForNet(netYear);
    final ratio = netYear == 0 ? 1.0 : grossYear / netYear;
    var withheld = 0.0, future = 0.0;
    for (var m = 0; m < 12; m++) {
      final t = (net[m] ?? 0) * (ratio - 1);
      forecast[m] ? future += t : withheld += t;
    }
    return _Salary(country, rules, options, net, forecast, ratio, grossYear, grossYear - netYear, withheld, future);
  }

  String money(num v) => formatMoney((v * 100).round(), rules.currency);
}

class _Kpis extends StatelessWidget {
  final _Salary? sal;
  final bool nonResident;
  const _Kpis({required this.sal, required this.nonResident});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final desk = context.watch<DeskController>();
    final other = _OtherTaxes.yearTotal(desk);
    final vat = _VatPanel.total(s, desk);
    final extra = sal == null || !nonResident || sal!.rules.nonResidentRate == null
        ? 0.0
        : sal!.grossYear * sal!.rules.nonResidentRate! - sal!.taxYear;
    final next = _Payments.items(desk, sal, nonResident).firstOrNull;
    return AutoGrid(minWidth: 200, children: [
      Kpi(tr('d_tax_year_forecast'), sal == null ? '—' : sal!.money(sal!.taxYear + extra), accent: true, note: tr('d_tax_salary_only')),
      Kpi(tr('d_withheld'), sal == null ? '—' : sal!.money(sal!.withheld), note: tr('d_withheld_note')),
      Kpi(tr('d_pay_yourself'), formatMoney(other + (sal == null ? 0 : (extra * 100).round()), s.baseCurrency),
          note: extra > 0 ? tr('d_pay_yourself_extra') : tr('d_pay_yourself_note')),
      Kpi(tr('d_vat_in_buys'), '≈ ${formatMoney(vat, s.baseCurrency)}', note: tr('d_vat_inside')),
      Kpi(tr('d_next_date'), next == null ? '—' : DateFormat.MMMd(intlLocale).format(next.date), note: next?.what),
    ]);
  }
}

class _Residency extends StatelessWidget {
  final Map<String, int> days;
  final List<String> mine;
  const _Residency({required this.days, required this.mine});

  @override
  Widget build(BuildContext context) {
    final list = days.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: Ledger.shadeOf(context), borderRadius: BorderRadius.circular(8)),
      child: Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(tr('d_status_year', [DateTime.now().year]), style: sans(context, size: 13, weight: FontWeight.w600)),
        if (list.isEmpty) Text(tr('d_status_unknown'), style: sans(context, size: 13, color: Ledger.mutedOf(context))),
        for (final e in list)
          e.value >= 183
              ? tagGood(context, tr('d_resident_days', [countryName(e.key), e.value]))
              : tagWarn(context, tr('d_nonresident_days', [countryName(e.key), e.value])),
        Text(tr('d_status_how'), style: sans(context, size: 12.5, color: Ledger.mutedOf(context))),
      ]),
    );
  }
}

class _SalaryPanel extends StatelessWidget {
  final _Salary sal;
  final bool nonResident;
  final Set<String> countries;
  final ValueChanged<String> onCountry;
  final ValueChanged<bool> onResident;
  const _SalaryPanel({required this.sal, required this.nonResident, required this.countries, required this.onCountry, required this.onResident});

  @override
  Widget build(BuildContext context) {
    final r = sal.rules;
    final hasNr = r.nonResidentRate != null;
    final extra = nonResident && hasNr ? sal.grossYear * r.nonResidentRate! - sal.taxYear : 0.0;
    final base = r.taxableBase(sal.grossYear);
    final nextBound = r.brackets.map((b) => b.upTo).where((u) => u > base && u.isFinite).firstOrNull;
    final months = [for (var i = 0; i < 12; i++) DateFormat.MMM(intlLocale).format(DateTime(2024, i + 1))];
    final now = DateTime.now();
    return Panel(
      title: tr('d_salary_tax_in', [countryName(sal.country)]),
      trailing: Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (countries.length > 1)
          Choice(options: [for (final c in countries) (c, countryName(c))], value: sal.country, onChanged: onCountry, dense: true),
        if (hasNr)
          Seg(
            options: [(true, tr('d_rate_withheld')), (false, tr('d_rate_nonres', ['${(r.nonResidentRate! * 100).round()}%']))],
            value: !nonResident,
            onChanged: onResident,
          ),
      ]),
      child: SplitRow([
        (
          2,
          520,
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DeskBarChart(
              height: 220,
              rodWidth: 18,
              groups: [
                for (var m = 0; m < 12; m++)
                  [
                    DRod([
                      if (sal.net[m] != null) ...[
                        (sal.net[m]!, sal.forecast[m] ? const Color(0xFF4F9E86).withValues(alpha: .4) : const Color(0xFF4F9E86)),
                        (sal.net[m]! * (sal.ratio - 1), sal.forecast[m] ? Ledger.inkOf(context).withValues(alpha: .35) : Ledger.inkOf(context)),
                        if (nonResident && m == 11 && extra > 0) (extra, warnColor),
                      ],
                    ]),
                  ],
              ],
              xLabels: months,
              tooltip: (m) => sal.net[m] == null
                  ? months[m]
                  : '${DateFormat.yMMMM(intlLocale).format(DateTime(now.year, m + 1))}${sal.forecast[m] ? ' · ${tr('d_forecast')}' : ''}\n'
                      '${tr('d_net')}: ${sal.money(sal.net[m]!)}\n'
                      '${tr('d_tax')}: ${sal.money(sal.net[m]! * (sal.ratio - 1))}\n'
                      '${tr('d_gross_short')}: ${sal.money(sal.net[m]! * sal.ratio)}',
              onTap: (m) {
                if (sal.net[m] == null || sal.forecast[m]) return;
                context.read<DeskController>().go(DeskPages.operations, filter: 'month:${DateFormat('yyyy-MM').format(DateTime(now.year, m + 1))}:income');
              },
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 16, runSpacing: 4, children: [
              _key(context, const Color(0xFF4F9E86), tr('d_came_to_account')),
              _key(context, Ledger.inkOf(context), tr('d_withheld_tax')),
              _key(context, Ledger.inkOf(context).withValues(alpha: .35), tr('d_forecast')),
              if (nonResident) _key(context, warnColor, tr('d_possible_extra')),
            ]),
          ])
        ),
        (
          1,
          280,
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            LineItem(tr('d_gross_year'), sal.money(sal.grossYear)),
            LineItem(tr('d_withheld_so_far'), sal.money(sal.withheld)),
            LineItem(tr('d_withheld_ahead'), sal.money(sal.future)),
            Divider(color: Ledger.inkOf(context)),
            LineItem(tr('d_tax_year'), sal.money(sal.taxYear + extra), bold: true),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: extra > 0 ? softWarn : Ledger.withinOf(context), borderRadius: BorderRadius.circular(6)),
              child: Row(children: [
                Expanded(child: Text(extra > 0 ? tr('d_extra_if_nonres') : tr('d_pay_nothing'), style: sans(context, size: 13.5, weight: FontWeight.w600, color: extra > 0 ? warnDark : null))),
                Text(extra > 0 ? '+${sal.money(extra)}' : sal.money(0), style: mono(size: 13.5, weight: FontWeight.w600, color: extra > 0 ? warnDark : null)),
              ]),
            ),
            if (nextBound != null) ...[
              const SizedBox(height: 10),
              Text(tr('d_to_next_rate', [sal.money(nextBound - base)]), style: sans(context, size: 12.5, color: Ledger.mutedOf(context))),
              Meter(base / nextBound),
            ],
            const SizedBox(height: 8),
            Text(
              tr('d_salary_how', [sal.money(sal.net.whereType<double>().firstOrNull ?? 0), '${((sal.ratio - 1) / sal.ratio * 100).toStringAsFixed(1)}%']),
              style: sans(context, size: 12.5, color: Ledger.mutedOf(context), height: 1.45),
            ),
            if (sal.rules.country == 'DE' || sal.rules.country == 'NL')
              Text(tr('d_social_note'), style: sans(context, size: 12, color: Ledger.mutedOf(context))),
          ])
        ),
      ]),
    );
  }

  Widget _key(BuildContext c, Color color, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        Swatch(color, size: 11),
        const SizedBox(width: 6),
        Text(label, style: sans(c, size: 12.5)),
      ]);
}

class _InterestCard extends StatelessWidget {
  final List<String> mine;
  const _InterestCard({required this.mine});
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final desk = context.watch<DeskController>();
    final now = DateTime.now();
    final h = desk.profile.holdings.where((x) => x.type == 'deposit' || x.type == 'savings').toList();
    final got = h.fold<int>(0, (a, x) => a + (s.toBaseAmount(x.receivedMinor, x.currency, now) ?? 0));
    final ahead = h.fold<double>(0, (a, x) => a + (s.toBaseAmount(x.monthlyIncome.round(), x.currency, now) ?? 0) * (12 - now.month));
    return Panel(
      title: tr('d_interest'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (h.isEmpty) Text(tr('d_interest_none'), style: sans(context, size: 13, color: Ledger.mutedOf(context))),
        for (final x in h) LineItem(x.name, formatMoney(x.receivedMinor, x.currency), sub: x.where),
        if (h.isNotEmpty) LineItem(tr('d_forecast_ahead'), '+${formatMoney(ahead.round(), s.baseCurrency)}'),
        Divider(color: Ledger.trackOf(context)),
        LineItem(tr('d_year_total'), formatMoney(got + ahead.round(), s.baseCurrency), bold: true),
        const SizedBox(height: 6),
        Text(mine.contains('RU') ? tr('d_interest_ru') : tr('d_interest_generic'), style: sans(context, size: 12.5, color: Ledger.mutedOf(context), height: 1.45)),
      ]),
    );
  }
}

class _BrokerCard extends StatelessWidget {
  final List<String> mine;
  const _BrokerCard({required this.mine});
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final desk = context.watch<DeskController>();
    final now = DateTime.now();
    final h = desk.profile.holdings.where((x) => x.type == 'bonds' || x.type == 'stocks' || x.type == 'fund').toList();
    final got = h.fold<int>(0, (a, x) => a + (s.toBaseAmount(x.receivedMinor, x.currency, now) ?? 0));
    final ru = mine.contains('RU');
    return Panel(
      title: tr('d_broker'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (h.isEmpty) Text(tr('d_broker_none'), style: sans(context, size: 13, color: Ledger.mutedOf(context))),
        for (final x in h) LineItem(x.name, formatMoney(x.receivedMinor, x.currency), sub: tr('d_type_${x.type}')),
        if (h.isNotEmpty && ru) LineItem(tr('d_broker_withheld'), formatMoney((got / .87 * .13).round(), s.baseCurrency)),
        const SizedBox(height: 6),
        Text(ru ? tr('d_broker_ru') : tr('d_broker_generic'), style: sans(context, size: 12.5, color: Ledger.mutedOf(context), height: 1.45)),
      ]),
    );
  }
}

class _OtherIncomeCard extends StatelessWidget {
  final _Salary? sal;
  const _OtherIncomeCard({required this.sal});
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final d = context.watch<DeskController>().data;
    final now = DateTime.now();
    final salary = {for (final c in s.categories) if (c.key == 'salary') c.id};
    final sums = <int?, int>{};
    for (final t in d.txns) {
      if (t.kind != TxnKind.income || t.excluded || salary.contains(t.categoryId) || t.time.year != now.year) continue;
      sums[t.categoryId] = (sums[t.categoryId] ?? 0) + (s.toBase(t) ?? 0);
    }
    return Panel(
      title: tr('d_other_income'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (sums.isEmpty) Text(tr('d_other_income_none'), style: sans(context, size: 13, color: Ledger.mutedOf(context))),
        for (final e in sums.entries)
          LineItem(e.key == null ? tr('d_uncategorized') : s.categoryName(s.categoryById[e.key]!), formatMoney(e.value, s.baseCurrency)),
        const SizedBox(height: 6),
        Text(tr('d_other_income_note'), style: sans(context, size: 12.5, color: Ledger.mutedOf(context), height: 1.45)),
      ]),
    );
  }
}

class _VatPanel extends StatelessWidget {
  final List<String> mine;
  const _VatPanel({required this.mine});

  /// (low, typical, high) VAT share for a category in a country: rate / (100 + rate).
  static (double, double, double) shareFor(String? key, CountryInfo c) {
    final std = c.vat ?? 0, red = c.vatReduced ?? std;
    double f(double r) => r / (100 + r);
    return switch (key) {
      'food' => (f(red / 3), f(red), f(std)),
      'education' => (0, 0, f(red)),
      'health' => (0, f(red), f(std)),
      'housing' => (0, 0, f(red)),
      'transport' => (f(red / 2), f(red), f(std)),
      _ => (f(std / 3), f(std), f(std)),
    };
  }

  static List<(int?, String, int, (double, double, double))> rows(AppState s, DeskController desk) {
    final now = DateTime.now();
    final byCatCountry = <(int?, String), int>{};
    final countryOf = <String, String>{};
    for (final c in desk.profile.countries.map((c) => countryByCode[c.code]).whereType<CountryInfo>()) {
      countryOf.putIfAbsent(c.currency, () => c.code);
    }
    for (final t in desk.data.txns) {
      if (t.kind != TxnKind.expense || t.excluded || t.time.year != now.year) continue;
      final country = countryOf[t.currency];
      if (country == null) continue;
      final k = (t.categoryId, country);
      byCatCountry[k] = (byCatCountry[k] ?? 0) + (s.toBase(t) ?? 0);
    }
    return [
      for (final e in byCatCountry.entries)
        (e.key.$1, e.key.$2, e.value, shareFor(e.key.$1 == null ? null : s.categoryById[e.key.$1]?.key, countryByCode[e.key.$2]!)),
    ]..sort((a, b) => b.$3.compareTo(a.$3));
  }

  static int total(AppState s, DeskController desk) => rows(s, desk).fold(0, (a, r) => a + (r.$3 * r.$4.$2).round());

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final desk = context.watch<DeskController>();
    final list = rows(s, desk);
    var lo = 0.0, mid = 0.0, hi = 0.0, spent = 0;
    for (final r in list) {
      lo += r.$3 * r.$4.$1;
      mid += r.$3 * r.$4.$2;
      hi += r.$3 * r.$4.$3;
      spent += r.$3;
    }
    String money(num v) => formatMoney(v.round(), s.baseCurrency);
    String pct(double v) => '${NumberFormat('0.#', intlLocale).format(v / (1 - v) * 100)}%';
    return Panel(
      title: tr('d_vat_title', [DateTime.now().year]),
      subtitle: tr('d_vat_sub'),
      child: SplitRow([
        (
          2,
          560,
          Column(children: [
            TableHead([
              (tr('category'), 5, false),
              (tr('d_country'), 3, false),
              (tr('d_spent'), 3, true),
              (tr('d_rate_used'), 3, true),
              (tr('d_vat_inside_short'), 3, true),
              (tr('d_range'), 4, true),
            ]),
            if (list.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(tr('d_nothing_yet'))),
            for (final (cat, country, sum, share) in list.take(12))
              TableLine([
                (Text(cat == null ? tr('d_uncategorized') : s.categoryName(s.categoryById[cat]!), style: sans(context, size: 13.5)), 5),
                (Text(countryName(country), style: sans(context, size: 13)), 3),
                (numCell(context, money(sum)), 3),
                (numCell(context, pct(share.$2), color: Ledger.mutedOf(context)), 3),
                (numCell(context, money(sum * share.$2), bold: true), 3),
                (numCell(context, '${money(sum * share.$1)}–${money(sum * share.$3)}', size: 11.5, color: Ledger.mutedOf(context)), 4),
              ]),
          ])
        ),
        (
          1,
          280,
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Ledger.emerald, borderRadius: BorderRadius.circular(8)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('d_vat_in_spending'), style: sans(context, size: 12.5, color: const Color(0xFFCFE6DC))),
                Text('≈ ${money(mid)}', style: mono(size: 26, weight: FontWeight.w600, color: Ledger.paper)),
                Text(tr('d_vat_share', [spent == 0 ? '0%' : '${(mid / spent * 100).toStringAsFixed(1)}%', money(lo), money(hi)]),
                    style: sans(context, size: 12.5, color: const Color(0xFFCFE6DC))),
              ]),
            ),
            const SizedBox(height: 10),
            Text(tr('d_vat_how'), style: sans(context, size: 12.5, color: Ledger.mutedOf(context), height: 1.45)),
            if (mine.contains('US')) Text(tr('d_vat_us'), style: sans(context, size: 12.5, color: Ledger.mutedOf(context))),
          ])
        ),
      ]),
    );
  }
}

/// Property, vehicle, self-employment and the user's own taxes: filled in here, counted and
/// optionally turned into a yearly regular payment (which the phone reminds about).
class _OtherTaxes extends StatefulWidget {
  final List<String> mine;
  const _OtherTaxes({required this.mine});

  static const kinds = ['property', 'vehicle', 'self', 'custom'];

  static double amountOf(Map<String, String> v, String kind) {
    double n(String k) => parseNum(v['$kind.$k'] ?? '') ?? 0;
    return switch (kind) {
      'property' => math.max(0, n('value') - n('free')) * n('rate') / 100 * (n('share') == 0 ? 1 : n('share')),
      'vehicle' => n('power') * n('rate') * (n('months') == 0 ? 12 : n('months')) / 12,
      'self' => n('income') * 12 * n('rate') / 100,
      _ => n('amount'),
    };
  }

  /// Taxes to pay yourself this year, in base currency.
  static int yearTotal(DeskController desk) {
    final v = desk.profile.taxInputs;
    final now = DateTime.now();
    var sum = 0;
    for (final k in kinds) {
      final cur = v['$k.currency'] ?? desk.state.baseCurrency;
      sum += desk.state.toBaseAmount((amountOf(v, k) * 100).round(), cur, now) ?? 0;
    }
    return sum;
  }

  @override
  State<_OtherTaxes> createState() => _OtherTaxesState();
}

class _OtherTaxesState extends State<_OtherTaxes> {
  final ctrl = <String, TextEditingController>{};

  TextEditingController c(DeskController desk, String key, [String def = '']) =>
      ctrl.putIfAbsent(key, () => TextEditingController(text: desk.profile.taxInputs[key] ?? def));

  @override
  void dispose() {
    for (final x in ctrl.values) {
      x.dispose();
    }
    super.dispose();
  }

  void _set(DeskController desk, String key, String v) {
    desk.profile.taxInputs[key] = v;
    desk.saveProfile(refold: false);
  }

  @override
  Widget build(BuildContext context) {
    final desk = context.watch<DeskController>();
    final ru = widget.mine.contains('RU');
    final v = desk.profile.taxInputs;
    Widget field(String key, String label, {String? suffix, String def = '', bool numeric = true}) =>
        FieldBox(label, c(desk, key, def), suffix: suffix, numeric: numeric, onChanged: (x) => _set(desk, key, x));
    Widget card(String kind, String title, List<Widget> fields, String how) {
      final amount = _OtherTaxes.amountOf(v, kind);
      final cur = v['$kind.currency'] ?? desk.state.baseCurrency;
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(border: Border.all(color: Ledger.inkOf(context)), borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(title, style: sans(context, size: 14.5, weight: FontWeight.w600))),
            Text(amount == 0 ? '—' : formatMoney((amount * 100).round(), cur), style: mono(size: 14, weight: FontWeight.w600)),
            IconButton(
              tooltip: tr('d_clear_all'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.backspace_outlined, size: 17),
              onPressed: () {
                for (final e in ctrl.entries.where((e) => e.key.startsWith('$kind.'))) {
                  e.value.clear();
                  v.remove(e.key);
                }
                desk.saveProfile(refold: false);
              },
            ),
          ]),
          const SizedBox(height: 10),
          AutoGrid(minWidth: 130, spacing: 8, children: fields),
          const SizedBox(height: 8),
          Text(how, style: sans(context, size: 12.5, color: Ledger.mutedOf(context))),
          const SizedBox(height: 8),
          _ReminderRow(kind: kind, amount: amount, currency: cur),
        ]),
      );
    }

    return Panel(
      title: tr('d_other_taxes'),
      subtitle: tr('d_other_taxes_sub'),
      child: AutoGrid(minWidth: 320, children: [
        card('property', tr('d_tax_property'), [
          field('property.value', tr('d_property_value')),
          field('property.free', ru ? tr('d_property_free_ru') : tr('d_property_free')),
          field('property.share', tr('d_share_of'), def: '1'),
          field('property.rate', tr('d_rate'), suffix: '%', def: ru ? '0.1' : ''),
        ], ru ? tr('d_property_how_ru') : tr('d_property_how')),
        card('vehicle', tr('d_tax_vehicle'), [
          field('vehicle.power', ru ? tr('d_power_hp') : tr('d_power')),
          field('vehicle.rate', tr('d_rate_per_unit')),
          field('vehicle.months', tr('d_months_owned'), def: '12'),
        ], tr('d_vehicle_how')),
        card('self', ru ? tr('d_tax_self_ru') : tr('d_tax_self'), [
          field('self.income', tr('d_income_month_field')),
          field('self.rate', tr('d_rate'), suffix: '%', def: ru ? '4' : ''),
        ], ru ? tr('d_self_how_ru') : tr('d_self_how')),
        card('custom', tr('d_tax_custom'), [
          field('custom.name', tr('name'), numeric: false),
          field('custom.amount', tr('col_amount')),
        ], tr('d_custom_how')),
      ]),
    );
  }
}

/// "Remind" for a tax: a yearly regular payment on the chosen date (the phone reminds about it).
class _ReminderRow extends StatelessWidget {
  final String kind;
  final double amount;
  final String currency;
  const _ReminderRow({required this.kind, required this.amount, required this.currency});

  @override
  Widget build(BuildContext context) {
    final desk = context.watch<DeskController>();
    final s = desk.state;
    final v = desk.profile.taxInputs;
    final id = int.tryParse(v['$kind.recurring'] ?? '');
    final rec = id == null ? null : s.recurring.where((r) => r.id == id).firstOrNull;
    final due = DateTime.tryParse(v['$kind.due'] ?? '') ?? DateTime(DateTime.now().year, 12, 1);
    return Row(children: [
      TextButton(
        onPressed: () async {
          final d = await showDatePicker(context: context, initialDate: due, firstDate: DateTime(2020), lastDate: DateTime(2100));
          if (d == null) return;
          v['$kind.due'] = d.toIso8601String();
          await desk.saveProfile(refold: false);
        },
        child: Text(tr('d_due', [DateFormat.yMMMd(intlLocale).format(due)])),
      ),
      const Spacer(),
      Text(tr('d_remind'), style: sans(context, size: 13)),
      Toggle(rec != null, onChanged: amount <= 0 && rec == null
          ? null
          : (on) async {
              if (on) {
                await s.saveRecurring(Recurring(
                  name: '${tr('d_tax_prefix')} ${kind == 'custom' ? (v['custom.name'] ?? '') : tr('d_tax_$kind')}',
                  amountMinor: (amount * 100).round(),
                  currency: currency,
                  kind: TxnKind.expense,
                  every: Every.year,
                  day: due.day,
                  next: DateTime(due.year, due.month, due.day),
                ));
                final created = s.recurring.where((r) => r.name.startsWith(tr('d_tax_prefix'))).fold<Recurring?>(
                    null, (a, r) => a == null || (r.id ?? 0) > (a.id ?? 0) ? r : a);
                v['$kind.recurring'] = '${created?.id ?? ''}';
              } else if (rec != null) {
                await s.deleteRecurring(rec);
                v.remove('$kind.recurring');
              }
              await desk.saveProfile(refold: false);
            }),
    ]);
  }
}

class _PayItem {
  final DateTime date;
  final String what;
  final String? sum;

  /// ok | wait | plan | none
  final String status;
  const _PayItem(this.date, this.what, this.sum, this.status);
}

class _Payments extends StatelessWidget {
  final List<String> mine;
  final _Salary? sal;
  final bool nonResident;
  const _Payments({required this.mine, required this.sal, required this.nonResident});

  static List<_PayItem> items(DeskController desk, _Salary? sal, bool nonResident) {
    final now = DateTime.now();
    final v = desk.profile.taxInputs;
    final out = <_PayItem>[];
    for (final c in desk.profile.countries) {
      final r = taxRules[c.code];
      if (r == null) continue;
      for (final d in r.deadlines) {
        var date = DateTime(now.year, d.month, d.day);
        if (date.isBefore(now)) date = DateTime(now.year + 1, d.month, d.day);
        out.add(_PayItem(date, '${countryName(c.code)}: ${tr(d.what)}', null, 'none'));
      }
    }
    for (final k in _OtherTaxes.kinds) {
      final a = _OtherTaxes.amountOf(v, k);
      if (a <= 0) continue;
      final due = DateTime.tryParse(v['$k.due'] ?? '') ?? DateTime(now.year, 12, 1);
      out.add(_PayItem(due, k == 'custom' ? (v['custom.name'] ?? tr('d_tax_custom')) : tr('d_tax_$k'),
          formatMoney((a * 100).round(), v['$k.currency'] ?? desk.state.baseCurrency), v['$k.recurring'] != null ? 'plan' : 'wait'));
    }
    if (sal != null && nonResident && sal.rules.nonResidentRate != null) {
      out.add(_PayItem(DateTime(now.year, 12, 31), tr('d_possible_extra'),
          sal.money(sal.grossYear * sal.rules.nonResidentRate! - sal.taxYear), 'wait'));
    }
    out.removeWhere((i) => i.date.isBefore(DateTime(now.year, now.month, now.day)));
    out.sort((a, b) => a.date.compareTo(b.date));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final desk = context.watch<DeskController>();
    final list = items(desk, sal, nonResident);
    return Panel(
      title: tr('d_payments'),
      subtitle: tr('d_payments_sub'),
      trailing: list.isEmpty ? null : DeskButton(tr('d_all_to_calendar'), small: true, icon: Icons.event_outlined, onTap: () => _addToCalendar(context, desk, list)),
      child: Column(children: [
        TableHead([(tr('d_when'), 3, false), (tr('d_what'), 8, false), (tr('col_amount'), 3, true), (tr('d_status'), 3, true), ('', 1, true)]),
        if (list.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(tr('d_no_payments'))),
        for (final i in list)
          TableLine([
            (Text(DateFormat.yMMMd(intlLocale).format(i.date), style: mono(size: 13, weight: FontWeight.w600)), 3),
            (Text(i.what, style: sans(context, size: 13.5)), 8),
            (numCell(context, i.sum ?? '—', bold: true), 3),
            (
              Align(
                alignment: Alignment.centerRight,
                child: switch (i.status) {
                  'ok' => tagGood(context, tr('d_st_ok')),
                  'wait' => tagWarn(context, tr('d_st_wait')),
                  'plan' => tagGood(context, tr('d_st_reminded')),
                  _ => tagPlain(context, tr('d_st_deadline')),
                },
              ),
              3
            ),
            (
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: tr('d_to_calendar'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.event_available_outlined, size: 18),
                  onPressed: () => _addToCalendar(context, desk, [i]),
                ),
              ),
              1
            ),
          ]),
      ]),
    );
  }
}

/// Income tax calculator, like the salary calculators people already know: an amount per month or
/// per year, before tax or take-home; the result updates while typing and shows each step.
class _Calculator extends StatefulWidget {
  final List<String> countries;
  final _Salary? sal;
  const _Calculator({required this.countries, required this.sal});
  @override
  State<_Calculator> createState() => _CalculatorState();
}

class _CalculatorState extends State<_Calculator> {
  String? country;
  final amount = TextEditingController();
  final deduct = TextEditingController();
  bool yearly = false;
  bool gross = true;
  bool resident = true;

  @override
  void dispose() {
    amount.dispose();
    deduct.dispose();
    super.dispose();
  }

  void _clear() => setState(() {
        amount.clear();
        deduct.clear();
        resident = true;
      });

  void _useSalary(_Salary sal) => setState(() {
        country = sal.country;
        gross = true;
        yearly = true;
        amount.text = NumberFormat('#,##0', intlLocale).format(sal.grossYear);
      });

  @override
  Widget build(BuildContext context) {
    final c = widget.countries.contains(country) ? country! : widget.countries.first;
    final r = taxRules[c]!;
    final x = parseNum(amount.text);
    final ded = parseNum(deduct.text) ?? 0;
    final flat = !resident && r.nonResidentRate != null;
    double taxOf(double g) => r.tax(g, resident: resident, extraDeductions: ded).$1;
    double? grossYear;
    if (x != null && x > 0) {
      final entered = yearly ? x : x * 12;
      if (gross) {
        grossYear = entered;
      } else {
        // Take-home given: find the income before tax that leaves exactly this much.
        var lo = entered, hi = entered * 3 + 1;
        for (var i = 0; i < 60; i++) {
          final mid = (lo + hi) / 2;
          mid - taxOf(mid) < entered ? lo = mid : hi = mid;
        }
        grossYear = (lo + hi) / 2;
      }
    }
    final (t, marg) = grossYear == null ? (0.0, 0.0) : r.tax(grossYear, resident: resident, extraDeductions: ded);
    final net = (grossYear ?? 0) - t;
    String money(num v) => formatMoney((v * 100).round(), r.currency);
    String pct(double v) => '${NumberFormat('0.##', intlLocale).format(v * 100)}%';
    final muted = Ledger.mutedOf(context);
    final mySalary = widget.sal != null && widget.sal!.country == c ? widget.sal : null;

    final inputs = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Seg(options: [(false, tr('d_calc_month')), (true, tr('d_calc_year'))], value: yearly, onChanged: (v) => setState(() => yearly = v)),
      const SizedBox(height: 8),
      Seg(options: [(true, tr('d_before_tax')), (false, tr('d_take_home'))], value: gross, onChanged: (v) => setState(() => gross = v)),
      const SizedBox(height: 12),
      FieldBox(
        tr(gross ? 'd_calc_gross_in' : 'd_calc_net_in', [yearly ? tr('d_calc_year').toLowerCase() : tr('d_calc_month').toLowerCase(), r.currency]),
        amount,
        hint: '0',
        onChanged: (_) => setState(() {}),
      ),
      if (r.nonResidentRate != null) ...[
        const SizedBox(height: 10),
        Seg(options: [(true, tr('d_resident')), (false, tr('d_nonresident'))], value: resident, onChanged: (v) => setState(() => resident = v)),
      ],
      if (!r.linearZones && !flat) ...[
        const SizedBox(height: 10),
        FieldBox(r.country == 'CN' ? tr('d_special_deductions') : tr('d_deductions_year'), deduct, hint: '0', onChanged: (_) => setState(() {})),
      ],
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (mySalary != null) DeskButton(tr('d_use_my_salary'), icon: Icons.download_outlined, onTap: () => _useSalary(mySalary)),
        ClearAllButton(onTap: x == null && ded == 0 ? null : _clear),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: Text('${r.source} · ${tr('d_checked_on', [r.checked])}', style: sans(context, size: 12, color: muted))),
        if (r.partial) tagWarn(context, tr('d_checked_partly')) else tagGood(context, tr('d_checked')),
      ]),
    ]);

    Widget results;
    if (grossYear == null) {
      results = Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(color: Ledger.shadeOf(context), borderRadius: BorderRadius.circular(8)),
        child: Column(children: [
          Icon(Icons.calculate_outlined, size: 32, color: muted),
          const SizedBox(height: 8),
          Text(tr('d_calc_enter'), textAlign: TextAlign.center, style: sans(context, size: 13.5, color: muted, height: 1.45)),
        ]),
      );
    } else {
      final g = grossYear;
      final base = r.taxableBase(g, extraDeductions: ded);
      results = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Ledger.emerald, borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('d_tax_year'), style: sans(context, size: 12.5, color: const Color(0xFFCFE6DC))),
            Text(money(t), style: mono(size: 28, weight: FontWeight.w600, color: Ledger.paper)),
            Text(tr('d_calc_rates', [g == 0 ? '0%' : pct(t / g), pct(marg)]), style: sans(context, size: 12.5, color: const Color(0xFFCFE6DC))),
          ]),
        ),
        const SizedBox(height: 12),
        TableHead([('', 4, false), (tr('d_calc_month'), 3, true), (tr('d_calc_year'), 3, true)]),
        for (final (label, v, bold) in [(tr('d_before_tax'), g, false), (tr('d_calc_tax'), t, false), (tr('d_take_home'), net, true)])
          TableLine([
            (Text(label, style: sans(context, size: 13.5, weight: bold ? FontWeight.w600 : FontWeight.w400)), 4),
            (numCell(context, money(v / 12), bold: bold), 3),
            (numCell(context, money(v), bold: bold), 3),
          ], padding: 4),
        const SizedBox(height: 12),
        // Where the money goes: take-home and tax as one bar.
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 12,
            child: Row(children: [
              Expanded(flex: math.max(1, (net / g * 1000).round()), child: Container(color: const Color(0xFF4F9E86))),
              if (t > 0) Expanded(flex: math.max(1, (t / g * 1000).round()), child: Container(color: Ledger.inkOf(context))),
            ]),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(spacing: 14, children: [
          _dot(context, const Color(0xFF4F9E86), '${tr('d_take_home')} ${g == 0 ? '' : pct(net / g)}'),
          _dot(context, Ledger.inkOf(context), '${tr('d_calc_tax')} ${g == 0 ? '' : pct(t / g)}'),
        ]),
        const SizedBox(height: 14),
        Text(tr('d_calc_steps'), style: sans(context, size: 13, weight: FontWeight.w600)),
        const SizedBox(height: 4),
        if (flat)
          LineItem(tr('d_nonresident'), '${pct(r.nonResidentRate!)} × ${money(g)} = ${money(t)}')
        else if (r.linearZones) ...[
          for (var i = 0; i < r.brackets.length; i++) LineItem(_bracketLabel(r, i), pct(r.brackets[i].rate)),
          Text(tr('d_linear_note'), style: sans(context, size: 12, color: muted)),
        ] else ...[
          Text(tr('d_calc_base', [money(g), money(r.allowance), money(ded), money(base)]), style: sans(context, size: 12.5, color: muted, height: 1.45)),
          for (var i = 0, prev = 0.0; i < r.brackets.length; prev = r.brackets[i].upTo, i++)
            () {
              final inside = (math.min(base, r.brackets[i].upTo) - prev).clamp(0, double.infinity).toDouble();
              final active = base > prev && (base <= r.brackets[i].upTo || !r.brackets[i].upTo.isFinite);
              return LineItem(
                _bracketLabel(r, i, ofBase: true),
                inside == 0 ? pct(r.brackets[i].rate) : '${pct(r.brackets[i].rate)} × ${money(inside)} = ${money(inside * r.brackets[i].rate)}',
                bold: active,
                color: inside == 0 ? muted : null,
              );
            }(),
        ],
        const SizedBox(height: 6),
        Text(tr('d_calc_note_${r.tier}'), style: sans(context, size: 12, color: muted)),
      ]);
    }

    return Panel(
      title: tr('d_calculator'),
      subtitle: tr('d_calc_sub'),
      trailing: widget.countries.length > 1
          ? Choice(options: [for (final k in widget.countries) (k, countryName(k))], value: c, onChanged: (v) => setState(() => country = v), dense: true)
          : Text(countryName(c), style: sans(context, size: 13, weight: FontWeight.w600)),
      child: SplitRow([(1, 300, inputs), (1, 360, results)]),
    );
  }

  Widget _dot(BuildContext c, Color color, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        Swatch(color, size: 10),
        const SizedBox(width: 6),
        Text(label, style: sans(c, size: 12.5)),
      ]);

  /// "up to X", "X — Y", "above X", or "any income" for a single flat bracket.
  static String _bracketLabel(TaxRules r, int i, {bool ofBase = false}) {
    String bound(int k) => NumberFormat.compact(locale: intlLocale).format(r.brackets[k].upTo + (r.linearZones || ofBase ? 0 : r.allowance));
    final last = !r.brackets[i].upTo.isFinite;
    if (i == 0) return last ? tr('d_any_income') : '${tr('d_up_to')} ${bound(0)}';
    return last ? '${tr('d_above')} ${bound(i - 1)}' : '${bound(i - 1)} — ${bound(i)}';
  }
}
