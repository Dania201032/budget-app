import 'dart:convert';
import 'dart:io';

import 'package:budget_app/data/database.dart';
import 'package:budget_app/data/repository.dart';
import 'package:budget_app/premium/license.dart';
import 'package:budget_app/premium/premium.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');

class _Store implements StoreBilling {
  bool active = false;
  @override
  Future<bool> hasActiveSubscription() async => active;
  @override
  Future<bool> buy() async => active = true;
}

/// Budget Plus: personal keys signed offline (as tool/license_keys.dart does), the trial, the store.
void main() {
  sqfliteFfiInit();
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late Repository repo;
  late SimpleKeyPair pair;
  late String pub;

  // Signs a key the way the developer's tool does, with this test's own key pair.
  Future<String> issue(Map<String, String> payload, {SimpleKeyPair? by}) async {
    final body = utf8.encode(jsonEncode(payload));
    final sig = await Ed25519().sign(body, keyPair: by ?? pair);
    return 'BP1.${_b64(body)}.${_b64(sig.bytes)}';
  }

  setUpAll(() async {
    pair = await Ed25519().newKeyPair();
    pub = base64.encode((await pair.extractPublicKey()).bytes);
  });

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('budget_plus_');
    repo = Repository(await openAppDatabase(factory: databaseFactoryFfi, path: '${tmp.path}/b.db'));
  });

  tearDown(() async {
    await Plus(repo, publicKey: pub).removeKey();
    await repo.db.close();
    tmp.deleteSync(recursive: true);
  });

  test('a key signed by the developer reads back with its name and end date', () async {
    final forever = await readLicense(await issue({'n': 'Иван', 'i': 'a1'}), publicKey: pub);
    expect(forever?.name, 'Иван');
    expect(forever?.until, isNull);
    expect(forever!.activeAt(DateTime(2099)), isTrue);

    final dated = await readLicense(await issue({'n': 'Маша', 'i': 'b2', 'u': '2027-06-30'}), publicKey: pub);
    expect(dated!.activeAt(DateTime(2027, 6, 30, 23, 59)), isTrue, reason: 'the last day counts');
    expect(dated.activeAt(DateTime(2027, 7, 1, 0, 1)), isFalse);
  });

  test('changed, foreign or broken keys are refused', () async {
    final good = await issue({'n': 'Иван', 'i': 'a1'});
    final parts = good.split('.');
    final forged = 'BP1.${_b64(utf8.encode(jsonEncode({'n': 'Иван', 'i': 'a1', 'u': '2099-01-01'})))}.${parts[2]}';
    expect(await readLicense(forged, publicKey: pub), isNull);
    final other = await Ed25519().newKeyPair();
    expect(await readLicense(await issue({'n': 'X', 'i': 'c3'}, by: other), publicKey: pub), isNull);
    expect(await readLicense('BP1.abc', publicKey: pub), isNull);
    expect(await readLicense('hello', publicKey: pub), isNull);
    // Keys signed by the test's pair don't open the real app.
    expect(await readLicense(good), isNull);
  });

  test('the trial runs 30 days from the first start, then Plus is off', () async {
    final plus = Plus(repo, publicKey: pub);
    final start = DateTime(2026, 10, 1);
    final first = await plus.status(now: start);
    expect(first.source, PlusSource.trial);
    expect(first.daysLeft(start), plusTrialDays);
    expect((await plus.status(now: start.add(const Duration(days: 29)))).source, PlusSource.trial);
    final after = await plus.status(now: start.add(const Duration(days: 31)));
    expect(after.source, PlusSource.none);
    expect(after.active, isFalse);
  });

  test('a personal key turns Plus on after the trial; removing it turns it off', () async {
    final plus = Plus(repo, publicKey: pub);
    await plus.status(now: DateTime(2020));
    expect((await plus.status()).source, PlusSource.none);

    expect(await plus.enterKey('nonsense'), isNull);
    expect(await plus.enterKey(await issue({'n': 'Old', 'i': 'd4', 'u': '2021-01-01'})), isNull, reason: 'expired');
    expect((await plus.status()).source, PlusSource.none);

    final l = await plus.enterKey('  ${await issue({'n': 'Иван', 'i': 'a1'})}\n');
    expect(l?.name, 'Иван');
    final s = await plus.status();
    expect(s.source, PlusSource.license);
    expect(s.licensee, 'Иван');

    await plus.removeKey();
    expect((await plus.status()).source, PlusSource.none);
  });

  test('a store subscription comes first', () async {
    final store = _Store();
    final plus = Plus(repo, store: store, publicKey: pub);
    await plus.status(now: DateTime(2020));
    expect((await plus.status()).active, isFalse);
    await store.buy();
    expect((await plus.status()).source, PlusSource.store);
  });

  test('in a shared budget one person\'s Plus keeps sync and the shared budget going for the other', () async {
    // Two devices: A has the subscription, B's trial is long over. The note travels by sync,
    // here copied by hand from A's settings to B's.
    final repoB = Repository(await openAppDatabase(factory: databaseFactoryFfi, path: '${tmp.path}/b2.db'));
    Future<void> carry(Repository from, Repository to) async =>
        to.setSetting(Plus.householdKey, (await from.setting(Plus.householdKey))!);
    final store = _Store()..active = true;
    final a = Plus(repo, store: store, publicKey: pub);
    final b = Plus(repoB, publicKey: pub);
    final day = DateTime(2026, 10, 25);
    await b.status(now: DateTime(2020));

    expect((await a.status(now: day, me: 'p:a')).source, PlusSource.store);
    await carry(repo, repoB);
    final viaA = await b.status(now: day, me: 'p:b');
    expect(viaA.source, PlusSource.household);
    expect(viaA.licensee, 'p:a');
    expect(viaA.allows(PlusFeature.sync), isTrue);
    expect(viaA.allows(PlusFeature.household), isTrue);
    expect(viaA.allows(PlusFeature.statements), isFalse);
    expect(viaA.allows(PlusFeature.receipts), isFalse);
    // Outside the shared budget it means nothing.
    expect((await b.status(now: day)).source, PlusSource.none);

    // The note is renewed only every few days, not on every look.
    final first = await repo.setting(Plus.householdKey);
    await a.status(now: day.add(const Duration(days: 2)), me: 'p:a');
    expect(await repo.setting(Plus.householdKey), first);
    await a.status(now: day.add(const Duration(days: 5)), me: 'p:a');
    expect(await repo.setting(Plus.householdKey), isNot(first));

    // Without renewal it runs out two weeks later.
    expect((await b.status(now: day.add(const Duration(days: 20)), me: 'p:b')).source, PlusSource.none);

    // A's subscription ends: A's next look withdraws the note at once.
    await carry(repo, repoB);
    store.active = false;
    await a.status(now: day.add(const Duration(days: 6)), me: 'p:a');
    await carry(repo, repoB);
    expect((await b.status(now: day.add(const Duration(days: 6)), me: 'p:b')).source, PlusSource.none);
    await repoB.db.close();
  });
}
