import 'dart:io';

import 'package:budget_app/data/database.dart';
import 'package:budget_app/data/repository.dart';
import 'package:budget_app/l10n/strings.dart';
import 'package:budget_app/sync/sync_engine.dart';
import 'package:budget_app/sync/sync_service.dart';
import 'package:budget_app/ui/ledger.dart';
import 'package:budget_app/ui/sync_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Connecting sync shows each step as it goes: the password, the folder, sending, receiving.
void main() {
  sqfliteFfiInit();

  testWidgets('the steps of connecting, then what came of it', (tester) async {
    currentLanguage = 'ru';
    late SyncService sync;
    await tester.runAsync(() async {
      final db = await openAppDatabase(
          factory: databaseFactoryFfi, path: '${Directory.systemTemp.path}/syncprog_${DateTime.now().microsecondsSinceEpoch}.db');
      sync = SyncService(Repository(db));
    });
    await tester.pumpWidget(MaterialApp(
      theme: ledgerTheme(Brightness.light),
      home: Scaffold(body: SyncProgressView(sync)),
    ));

    sync.beginConnect();
    await tester.pump();
    expect(find.text(tr('syp_password_check')), findsOneWidget);
    expect(find.text(tr('syp_ok')), findsOneWidget, reason: 'says at once that all was done right');

    sync.passwordOk();
    sync.report(const SyncProgress(SyncStage.look, 3, 40));
    await tester.pump();
    expect(find.text(tr('syp_password')), findsOneWidget);
    expect(find.text(tr('syp_look', [3, 40])), findsOneWidget);

    sync.report(const SyncProgress(SyncStage.send, 1, 2));
    await tester.pump();
    expect(find.text(tr('syp_look_done')), findsOneWidget);
    expect(find.text(tr('syp_send', [1, 2])), findsOneWidget);

    sync.report(const SyncProgress(SyncStage.receive, 5, 9, changes: 120));
    await tester.pump();
    expect(find.text(tr('syp_send_done')), findsOneWidget);
    expect(find.textContaining(tr('syp_changes', [120])), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    sync.endConnect();
    await tester.pump();

    // The result: the first device, the cloud still downloading, or done.
    final ctx = tester.element(find.byType(SyncProgressView));
    for (final (r, key) in [
      (const SyncReport(0, 12, alone: true), 'syr_alone'),
      (const SyncReport(30, 0, pending: 4), 'syr_pending'),
      (const SyncReport(30, 2), 'syr_done'),
    ]) {
      showSyncResult(ctx, r);
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining(tr(key, [r.received, key == 'syr_pending' ? r.pending : r.sent]).substring(0, 20)), findsOneWidget);
      await tester.tap(find.text(tr('ok')));
      await tester.pump(const Duration(seconds: 1));
    }
  });
}
