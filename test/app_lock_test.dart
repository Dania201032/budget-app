import 'package:budget_app/security/app_lock.dart';
import 'package:budget_app/security/secure_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PIN: only a salted hash is kept; wrong PINs fail; lock after leaving', () async {
    final lock = AppLock(store: SecureStore.instance);
    await lock.load();
    expect(lock.enabled, isFalse);
    await lock.setPin('4821');
    final stored = (await SecureStore.instance.read('lock_pin'))!;
    expect(stored.contains('4821'), isFalse);
    expect(stored.split(':'), hasLength(3));

    final again = AppLock(store: SecureStore.instance);
    await again.load();
    expect(again.enabled && again.locked, isTrue, reason: 'locked at start');
    expect(again.pinLength, 4);
    expect(await again.checkPin('1234'), isFalse);
    expect(again.locked, isTrue);
    expect(await again.checkPin('4821'), isTrue);
    expect(again.locked, isFalse);

    // Away for less than "lock after" → stays open; with "right away" → locks.
    await again.setLockAfter(const Duration(minutes: 5));
    again.onPaused();
    again.onResumed();
    expect(again.locked, isFalse);
    await again.setLockAfter(Duration.zero);
    again.onPaused();
    again.onResumed();
    expect(again.locked, isTrue);

    await again.disable();
    expect(await SecureStore.instance.read('lock_pin'), isNull);
  });
}
