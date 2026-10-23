import 'package:budget_app/data/database.dart';
import 'package:budget_app/data/models.dart';
import 'package:budget_app/data/repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Database db;
  late Repository repo;

  setUp(() async {
    db = await openAppDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    repo = Repository(db);
  });
  tearDown(() => db.close());

  Recurring rent({DateTime? next, Every every = Every.month, int day = 31}) => Recurring(
      name: 'Аренда', amountMinor: 300000, currency: 'CNY', kind: TxnKind.expense, every: every, day: day,
      next: next ?? DateTime(2027, 1, 31));

  test('monthly on the 31st falls on the last day of shorter months and comes back', () {
    final r = rent();
    final dates = r.occurrences(DateTime(2027, 5, 31)).toList();
    expect(dates, [
      DateTime(2027, 1, 31), DateTime(2027, 2, 28), DateTime(2027, 3, 31), DateTime(2027, 4, 30), DateTime(2027, 5, 31),
    ]);
  });

  test('weekly and yearly', () {
    expect(rent(every: Every.week, next: DateTime(2026, 10, 20)).after(DateTime(2026, 10, 20)), DateTime(2026, 10, 27));
    expect(rent(every: Every.year, day: 29, next: DateTime(2028, 2, 29)).after(DateTime(2028, 2, 29)), DateTime(2029, 2, 28));
  });

  test('record adds the operation and moves on; skip only moves on', () async {
    final id = await repo.saveRecurring(rent(next: DateTime(2026, 10, 31)));
    var r = (await repo.recurring()).single;
    expect(r.id, id);
    await repo.recordRecurring(r, at: DateTime(2026, 10, 31, 9));
    final txns = await repo.txnsBetween(DateTime(2026), DateTime(2027));
    expect(txns.single.merchant, 'Аренда');
    expect(txns.single.source, Repository.recurringSource);
    r = (await repo.recurring()).single;
    expect(r.next, DateTime(2026, 11, 30));
    await repo.skipRecurring(r);
    expect((await repo.recurring()).single.next, DateTime(2026, 12, 31));
    expect(await repo.txnsBetween(DateTime(2026), DateTime(2027)), hasLength(1));
    await repo.deleteRecurring(id);
    expect(await repo.recurring(), isEmpty);
  });
}
