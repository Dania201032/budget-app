import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// A personal key to Budget Plus (`BP1.<payload>.<signature>`): who it is for and until when,
/// signed by the developer (tool/license_keys.dart). Checked offline against [_publicKey].
class PlusLicense {
  final String name;
  final String id;

  /// Null: forever.
  final DateTime? until;
  const PlusLicense(this.name, this.id, this.until);

  bool activeAt(DateTime now) => until == null || !now.isAfter(until!);
}

const _publicKey = 'bRKejG+Nbsr5Qc/B6rzsb30lJq4VZQny4iFxSWKFYN4=';

/// Keys withdrawn after they were handed out (by their id).
const _revoked = <String>{};

List<int> _unb64(String s) => base64Url.decode(s + '=' * ((4 - s.length % 4) % 4));

/// The license in [key], or null when it isn't a valid one.
Future<PlusLicense?> readLicense(String key, {String publicKey = _publicKey}) async {
  final parts = key.trim().split('.');
  if (parts.length != 3 || parts[0] != 'BP1') return null;
  try {
    final body = _unb64(parts[1]);
    final ok = await Ed25519().verify(
      body,
      signature: Signature(_unb64(parts[2]), publicKey: SimplePublicKey(base64.decode(publicKey), type: KeyPairType.ed25519)),
    );
    if (!ok) return null;
    final j = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
    final id = j['i'] as String? ?? '';
    if (_revoked.contains(id)) return null;
    final u = j['u'] as String?;
    return PlusLicense(j['n'] as String? ?? '', id, u == null ? null : DateTime.tryParse(u)?.add(const Duration(days: 1)));
  } catch (_) {
    return null;
  }
}
