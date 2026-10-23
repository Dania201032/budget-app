import 'dart:convert';

import 'package:budget_app/data/database.dart';
import 'package:budget_app/data/rates.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Database db;
  final requested = <String>[];

  // Fake rates source: 1 CNY = 12.5 RUB = 0.14 USD on every date; mirrors the real JSON shape.
  final client = MockClient((req) async {
    requested.add(req.url.toString());
    final m = RegExp(r'currency-api@([^/]+)/v1/currencies/(\w+)\.json').firstMatch(req.url.toString());
    if (m == null) return http.Response('not found', 404);
    final date = m.group(1) == 'latest' ? '2026-10-12' : m.group(1)!;
    final base = m.group(2)!;
    final rates = base == 'cny'
        ? {'rub': 12.5, 'usd': 0.14, 'cny': 1, 'btc': 0.000001}
        : {'cny': 0.08, 'usd': 0.0112, 'rub': 1};
    return http.Response(jsonEncode({'date': date, base: rates}), 200, headers: {'content-type': 'application/json'});
  });

  setUp(() async {
    requested.clear();
    db = await openAppDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
  });
  tearDown(() => db.close());

  test('downloads, caches and converts by date', () async {
    final r = RatesService(db, client: client);
    await r.load('CNY');
    expect(r.toBase(125000, 'RUB', DateTime(2026, 10, 1)), isNull);

    await r.ensure([DateTime(2026, 10, 1)], {'RUB'});
    expect(requested.single, contains('@2026-10-01/'));
    expect(r.toBase(125000, 'RUB', DateTime(2026, 10, 1)), 10000); // 1250 ₽ = 100 ¥
    expect(r.toBase(500, 'CNY', DateTime(2026, 10, 1)), 500);

    // Nearest known date is used when the exact one is missing.
    expect(r.rate('RUB', DateTime(2026, 10, 5)), 12.5);

    // Cached in the DB: a fresh service needs no network.
    final again = RatesService(db, client: MockClient((_) async => throw Exception('offline')));
    await again.load('CNY');
    expect(again.rate('RUB', DateTime(2026, 10, 1)), 12.5);
  });

  test('manual rate overrides downloaded ones and survives a base change', () async {
    final r = RatesService(db, client: client);
    await r.load('CNY');
    await r.ensure([DateTime(2026, 10, 1)], {'RUB'});
    await r.setManual('RUB', 11.5);
    expect(r.toBase(115000, 'RUB', DateTime(2026, 10, 1)), 10000);

    await r.load('RUB');
    expect(r.rate('CNY', DateTime(2026, 10, 1)), closeTo(1 / 11.5, 1e-9));

    await r.setManual('CNY', null);
    // Back to the downloaded CNY-based rate, re-based to RUB: 1 RUB = 1/12.5 CNY.
    expect(r.rate('CNY', DateTime(2026, 10, 1)), closeTo(0.08, 1e-9));
    expect(r.rate('USD', DateTime(2026, 10, 1)), closeTo(0.14 / 12.5, 1e-9));
  });

  test('falls back to the mirror and remembers failures', () async {
    var jsdelivrCalls = 0;
    final flaky = MockClient((req) async {
      if (req.url.host == 'cdn.jsdelivr.net') {
        jsdelivrCalls++;
        return http.Response('blocked', 503);
      }
      if (req.url.host == '2026-10-02.currency-api.pages.dev') {
        return http.Response(jsonEncode({'date': '2026-10-02', 'cny': {'rub': 12.0}}), 200);
      }
      return http.Response('nope', 404);
    });
    final r = RatesService(db, client: flaky);
    await r.load('CNY');
    await r.ensure([DateTime(2026, 10, 2), DateTime(2026, 10, 3)], {'RUB'});
    expect(r.rate('RUB', DateTime(2026, 10, 2)), 12.0);
    final calls = jsdelivrCalls;
    await r.ensure([DateTime(2026, 10, 3)], {'RUB'});
    expect(jsdelivrCalls, calls, reason: 'failed day is not retried in the same session');
  });
}
