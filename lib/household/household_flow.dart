import 'dart:convert';
import 'dart:math';

import '../state/app_state.dart';
import '../sync/sync_crypto.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_folder.dart';
import '../sync/sync_service.dart';
import 'household.dart';

/// Setting up, joining and leaving a shared budget. The folder is always a new one: an old
/// phone ⇄ computer sync folder holds the whole history, which the other person could read.

/// The folder already holds a sync group: a new shared budget can't start there.
class FolderInUse implements Exception {
  const FolderInUse();
}

String newPersonUid() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// Starts a shared budget on this device. [owners]: account id -> owner ("me" or "partner" for
/// the two people created here, null for common); [hidden]: accounts the others won't see.
/// [personalPassword]: lets this person's other devices see the hidden ones.
Future<void> foundHousehold(
  AppState state, {
  required HouseholdConfig config,
  required String myName,
  String? partnerName,
  required Map<int, String?> owners,
  Set<int> hidden = const {},
  String? personalPassword,
  required SyncFolder folder,
  required String password,
  required String kind,
  required String location,
}) async {
  if (await SyncService.hasGroup(folder)) throw const FolderInUse();
  final repo = state.repo;
  if (state.sync.enabled) await state.disconnectSync();
  await repo.setHousehold(config);
  final me = await repo.addPerson(myName);
  final partner = partnerName == null || partnerName.trim().isEmpty ? null : await repo.addPerson(partnerName);
  for (final e in owners.entries) {
    final owner = switch (e.value) { 'me' => me, 'partner' => partner, _ => null };
    await repo.setAccountOwner(e.key, owner);
  }
  // Before the first sync: hidden rows are sealed from the very first file.
  for (final id in hidden) {
    await repo.setAccountHidden(id, true);
  }
  await repo.db.update('transactions', {'author': me}, where: 'author IS NULL');
  await state.sync.setPerson(me);
  await state.sync.setPersonCipher(
      personalPassword == null ? null : await SyncService.openPersonKey(folder, me, personalPassword));
  await state.connectSync(folder, password, kind: kind, location: location);
  await state.reloadHousehold();
}

/// What a shared budget's folder says before joining it.
class HouseholdInvite {
  final SyncCipher cipher;
  final Map<String, String> people;
  final HouseholdConfig? config;
  const HouseholdInvite(this.cipher, this.people, this.config);

  /// The folder holds an ordinary phone ⇄ computer sync, not a shared budget.
  bool get isPlainSync => config == null;
}

/// Opens a shared budget's folder with its password. Throws [WrongSyncPassword].
/// [sync]: told when the password is checked and how far the reading got (for the progress view).
Future<HouseholdInvite> readInvite(SyncFolder folder, String password, {SyncService? sync}) async {
  final cipher = await SyncEngine.openGroup(folder, password);
  sync?.passwordOk();
  final (people, setup) = await SyncEngine.peek(folder, cipher, onProgress: sync?.report);
  return HouseholdInvite(
    cipher,
    people,
    setup == null ? null : HouseholdConfig.fromJson(jsonDecode(setup) as Map<String, dynamic>),
  );
}

/// Joins a shared budget as [person] (one of its people: another device of theirs) or as a new
/// person named [newName]. [keepMine]: this device's own records join the budget (else they are
/// replaced by the budget's). [personalPassword]: opens (or, for a new person, creates) the
/// personal key that shows one's hidden accounts.
Future<void> joinHousehold(
  AppState state, {
  String? person,
  String? newName,
  required bool keepMine,
  String? personalPassword,
  required SyncFolder folder,
  required String password,
  required String kind,
  required String location,
}) async {
  assert(person != null || newName != null);
  final repo = state.repo;
  if (state.sync.enabled) await state.disconnectSync();
  final me = person ?? newPersonUid();
  final name = newName ?? '';
  final hasOwn = await repo.hasTransactions();
  final merge = keepMine && hasOwn;
  await state.sync.setPerson(me);
  await state.sync.setPersonCipher(
      personalPassword == null ? null : await SyncService.openPersonKey(folder, me, personalPassword));
  await state.connectSyncAs(
    folder,
    password,
    kind: kind,
    location: location,
    wipe: !keepMine,
    beforeTake: !merge
        ? null
        : () async {
            if (person == null) await repo.addPerson(name, uid: me);
            final myName = (await repo.people()).where((p) => p.uid == me).firstOrNull?.name ?? name;
            await repo.claimAsMine(me, myName);
          },
    beforeSend: !merge ? null : () async => repo.mergeSameNamedCategories(),
  );
  // A new person on a device that took the budget's data as it is.
  if (person == null && !(await repo.people()).any((p) => p.uid == me)) await repo.addPerson(name, uid: me);
  await state.reloadHousehold();
  await state.syncNow();
}

/// Leaves the shared budget on this device: sync stops, the data stays here as it is.
Future<void> leaveHousehold(AppState state) async {
  await state.disconnectSync();
  await state.repo.setHousehold(null);
  state.repo.me = null;
  await state.reloadHousehold();
}

