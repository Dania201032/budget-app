import 'package:intl/intl.dart';

import '../data/models.dart';
import '../data/repository.dart';
import '../domain/money.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'profile.dart';

/// A "What to look at" hint on the Summary.
class Insight {
  /// Hiding key: the rule plus what it is about, for the current month.
  final String id;
  final String rule;

  /// bad | good | info
  final String tone;
  final String title;
  final String body;

  /// How much money it is about (base currency), for the order.
  final int impactMinor;

  /// Page to open and an optional operations filter ('review', a category id…).
  final int? page;
  final String? filter;

  const Insight({
    required this.id,
    required this.rule,
    required this.tone,
    required this.title,
    required this.body,
    required this.impactMinor,
    this.page,
    this.filter,
  });
}

/// Per-payee totals for the Analytics table.
class PayeeStats {
  final String name;
  int count = 0;
  int sum = 0;
  int recent = 0;
  int earlier = 0;
  int? categoryId;
  PayeeStats(this.name);
}

/// Everything the desktop pages show beyond AppState's own numbers: thirteen months of
/// transactions folded by month, category, payee, weekday and hour. Recomputed when data changes.
class DeskData {
  final DateTime now;

  /// First days of the last 13 months, oldest first; the last one is the current month.
  final List<DateTime> months;
  final List<Txn> txns;
  final List<int> spentByMonth;
  final List<int> incomeByMonth;

  /// category id -> amount per month (index as [months]).
  final Map<int?, List<int>> spentByCategory;
  final Map<int?, List<int>> incomeByCategory;

  /// Spending per day of the current and the previous month.
  final List<int> thisMonthDays;
  final List<int> prevMonthDays;

  /// [weekday 0 = Monday][two-hour block], last six months.
  final List<List<int>> heat;
  final List<PayeeStats> payees;

  /// Days of this year with spending in each country (by the currency of the day's payments).
  final Map<String, int> daysByCountry;
  final List<Insight> insights;

  DeskData._({
    required this.now,
    required this.months,
    required this.txns,
    required this.spentByMonth,
    required this.incomeByMonth,
    required this.spentByCategory,
    required this.incomeByCategory,
    required this.thisMonthDays,
    required this.prevMonthDays,
    required this.heat,
    required this.payees,
    required this.daysByCountry,
    required this.insights,
  });

  static DeskData empty() {
    final now = DateTime.now();
    return DeskData._(
      now: now,
      months: [for (var i = 12; i >= 0; i--) DateTime(now.year, now.month - i)],
      txns: const [],
      spentByMonth: List.filled(13, 0),
      incomeByMonth: List.filled(13, 0),
      spentByCategory: const {},
      incomeByCategory: const {},
      thisMonthDays: List.filled(DateTime(now.year, now.month + 1, 0).day, 0),
      prevMonthDays: List.filled(DateTime(now.year, now.month, 0).day, 0),
      heat: List.generate(7, (_) => List.filled(12, 0)),
      payees: const [],
      daysByCountry: const {},
      insights: const [],
    );
  }

  int monthIndex(DateTime t) => (t.year - months.first.year) * 12 + t.month - months.first.month;

  /// Median of a category's spending over the three months before the current one.
  int median3(int? categoryId) {
    final list = spentByCategory[categoryId];
    if (list == null) return 0;
    final v = [list[9], list[10], list[11]]..sort();
    return v[1];
  }

  /// This month's spending in a category extrapolated to the whole month.
  int forecastOf(int? categoryId, {required int daysPassed, required int daysInMonth}) {
    final spent = spentByCategory[categoryId]?[12] ?? 0;
    return daysPassed == 0 ? spent : (spent / daysPassed * daysInMonth).round();
  }

  static Future<DeskData> load(AppState s, DeskProfile p) async {
    final now = DateTime.now();
    final months = [for (var i = 12; i >= 0; i--) DateTime(now.year, now.month - i)];
    final txns = await s.repo.txnsBetween(months.first, DateTime(now.year, now.month + 1));
    final foreign = {for (final t in txns) t.currency}..remove(s.baseCurrency);
    if (foreign.isNotEmpty) {
      try {
        await s.rates.ensure({for (final t in txns) DateTime(t.time.year, t.time.month, t.time.day)}, foreign, maxRequests: 30);
      } catch (_) {
        // Offline: what has a rate counts, the rest waits for the next refresh.
      }
    }
    int idx(DateTime t) => (t.year - months.first.year) * 12 + t.month - months.first.month;

    final spent = List.filled(13, 0), income = List.filled(13, 0);
    final byCat = <int?, List<int>>{}, inCat = <int?, List<int>>{};
    final thisDays = List.filled(DateTime(now.year, now.month + 1, 0).day, 0);
    final prevDays = List.filled(DateTime(now.year, now.month, 0).day, 0);
    final heat = List.generate(7, (_) => List.filled(12, 0));
    final payees = <String, PayeeStats>{};
    final sixAgo = DateTime(now.year, now.month - 5);
    final threeAgo = DateTime(now.year, now.month - 2);
    final dayCurrency = <DateTime, Map<String, int>>{};

    for (final t in txns) {
      if (t.excluded) continue;
      final v = s.toBase(t);
      if (v == null) continue;
      final i = idx(t.time);
      if (i < 0 || i > 12) continue;
      if (t.kind == TxnKind.income) {
        income[i] += v;
        inCat.putIfAbsent(t.categoryId, () => List.filled(13, 0))[i] += v;
        continue;
      }
      spent[i] += v;
      byCat.putIfAbsent(t.categoryId, () => List.filled(13, 0))[i] += v;
      if (i == 12) thisDays[t.time.day - 1] += v;
      if (i == 11) prevDays[t.time.day - 1] += v;
      if (!t.time.isBefore(sixAgo)) {
        heat[t.time.weekday - 1][t.time.hour ~/ 2] += v;
        final name = t.merchant?.trim();
        if (name != null && name.isNotEmpty) {
          final ps = payees.putIfAbsent(name, () => PayeeStats(name));
          ps.count++;
          ps.sum += v;
          ps.categoryId ??= t.categoryId;
          if (!t.time.isBefore(threeAgo)) {
            ps.recent += v;
          } else {
            ps.earlier += v;
          }
        }
      }
      if (t.time.year == now.year) {
        final day = DateTime(t.time.year, t.time.month, t.time.day);
        final m = dayCurrency.putIfAbsent(day, () => {});
        m[t.currency] = (m[t.currency] ?? 0) + v;
      }
    }

    // A day counts for the country whose currency took most of that day's spending.
    final countryOfCurrency = <String, String>{};
    for (final c in [...p.countries.map((c) => countryByCode[c.code]).whereType<CountryInfo>(), ...countryInfos]) {
      countryOfCurrency.putIfAbsent(c.currency, () => c.code);
    }
    final days = <String, int>{};
    for (final m in dayCurrency.values) {
      final top = (m.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
      final c = countryOfCurrency[top];
      if (c != null) days[c] = (days[c] ?? 0) + 1;
    }

    final data = DeskData._(
      now: now,
      months: months,
      txns: txns,
      spentByMonth: spent,
      incomeByMonth: income,
      spentByCategory: byCat,
      incomeByCategory: inCat,
      thisMonthDays: thisDays,
      prevMonthDays: prevDays,
      heat: heat,
      payees: payees.values.toList()..sort((a, b) => b.sum.compareTo(a.sum)),
      daysByCountry: days,
      insights: const [],
    );
    return data._withInsights(s, p);
  }

  DeskData _withInsights(AppState s, DeskProfile p) {
    final list = <Insight>[];
    final m = s.todayStats;
    final base = s.baseCurrency;
    String money(num v) => formatMoney(v.round(), base);
    final monthKey = DateFormat('yyyy-MM').format(now);
    final daysIn = DateTime(now.year, now.month + 1, 0).day;
    final passed = now.day;
    final cats = s.categoryById;
    String catName(int? id) => id == null ? tr('d_uncategorized') : (cats[id] == null ? '—' : s.categoryName(cats[id]!));

    for (final r in hintRules) {
      if (!p.hintOn(r.key)) continue;
      final lvl = p.hintLevel(r);
      switch (r.key) {
        case 'over':
          for (final e in p.categoryPlan.entries) {
            if (e.value <= 0) continue;
            final fc = forecastOf(e.key, daysPassed: passed, daysInMonth: daysIn);
            final over = fc - e.value;
            final hit = switch (r.levels.indexOf(lvl)) {
              0 => fc > e.value * 1.05,
              1 => over > 5000,
              _ => (spentByCategory[e.key]?[12] ?? 0) > e.value,
            };
            if (hit && over > 0) {
              list.add(Insight(
                id: 'over:${e.key}:$monthKey',
                rule: tr('d_rule_over'),
                tone: 'bad',
                title: tr('d_ins_over_t', [catName(e.key), money(over)]),
                body: tr('d_ins_over_b', [money(spentByCategory[e.key]?[12] ?? 0), money(e.value), money(fc)]),
                impactMinor: over,
                page: 1,
                filter: 'cat:${e.key}',
              ));
            }
          }
        case 'up':
        case 'down':
          for (final id in spentByCategory.keys) {
            final med = median3(id);
            if (med < 10000) continue;
            final fc = forecastOf(id, daysPassed: passed, daysInMonth: daysIn);
            final pct = ((fc - med) / med * 100).round();
            if (r.key == 'up' && pct >= lvl) {
              list.add(Insight(
                id: 'up:$id:$monthKey',
                rule: tr('d_rule_up', [lvl]),
                tone: 'bad',
                title: tr('d_ins_up_t', [catName(id), pct]),
                body: tr('d_ins_up_b', [money(fc), money(med)]),
                impactMinor: fc - med,
                page: 3,
              ));
            } else if (r.key == 'down' && -pct >= lvl && passed >= 7) {
              list.add(Insight(
                id: 'down:$id:$monthKey',
                rule: tr('d_rule_down', [lvl]),
                tone: 'good',
                title: tr('d_ins_down_t', [catName(id), -pct]),
                body: tr('d_ins_down_b', [money(med - fc)]),
                impactMinor: med - fc,
                page: 3,
              ));
            }
          }
        case 'review':
          final q = s.reviewQueue;
          if (q.length >= lvl && q.isNotEmpty) {
            final sum = q.fold<int>(0, (a, t) => a + (s.toBase(t) ?? 0));
            list.add(Insight(
              id: 'review:$monthKey:${q.length}',
              rule: tr('d_rule_review'),
              tone: 'info',
              title: tr('d_ins_review_t', [q.length]),
              body: tr('d_ins_review_b'),
              impactMinor: sum,
              page: 1,
              filter: 'review',
            ));
          }
        case 'fx':
          final monthAgo = DateTime(now.year, now.month - 1, now.day);
          for (final a in s.accounts) {
            if (a.currency == base) continue;
            final bal = s.balances[a.id];
            final then = s.rates.rate(a.currency, monthAgo), nowRate = s.rates.rate(a.currency, now);
            if (bal == null || bal <= 0 || then == null || nowRate == null || then == 0) continue;
            final valueNow = s.rates.toBase(bal, a.currency, now) ?? 0;
            final valueThen = s.rates.toBase(bal, a.currency, monthAgo) ?? valueNow;
            final pct = (valueNow - valueThen) / (valueThen == 0 ? 1 : valueThen) * 100;
            if (pct.abs() >= lvl) {
              list.add(Insight(
                id: 'fx:${a.currency}:$monthKey',
                rule: tr('d_rule_fx', [lvl]),
                tone: pct < 0 ? 'bad' : 'good',
                title: tr(pct < 0 ? 'd_ins_fx_down_t' : 'd_ins_fx_up_t', [a.currency, pct.abs().toStringAsFixed(1)]),
                body: tr('d_ins_fx_b', [s.accountName(a), money((valueNow - valueThen).abs())]),
                impactMinor: (valueNow - valueThen).abs(),
                page: 3,
              ));
            }
          }
        case 'big':
          final limit = m?.dailyLimit ?? 0;
          if (limit <= 0) break;
          final weekAhead = DateTime(now.year, now.month, now.day + 7);
          for (final rec in s.recurring) {
            if (rec.kind != TxnKind.expense || rec.next.isAfter(weekAhead)) continue;
            final v = s.toBaseAmount(rec.amountMinor, rec.currency, rec.next) ?? 0;
            if (v >= limit * lvl) {
              list.add(Insight(
                id: 'big:${rec.id}:${rec.next.millisecondsSinceEpoch}',
                rule: tr('d_rule_big', [lvl]),
                tone: 'info',
                title: tr('d_ins_big_t', [rec.name, formatMoney(rec.amountMinor, rec.currency)]),
                body: tr('d_ins_big_b', [DateFormat.MMMMd(intlLocale).format(rec.next)]),
                impactMinor: v,
                page: 4,
              ));
            }
          }
        case 'dup':
          final month = txns.where((t) => t.kind == TxnKind.expense && monthIndex(t.time) == 12).toList()
            ..sort((a, b) => a.time.compareTo(b.time));
          for (var i = 1; i < month.length; i++) {
            final a = month[i - 1], b = month[i];
            if (a.amountMinor == b.amountMinor &&
                a.merchant != null &&
                a.merchant == b.merchant &&
                b.time.difference(a.time).inMinutes <= lvl) {
              list.add(Insight(
                id: 'dup:${b.id}',
                rule: tr('d_rule_dup', [lvl]),
                tone: 'bad',
                title: tr('d_ins_dup_t', [a.merchant, formatMoney(a.amountMinor, a.currency)]),
                body: tr('d_ins_dup_b', [DateFormat.MMMMd(intlLocale).add_Hm().format(b.time)]),
                impactMinor: s.toBase(b) ?? 0,
                page: 1,
              ));
            }
          }
        case 'debt':
          for (final d in s.openDebts) {
            final age = now.difference(d.createdAt).inDays;
            if (age >= lvl) {
              list.add(Insight(
                id: 'debt:${d.id}',
                rule: tr('d_rule_debt', [lvl]),
                tone: 'info',
                title: tr('d_ins_debt_t', [d.person ?? tr('d_someone'), formatMoney(d.openMinor, d.currency)]),
                body: tr('d_ins_debt_b', [age]),
                impactMinor: s.toBaseAmount(d.openMinor, d.currency, now) ?? 0,
                page: 6,
              ));
            }
          }
      }
    }
    final shown = list.where((i) => !p.hiddenHints.contains(i.id)).toList()
      ..sort((a, b) => b.impactMinor.compareTo(a.impactMinor));
    return DeskData._(
      now: now,
      months: months,
      txns: txns,
      spentByMonth: spentByMonth,
      incomeByMonth: incomeByMonth,
      spentByCategory: spentByCategory,
      incomeByCategory: incomeByCategory,
      thisMonthDays: thisMonthDays,
      prevMonthDays: prevMonthDays,
      heat: heat,
      payees: payees,
      daysByCountry: daysByCountry,
      insights: shown,
    );
  }

  /// Transactions created by the regular-payments feature are not "spent by habit".
  static bool isRegular(Txn t) => t.source == Repository.recurringSource;
}
