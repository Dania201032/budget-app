import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import 'secure_store.dart';

/// Optional lock of the app: a PIN (only its PBKDF2 hash is kept, in the Keystore/Keychain) and,
/// if the phone has one, the fingerprint or face. Locks at start and after being away for
/// [lockAfter].
class AppLock extends ChangeNotifier {
  AppLock({SecureStore? store, LocalAuthentication? auth})
      : _store = store ?? SecureStore.instance,
        _auth = auth ?? LocalAuthentication();

  final SecureStore _store;
  final LocalAuthentication _auth;

  static const _keyPin = 'lock_pin';
  static const _keyBio = 'lock_bio';
  static const _keyAfter = 'lock_after';
  static const iterations = 30000;

  bool enabled = false;
  bool biometrics = false;

  /// How long the app may stay in the background before it locks again.
  Duration lockAfter = Duration.zero;

  bool locked = false;

  /// Digits in the PIN (4–6), so the lock screen knows when it's complete.
  int pinLength = 4;
  DateTime? _leftAt;

  Future<void> load() async {
    final stored = await _store.read(_keyPin);
    enabled = stored != null;
    pinLength = int.tryParse(stored?.split(':').elementAtOrNull(2) ?? '') ?? 4;
    biometrics = enabled && await _store.read(_keyBio) == '1';
    lockAfter = Duration(seconds: int.tryParse(await _store.read(_keyAfter) ?? '') ?? 0);
    locked = enabled;
    notifyListeners();
  }

  // --- PIN ---

  static String _hash(String pin, Uint8List salt) {
    // PBKDF2-HMAC-SHA256: guessing all 6-digit PINs takes a while even with the hash in hand.
    var block = Hmac(sha256, utf8.encode(pin)).convert([...salt, 0, 0, 0, 1]).bytes;
    final out = List<int>.from(block);
    final mac = Hmac(sha256, utf8.encode(pin));
    for (var i = 1; i < iterations; i++) {
      block = mac.convert(block).bytes;
      for (var j = 0; j < out.length; j++) {
        out[j] ^= block[j];
      }
    }
    return base64Encode(out);
  }

  Future<void> setPin(String pin) async {
    final salt = Uint8List.fromList(List.generate(16, (_) => Random.secure().nextInt(256)));
    await _store.write(_keyPin, '${base64Encode(salt)}:${_hash(pin, salt)}:${pin.length}');
    pinLength = pin.length;
    enabled = true;
    locked = false;
    notifyListeners();
  }

  Future<bool> checkPin(String pin) async {
    final stored = await _store.read(_keyPin);
    if (stored == null) return true;
    final parts = stored.split(':');
    final ok = parts.length >= 2 && _hash(pin, base64Decode(parts[0])) == parts[1];
    if (ok) {
      locked = false;
      notifyListeners();
    }
    return ok;
  }

  Future<void> disable() async {
    await _store.write(_keyPin, null);
    await _store.write(_keyBio, null);
    enabled = biometrics = locked = false;
    notifyListeners();
  }

  // --- Fingerprint / face ---

  Future<bool> biometricsAvailable() async {
    try {
      return await _auth.isDeviceSupported() && (await _auth.getAvailableBiometrics()).isNotEmpty;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> setBiometrics(bool on) async {
    await _store.write(_keyBio, on ? '1' : null);
    biometrics = on;
    notifyListeners();
  }

  Future<void> setLockAfter(Duration d) async {
    await _store.write(_keyAfter, '${d.inSeconds}');
    lockAfter = d;
    notifyListeners();
  }

  /// The system's fingerprint / face prompt; true when it unlocked.
  Future<bool> unlockWithBiometrics(String reason) async {
    if (!biometrics) return false;
    try {
      final ok = await _auth.authenticate(localizedReason: reason, biometricOnly: true);
      if (ok) {
        locked = false;
        notifyListeners();
      }
      return ok;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    } on LocalAuthException {
      return false;
    }
  }

  // --- Leaving and coming back ---

  void onPaused() => _leftAt ??= DateTime.now();

  /// Leaving the app for a system screen it opened itself (the folder or file picker) is not
  /// leaving it: no lock on coming back.
  Future<T> whileInSystemScreen<T>(Future<T> Function() open) async {
    _inSystemScreen++;
    try {
      return await open();
    } finally {
      _inSystemScreen--;
      _leftAt = null;
    }
  }

  int _inSystemScreen = 0;

  void onResumed() {
    final left = _leftAt;
    _leftAt = null;
    if (_inSystemScreen > 0) return;
    if (enabled && left != null && DateTime.now().difference(left) >= lockAfter) {
      locked = true;
      notifyListeners();
    }
  }
}
