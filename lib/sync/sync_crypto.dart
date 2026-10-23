import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Sync files are encrypted with a key made from the sync password, the same on every device:
/// PBKDF2-HMAC-SHA256 with the folder's salt, then AES-256-GCM per file. The cloud only ever
/// sees ciphertext; without the password the files are unreadable.
class SyncCipher {
  static const _magic = [0x42, 0x44, 0x53, 0x31]; // "BDS1"
  static const iterations = 120000;

  final SecretKey _key;
  SyncCipher._(this._key);

  static Uint8List newSalt() {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(16, (_) => r.nextInt(256)));
  }

  /// Seconds of hashing on a phone: done in a background isolate so the screen doesn't freeze.
  static Future<SyncCipher> fromPassword(String password, List<int> salt, {int rounds = iterations}) async {
    final saltCopy = List<int>.of(salt);
    final bytes = await Isolate.run(() async {
      final pbkdf2 = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: rounds, bits: 256);
      final key = await pbkdf2.deriveKeyFromPassword(password: password, nonce: saltCopy);
      return key.extractBytes();
    });
    return SyncCipher._(SecretKey(bytes));
  }

  /// The derived key, to keep in the device's secure storage instead of the password.
  Future<String> exportKey() async => base64Encode(await _key.extractBytes());

  static SyncCipher fromKey(String b64) => SyncCipher._(SecretKey(base64Decode(b64)));

  static final _aes = AesGcm.with256bits();

  /// gzip + AES-GCM: magic, nonce (12), ciphertext, tag (16).
  Future<Uint8List> seal(List<int> plain) async {
    final box = await _aes.encrypt(gzip.encode(plain), secretKey: _key);
    return Uint8List.fromList([..._magic, ...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  /// Null when the file isn't ours or the key is wrong.
  Future<Uint8List?> open(List<int> data) async {
    if (data.length < 4 + 12 + 16) return null;
    for (var i = 0; i < 4; i++) {
      if (data[i] != _magic[i]) return null;
    }
    final box = SecretBox(
      data.sublist(16, data.length - 16),
      nonce: data.sublist(4, 16),
      mac: Mac(data.sublist(data.length - 16)),
    );
    try {
      return Uint8List.fromList(gzip.decode(await _aes.decrypt(box, secretKey: _key)));
    } on SecretBoxAuthenticationError {
      return null;
    }
  }
}
