import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:sqflite_sqlcipher/sqflite.dart';

String dateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Exchange rates with an offline cache.
///
/// Source: fawazahmed0/exchange-api (free, no key, daily history, 300+ currencies), served from
/// jsDelivr with a Cloudflare mirror as fallback. Rates are "quote per 1 base".
/// A manual rate set by the user overrides downloaded rates for every date.
class RatesService {
  final Database db;
  final http.Client _client;
  RatesService(this.db, {http.Client? client}) : _client = client ?? http.Client();

  String _base = 'CNY';

  /// date -> quote -> rate
  final Map<String, Map<String, double>> _cache = {};
  Map<String, double> manual = {};
  final Set<String> _failed = {};

  String get base => _base;

  Future<void> load(String base) async {
    _base = base;
    _cache.clear();
    _failed.clear();
    // Rates downloaded for another base are re-based (rate_B(Q) = rate_A(Q) / rate_A(B)),
    // so switching the main currency works offline. Direct rows win over derived ones.
    final byDateBase = <String, Map<String, Map<String, double>>>{};
    for (final r in await db.query('rates')) {
      byDateBase
          .putIfAbsent(r['date'] as String, () => {})
          .putIfAbsent(r['base'] as String, () => {})[r['quote'] as String] = (r['rate'] as num).toDouble();
    }
    byDateBase.forEach((date, bases) {
      final out = <String, double>{};
      bases.forEach((otherBase, rates) {
        if (otherBase == base) return;
        final b = rates[base];
        if (b == null || b == 0) return;
        rates.forEach((q, r) => out[q] = r / b);
        out[otherBase] = 1 / b;
      });
      out.addAll(bases[base] ?? const {});
      out.remove(base);
      if (out.isNotEmpty) _cache[date] = out;
    });

    manual = {};
    for (final r in await db.query('manual_rates')) {
      final b = r['base'] as String, q = r['quote'] as String, rate = (r['rate'] as num).toDouble();
      if (b == base) {
        manual[q] = rate;
      } else if (q == base && rate != 0) {
        manual.putIfAbsent(b, () => 1 / rate);
      }
    }
  }

  bool isManual(String quote) => manual.containsKey(quote);

  /// Quote per 1 base for [date]: manual, exact day, else the nearest day we have.
  double? rate(String quote, DateTime date) {
    if (quote == _base) return 1;
    final m = manual[quote];
    if (m != null) return m;
    final key = dateKey(date);
    final exact = _cache[key]?[quote];
    if (exact != null) return exact;
    String? best;
    for (final k in _cache.keys) {
      if (!_cache[k]!.containsKey(quote)) continue;
      if (best == null) {
        best = k;
        continue;
      }
      final dBest = (DateTime.parse(best).difference(date)).inDays.abs();
      final dK = (DateTime.parse(k).difference(date)).inDays.abs();
      if (dK < dBest || (dK == dBest && k.compareTo(best) < 0)) best = k;
    }
    return best == null ? null : _cache[best]![quote];
  }

  /// Latest known rate (for showing "1 ¥ = 12,4 ₽" in settings).
  double? latest(String quote) => rate(quote, DateTime.now());

  /// Converts to base currency, or null when no rate is known yet.
  int? toBase(int amountMinor, String currency, DateTime date) {
    if (currency == _base) return amountMinor;
    final r = rate(currency, date);
    if (r == null || r == 0) return null;
    return (amountMinor / r).round();
  }

  /// [amountMinor] in [from] expressed in [to] (via the base currency), or null without a rate.
  int? convert(int amountMinor, String from, String to, DateTime at) {
    if (from == to) return amountMinor;
    final inBase = toBase(amountMinor, from, at);
    if (inBase == null) return null;
    final r = rate(to, at);
    return r == null ? null : (inBase * r).round();
  }

  /// Downloads missing rates for the given days (at most [maxRequests] requests per call;
  /// other days fall back to the nearest known rate).
  Future<void> ensure(Iterable<DateTime> days, Set<String> currencies, {int maxRequests = 12}) async {
    final needed = currencies.where((c) => c != _base && !manual.containsKey(c)).toSet();
    if (needed.isEmpty) return;
    final today = DateTime.now();
    final keys = <String>{};
    for (final d in days) {
      final recent = today.difference(d).inDays < 1;
      final key = recent ? 'latest' : dateKey(d);
      final have = recent ? _cache[dateKey(today)] ?? _cache[dateKey(today.subtract(const Duration(days: 1)))] : _cache[key];
      if (have != null && needed.every(have.containsKey)) continue;
      keys.add(key);
    }
    var requests = 0;
    for (final key in keys) {
      if (requests >= maxRequests) break;
      if (_failed.contains(key)) continue;
      requests++;
      await _fetch(key);
    }
  }

  Future<void> _fetch(String key) async {
    final b = _base.toLowerCase();
    final urls = [
      'https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@$key/v1/currencies/$b.json',
      'https://$key.currency-api.pages.dev/v1/currencies/$b.json',
    ];
    for (final url in urls) {
      try {
        final res = await _client.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
        if (res.statusCode != 200) continue;
        final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        final date = json['date'] as String;
        final rates = (json[b] as Map<String, dynamic>).map((k, v) => MapEntry(k.toUpperCase(), (v as num).toDouble()));
        await _store(date, rates);
        return;
      } catch (e) {
        debugPrint('Rates $url failed: $e');
      }
    }
    _failed.add(key);
  }

  Future<void> _store(String date, Map<String, double> rates) async {
    // Drop the source's long crypto/token codes; 3-letter codes (incl. a few like BTC) are kept.
    final filtered = {
      for (final e in rates.entries)
        if (RegExp(r'^[A-Z]{3}$').hasMatch(e.key)) e.key: e.value,
    };
    _cache[date] = filtered;
    final batch = db.batch();
    for (final e in filtered.entries) {
      batch.insert('rates', {'date': date, 'base': _base, 'quote': e.key, 'rate': e.value},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// [rate] = how many [quote] for 1 base; null removes the manual rate.
  Future<void> setManual(String quote, double? rate) async {
    // Drop the pair in both directions so an old inverse row can't come back on reload.
    await db.delete('manual_rates',
        where: '(base = ? AND quote = ?) OR (base = ? AND quote = ?)', whereArgs: [_base, quote, quote, _base]);
    if (rate == null) {
      manual.remove(quote);
    } else {
      manual[quote] = rate;
      await db.insert('manual_rates', {'base': _base, 'quote': quote, 'rate': rate},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }
}
