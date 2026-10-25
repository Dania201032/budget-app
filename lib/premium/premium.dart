import 'dart:convert';

import '../data/repository.dart';
import '../security/secure_store.dart';
import 'license.dart';

/// Budget Plus: what the subscription adds. Free stays a complete budget for one person on one
/// phone; Plus is more devices, more people, more analysis. Nothing is ever locked away: when
/// Plus ends, everything made with it stays visible, only its actions stop (sync pauses).
enum PlusFeature { sync, household, statements, envelopes, netWorth, taxes, receipts }

/// Days of Plus everyone gets from the first start.
const plusTrialDays = 30;

/// Where Plus comes from. [household]: another person of the shared budget has Plus, which
/// keeps the shared budget (and its sync) going for everyone in it; the rest stays theirs.
enum PlusSource { none, trial, license, store, household }

/// The store's subscription (Google Play, RuStore): the build for each store provides its own.
/// Without one (this build, the computer) only the trial and personal keys count.
abstract class StoreBilling {
  /// Whether the store reports an active subscription, asked on the device (no server).
  Future<bool> hasActiveSubscription();

  /// Starts buying the subscription; false when the store can't (not installed from it).
  Future<bool> buy();
}

class NoStoreBilling implements StoreBilling {
  const NoStoreBilling();
  @override
  Future<bool> hasActiveSubscription() async => false;
  @override
  Future<bool> buy() async => false;
}

class PlusStatus {
  final PlusSource source;
  final DateTime? until;

  /// The personal key's name ("for Ivan"); for [PlusSource.household] the person whose Plus it is.
  final String? licensee;
  const PlusStatus(this.source, {this.until, this.licensee});

  bool get active => source != PlusSource.none;

  /// Through a partner's Plus only the shared budget itself works: its sync and its setup.
  bool allows(PlusFeature f) => switch (source) {
        PlusSource.none => false,
        PlusSource.household => f == PlusFeature.sync || f == PlusFeature.household,
        _ => true,
      };

  int daysLeft(DateTime now) => until == null ? 0 : until!.difference(now).inDays.clamp(0, 9999);
}

/// Works out the status: a store subscription, else a personal key, else the trial, else a
/// partner's Plus. The key lives in secure storage; the trial's start in the settings (this
/// device only). A person with Plus in a shared budget leaves a note in the shared settings
/// ([householdKey], renewed every few days while they open the app), which the others read.
class Plus {
  Plus(this.repo, {StoreBilling? store, this.publicKey}) : store = store ?? const NoStoreBilling();
  final Repository repo;
  final StoreBilling store;

  /// Tests sign with their own key; the app checks against the developer's.
  final String? publicKey;

  static const _licenseKey = 'plus_license';

  /// Synced setting: {"by": person uid, "until": ISO time}.
  static const householdKey = 'household_plus';

  /// How long the note keeps the shared budget going after its last renewal.
  static const householdWindow = Duration(days: 14);

  Future<PlusLicense?> _read(String key) => publicKey == null ? readLicense(key) : readLicense(key, publicKey: publicKey!);

  /// [me]: this device's person in a shared budget (null: none).
  Future<PlusStatus> status({DateTime? now, String? me}) async {
    final at = now ?? DateTime.now();
    final own = await _own(at);
    if (me != null) {
      final note = await _note();
      if (own.source == PlusSource.store || own.source == PlusSource.license) {
        // Renewed when less than 10 days are left: one small change every few days. When two
        // people have Plus, whichever note is there serves both (no rewriting each other's).
        var until = at.add(householdWindow);
        if (own.until != null && own.until!.isBefore(until)) until = own.until!;
        if (note == null || note.$2.isBefore(until.subtract(const Duration(days: 4)))) await _writeNote(me, until);
      } else if (note != null && note.$1 == me && note.$2.isAfter(at)) {
        // My Plus ended (key removed, subscription over): the others stop counting on it.
        await _writeNote(me, at);
      }
      if (!own.active && note != null && note.$1 != me && note.$2.isAfter(at)) {
        return PlusStatus(PlusSource.household, until: note.$2, licensee: note.$1);
      }
    }
    return own;
  }

  Future<PlusStatus> _own(DateTime at) async {
    if (await store.hasActiveSubscription()) return const PlusStatus(PlusSource.store);
    final key = await SecureStore.instance.read(_licenseKey);
    if (key != null) {
      final l = await _read(key);
      if (l != null && l.activeAt(at)) return PlusStatus(PlusSource.license, until: l.until, licensee: l.name);
    }
    var start = DateTime.tryParse(await repo.setting('plus_trial_start') ?? '');
    if (start == null) {
      start = at;
      await repo.setSetting('plus_trial_start', at.toIso8601String());
    }
    final end = start.add(const Duration(days: plusTrialDays));
    return at.isBefore(end) ? PlusStatus(PlusSource.trial, until: end) : const PlusStatus(PlusSource.none);
  }

  Future<(String, DateTime)?> _note() async {
    try {
      final j = jsonDecode(await repo.setting(householdKey) ?? '') as Map<String, dynamic>;
      final until = DateTime.tryParse(j['until'] as String? ?? '');
      final by = j['by'] as String?;
      return by == null || until == null ? null : (by, until);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeNote(String me, DateTime until) =>
      repo.setSetting(householdKey, jsonEncode({'by': me, 'until': until.toUtc().toIso8601String()}));

  /// Takes a personal key; the license when it is valid, else null (nothing saved).
  Future<PlusLicense?> enterKey(String key) async {
    final l = await _read(key);
    if (l == null || !l.activeAt(DateTime.now())) return null;
    await SecureStore.instance.write(_licenseKey, key.trim());
    return l;
  }

  Future<void> removeKey() => SecureStore.instance.write(_licenseKey, null);
}
