import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';

import '../data/models.dart';
import 'statement.dart';

/// bunq's public API, called straight from the device with the user's own API key (bunq app →
/// Profile → Security & Settings → Developers → API keys). Read-only use: accounts and payments.
///
/// The protocol: this device registers an RSA key ("installation"), the API key is bound to it
/// ("device-server"), then a session token is opened; POST bodies are signed with the key.
/// Keys starting with "sandbox_" go to bunq's sandbox.
class BunqClient {
  BunqClient(this.state, {http.Client? client}) : _http = client ?? http.Client();

  /// Everything needed to talk to bunq again without registering anew; kept in secure storage.
  final BunqState state;
  final http.Client _http;

  String get _base => state.apiKey.startsWith('sandbox_') ? 'https://public-api.sandbox.bunq.com/v1' : 'https://api.bunq.com/v1';

  Map<String, String> _headers({String? token, String? body}) => {
        'Cache-Control': 'no-cache',
        'User-Agent': 'Saldo',
        'X-Bunq-Language': 'en_US',
        'X-Bunq-Region': 'nl_NL',
        'X-Bunq-Geolocation': '0 0 0 0 000',
        'X-Bunq-Client-Request-Id': '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 30)}',
        'Content-Type': 'application/json',
        'X-Bunq-Client-Authentication': ?token,
        if (body != null && state.privateKey != null) 'X-Bunq-Client-Signature': base64Encode(rsaSign(state.privateKey!, utf8.encode(body))),
      };

  Future<List<Map<String, dynamic>>> _call(String method, String path, {String? token, Object? json}) async {
    final body = json == null ? null : jsonEncode(json);
    final uri = Uri.parse(path.startsWith('http') ? path : '$_base$path');
    final res = method == 'POST'
        ? await _http.post(uri, headers: _headers(token: token, body: body), body: body)
        : await _http.get(uri, headers: _headers(token: token));
    final decoded = res.body.isEmpty ? <String, dynamic>{} : jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 401) throw const BunqAuthError();
    if (res.statusCode >= 400) {
      final err = (decoded['Error'] as List?)?.map((e) => (e as Map)['error_description']).join('; ');
      throw BunqError(res.statusCode, err ?? res.reasonPhrase ?? '');
    }
    _lastPagination = decoded['Pagination'] as Map<String, dynamic>?;
    return [for (final e in (decoded['Response'] as List? ?? const [])) e as Map<String, dynamic>];
  }

  Map<String, dynamic>? _lastPagination;

  static T? _find<T>(List<Map<String, dynamic>> items, String key) =>
      items.map((e) => e[key]).whereType<Object>().cast<T?>().firstOrNull;

  /// Registers this device with bunq (once per API key) and opens a session.
  Future<void> connect() async {
    if (state.privateKey == null) {
      state.privateKey = await Isolate.run(() => generateRsaKey());
      state.installationToken = null;
    }
    if (state.installationToken == null) {
      final r = await _call('POST', '/installation', json: {'client_public_key': rsaPublicPem(state.privateKey!)});
      state.installationToken = (_find<Map<String, dynamic>>(r, 'Token'))?['token'] as String?;
      await _call('POST', '/device-server', token: state.installationToken, json: {
        'description': 'Saldo',
        'secret': state.apiKey,
        'permitted_ips': ['*'],
      });
    }
    final r = await _call('POST', '/session-server', token: state.installationToken, json: {'secret': state.apiKey});
    state.sessionToken = (_find<Map<String, dynamic>>(r, 'Token'))?['token'] as String?;
    final user = _find<Map<String, dynamic>>(r, 'UserPerson') ??
        _find<Map<String, dynamic>>(r, 'UserCompany') ??
        _find<Map<String, dynamic>>(r, 'UserApiKey');
    state.userId = user?['id'] as int?;
  }

  Future<List<Map<String, dynamic>>> _authed(String path) async {
    if (state.sessionToken == null || state.userId == null) await connect();
    try {
      return await _call('GET', path.replaceAll('{user}', '${state.userId}'), token: state.sessionToken);
    } on BunqAuthError {
      // The session expired (a week without use): open a new one.
      await connect();
      return _call('GET', path.replaceAll('{user}', '${state.userId}'), token: state.sessionToken);
    }
  }

  /// The user's active accounts: id, name, currency, IBAN.
  Future<List<BunqAccount>> accounts() async {
    final r = await _authed('/user/{user}/monetary-account');
    final out = <BunqAccount>[];
    for (final item in r) {
      for (final v in item.values.whereType<Map<String, dynamic>>()) {
        if (v['status'] != null && v['status'] != 'ACTIVE') continue;
        final iban = (v['alias'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .where((a) => a['type'] == 'IBAN')
            .map((a) => a['value'] as String?)
            .firstOrNull;
        out.add(BunqAccount(v['id'] as int, v['description'] as String? ?? 'bunq', v['currency'] as String? ?? 'EUR', iban));
      }
    }
    return out;
  }

  /// Payments of [account] made since [since], newest pages first.
  Future<Statement> payments(BunqAccount account, DateTime since) async {
    final rows = <StatementRow>[];
    String? next = '/user/{user}/monetary-account/${account.id}/payment?count=200';
    while (next != null) {
      final r = await _authed(next);
      var older = false;
      for (final item in r) {
        final p = item['Payment'] as Map<String, dynamic>?;
        if (p == null) continue;
        final row = bunqPaymentRow(p);
        if (row == null) continue;
        if (row.time.isBefore(since)) {
          older = true;
          continue;
        }
        rows.add(row);
      }
      final olderUrl = _lastPagination?['older_url'] as String?;
      next = older || olderUrl == null ? null : olderUrl.replaceFirst('/v1', '');
    }
    return Statement(format: 'bunq', app: 'bunq', accountRef: account.iban, rows: rows);
  }
}

class BunqAccount {
  final int id;
  final String name;
  final String currency;
  final String? iban;
  const BunqAccount(this.id, this.name, this.currency, this.iban);
}

class BunqError implements Exception {
  final int status;
  final String message;
  const BunqError(this.status, this.message);
  @override
  String toString() => 'bunq $status: $message';
}

class BunqAuthError implements Exception {
  const BunqAuthError();
}

/// A payment object of the API as a statement row; times are UTC ("2026-09-20 12:34:56.123456").
StatementRow? bunqPaymentRow(Map<String, dynamic> p) {
  final amount = p['amount'] as Map<String, dynamic>?;
  final currency = amount?['currency'] as String? ?? 'EUR';
  final value = parseAmount(amount?['value'] as String?, digits: minorDigits(currency));
  final created = DateTime.tryParse('${(p['created'] as String?)?.replaceFirst(' ', 'T')}Z');
  if (value == null || value == 0 || created == null) return null;
  final other = p['counterparty_alias'] as Map<String, dynamic>?;
  final description = (p['description'] as String?)?.trim();
  return StatementRow(
    time: created.toLocal(),
    kind: value < 0 ? TxnKind.expense : TxnKind.income,
    amountMinor: value.abs(),
    currency: currency,
    payee: (other?['display_name'] as String?)?.trim(),
    details: description == null || description.isEmpty ? null : description,
    category: p['type'] as String?,
    id: '${p['id']}',
  );
}

/// What's kept between uses: the API key, this device's key and the tokens bunq gave it.
class BunqState {
  String apiKey;
  RSAPrivateKey? privateKey;
  String? installationToken;
  String? sessionToken;
  int? userId;

  BunqState(this.apiKey);

  Map<String, Object?> toJson() => {
        'apiKey': apiKey,
        if (privateKey != null)
          'key': {
            'n': privateKey!.modulus!.toString(),
            'd': privateKey!.privateExponent!.toString(),
            'p': privateKey!.p!.toString(),
            'q': privateKey!.q!.toString(),
          },
        'installation': installationToken,
        'session': sessionToken,
        'user': userId,
      };

  factory BunqState.fromJson(Map<String, dynamic> j) {
    final s = BunqState(j['apiKey'] as String);
    final k = j['key'] as Map<String, dynamic>?;
    if (k != null) {
      s.privateKey = RSAPrivateKey(
          BigInt.parse(k['n'] as String), BigInt.parse(k['d'] as String), BigInt.parse(k['p'] as String), BigInt.parse(k['q'] as String));
    }
    s.installationToken = j['installation'] as String?;
    s.sessionToken = j['session'] as String?;
    s.userId = j['user'] as int?;
    return s;
  }
}

// --- RSA, as bunq wants it: 2048-bit keys, SHA256withRSA signatures, the public key as PEM ---

RSAPrivateKey generateRsaKey([int bits = 2048]) {
  final random = FortunaRandom()..seed(KeyParameter(Uint8List.fromList(List.generate(32, (_) => Random.secure().nextInt(256)))));
  final gen = RSAKeyGenerator()..init(ParametersWithRandom(RSAKeyGeneratorParameters(BigInt.from(65537), bits, 64), random));
  return gen.generateKeyPair().privateKey;
}

Uint8List rsaSign(RSAPrivateKey key, List<int> data) {
  final signer = RSASigner(SHA256Digest(), '0609608648016503040201')..init(true, PrivateKeyParameter<RSAPrivateKey>(key));
  return signer.generateSignature(Uint8List.fromList(data)).bytes;
}

/// The public half of [key] as an X.509 SubjectPublicKeyInfo PEM ("-----BEGIN PUBLIC KEY-----").
String rsaPublicPem(RSAPrivateKey key) {
  final e = key.publicExponent ?? BigInt.from(65537);
  final rsaKey = _der(0x30, [..._derInt(key.modulus!), ..._derInt(e)]);
  final algorithm = _der(0x30, [
    ..._der(0x06, const [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]), // rsaEncryption
    0x05, 0x00,
  ]);
  final info = _der(0x30, [...algorithm, ..._der(0x03, [0x00, ...rsaKey])]);
  final b64 = base64Encode(info);
  final lines = [for (var i = 0; i < b64.length; i += 64) b64.substring(i, min(i + 64, b64.length))];
  return '-----BEGIN PUBLIC KEY-----\n${lines.join('\n')}\n-----END PUBLIC KEY-----\n';
}

List<int> _der(int tag, List<int> content) {
  final n = content.length;
  final len = n < 0x80
      ? [n]
      : n < 0x100
          ? [0x81, n]
          : n < 0x10000
              ? [0x82, n >> 8, n & 0xFF]
              : [0x83, n >> 16, (n >> 8) & 0xFF, n & 0xFF];
  return [tag, ...len, ...content];
}

List<int> _derInt(BigInt v) {
  var hex = v.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  final bytes = [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
  if (bytes.first & 0x80 != 0) bytes.insert(0, 0);
  return _der(0x02, bytes);
}
