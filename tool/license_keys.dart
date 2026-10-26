// Personal keys to "Saldo Plus" (for friends, testers): signed with the developer's private key,
// checked by the app offline (lib/premium/license.dart). The private key never goes into the repo.
//
//   dart run tool/license_keys.dart generate              (once: makes the key pair)
//   dart run tool/license_keys.dart issue "Иван"          (forever)
//   dart run tool/license_keys.dart issue "Иван" 2027-06-30
//
// The private key file: BUDGET_LICENSE_KEY env, or D:\dev\keys\budget_license_ed25519.key.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

final _keyFile = File(Platform.environment['BUDGET_LICENSE_KEY'] ?? r'D:\dev\keys\budget_license_ed25519.key');

String _b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');

Future<void> main(List<String> args) async {
  final ed = Ed25519();
  if (args.isNotEmpty && args.first == 'generate') {
    if (_keyFile.existsSync()) {
      stderr.writeln('${_keyFile.path} exists: not overwriting it (keys issued with it would stop working).');
      exit(1);
    }
    final pair = await ed.newKeyPair();
    final seed = await pair.extractPrivateKeyBytes();
    final pub = await pair.extractPublicKey();
    _keyFile.writeAsStringSync(base64.encode(seed));
    stdout.writeln('Private key saved to ${_keyFile.path} — back it up, keep it secret.');
    stdout.writeln('Public key for lib/premium/license.dart: ${base64.encode(pub.bytes)}');
    return;
  }
  if (args.length < 2 || args.first != 'issue') {
    stderr.writeln('usage: generate | issue "Name" [yyyy-mm-dd]');
    exit(2);
  }
  final pair = await ed.newKeyPairFromSeed(base64.decode(_keyFile.readAsStringSync().trim()));
  final r = Random.secure();
  final payload = {
    'n': args[1],
    'i': List.generate(6, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join(),
    if (args.length > 2) 'u': args[2],
  };
  final body = utf8.encode(jsonEncode(payload));
  final sig = await ed.sign(body, keyPair: pair);
  final key = 'BP1.${_b64(body)}.${_b64(sig.bytes)}';
  // Who got which key: to withdraw one later, its id goes into _revoked in lib/premium/license.dart.
  File('${_keyFile.parent.path}${Platform.pathSeparator}issued_keys.tsv').writeAsStringSync(
      '${DateTime.now().toIso8601String().substring(0, 10)}\t${payload['n']}\t${payload['i']}\t${payload['u'] ?? 'forever'}\t$key\n',
      mode: FileMode.append);
  stdout.writeln(key);
}
