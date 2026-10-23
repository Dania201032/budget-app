import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Small secrets kept by the phone's secure hardware (Android Keystore, iOS Keychain, this device
/// only): the database key and the app lock's PIN hash. Never in the database, never in backups.
/// Tests (no platform) get an in-memory map.
class SecureStore {
  SecureStore._();
  static final instance = SecureStore._();

  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );
  final Map<String, String> _memory = {};
  bool _noPlatform = false;

  Future<String?> read(String key) async {
    if (_noPlatform) return _memory[key];
    try {
      return await _storage.read(key: key);
    } on MissingPluginException {
      _noPlatform = true;
      return _memory[key];
    }
  }

  Future<void> write(String key, String? value) async {
    if (!_noPlatform) {
      try {
        if (value == null) {
          await _storage.delete(key: key);
        } else {
          await _storage.write(key: key, value: value);
        }
        return;
      } on MissingPluginException {
        _noPlatform = true;
      }
    }
    if (value == null) {
      _memory.remove(key);
    } else {
      _memory[key] = value;
    }
  }
}
