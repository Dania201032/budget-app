import 'dart:convert';
import 'dart:typed_data';

import 'package:budget_app/data/models.dart';
import 'package:budget_app/import/bunq.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointycastle/export.dart';

/// bunq's API played by a fake server that checks what a real one checks: the signature of each
/// POST body against the registered key, and the tokens.
void main() {
  // A small key: generating 2048 bits in a test takes long and proves nothing more.
  final key = generateRsaKey(1024);

  bool verify(RSAPublicKey pub, String body, String signature) {
    final v = RSASigner(SHA256Digest(), '0609608648016503040201')..init(false, PublicKeyParameter<RSAPublicKey>(pub));
    return v.verifySignature(Uint8List.fromList(utf8.encode(body)), RSASignature(base64Decode(signature)));
  }

  test('public key PEM is valid X.509 that holds the key', () {
    final pem = rsaPublicPem(key);
    expect(pem, startsWith('-----BEGIN PUBLIC KEY-----\n'));
    final der = base64Decode(pem.split('\n').where((l) => !l.startsWith('-----')).join());
    // SEQUENCE { SEQUENCE { rsaEncryption OID, NULL }, BIT STRING }
    expect(der[0], 0x30);
    expect(utf8.decode(der, allowMalformed: true), isNotEmpty);
    final hex = key.modulus!.toRadixString(16);
    final derHex = der.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    expect(derHex, contains(hex.length.isOdd ? '0$hex' : hex));
    expect(derHex, contains('2a864886f70d010101'));
  });

  test('payment rows: sign gives the direction, times are UTC', () {
    final row = bunqPaymentRow({
      'id': 77,
      'created': '2026-09-20 10:15:00.000000',
      'amount': {'value': '-12.34', 'currency': 'EUR'},
      'description': 'Lunch',
      'type': 'MASTERCARD',
      'counterparty_alias': {'display_name': 'Cafe Voorbeeld', 'iban': null},
    })!;
    expect(row.kind, TxnKind.expense);
    expect(row.amountMinor, 1234);
    expect(row.payee, 'Cafe Voorbeeld');
    expect(row.id, '77');
    expect(row.time, DateTime.utc(2026, 9, 20, 10, 15).toLocal());
  });

  test('registers, opens a session, lists accounts and pages through payments', () async {
    RSAPublicKey? registered;
    final seen = <String>[];
    var sessions = 0;
    final client = MockClient((req) async {
      seen.add('${req.method} ${req.url.path}${req.url.query.isEmpty ? '' : '?${req.url.query}'}');
      expect(req.url.host, 'public-api.sandbox.bunq.com');
      if (req.method == 'POST' && req.url.path != '/v1/installation') {
        expect(verify(registered!, req.body, req.headers['X-Bunq-Client-Signature']!), isTrue, reason: req.url.path);
      }
      http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
      switch (req.url.path) {
        case '/v1/installation':
          final pem = (jsonDecode(req.body) as Map)['client_public_key'] as String;
          expect(pem, contains('BEGIN PUBLIC KEY'));
          registered = RSAPublicKey(key.modulus!, key.publicExponent!);
          return ok({
            'Response': [
              {'Id': {'id': 1}},
              {'Token': {'token': 'inst-token'}},
              {'ServerPublicKey': {'server_public_key': '-----BEGIN PUBLIC KEY-----'}},
            ]
          });
        case '/v1/device-server':
          expect(req.headers['X-Bunq-Client-Authentication'], 'inst-token');
          expect((jsonDecode(req.body) as Map)['secret'], 'sandbox_abc');
          return ok({'Response': [{'Id': {'id': 2}}]});
        case '/v1/session-server':
          sessions++;
          return ok({
            'Response': [
              {'Id': {'id': 3}},
              {'Token': {'token': 'session-$sessions'}},
              {'UserPerson': {'id': 42}},
            ]
          });
        case '/v1/user/42/monetary-account':
          expect(req.headers['X-Bunq-Client-Authentication'], 'session-$sessions');
          return ok({
            'Response': [
              {
                'MonetaryAccountBank': {
                  'id': 9,
                  'description': 'Main',
                  'currency': 'EUR',
                  'status': 'ACTIVE',
                  'alias': [{'type': 'IBAN', 'value': 'NL00BUNQ0000000000'}],
                }
              },
              {'MonetaryAccountSavings': {'id': 10, 'description': 'Old', 'currency': 'EUR', 'status': 'CANCELLED'}},
            ]
          });
        case '/v1/user/42/monetary-account/9/payment':
          if (sessions == 1) return http.Response('{"Error":[{"error_description":"Insufficient authorisation."}]}', 401);
          final older = req.url.queryParameters['older_id'] != null;
          Map<String, Object> p(int id, String created, String value) => {
                'Payment': {
                  'id': id,
                  'created': created,
                  'amount': {'value': value, 'currency': 'EUR'},
                  'description': 'p$id',
                  'counterparty_alias': {'display_name': 'Shop $id'},
                }
              };
          return ok({
            'Response': older
                ? [p(3, '2026-08-01 09:00:00.000000', '-1.00')]
                : [p(1, '2026-09-21 09:00:00.000000', '-5.00'), p(2, '2026-09-10 09:00:00.000000', '20.00')],
            'Pagination': {'older_url': older ? null : '/v1/user/42/monetary-account/9/payment?count=200&older_id=2'},
          });
      }
      return http.Response('not found', 404);
    });

    final state = BunqState('sandbox_abc')..privateKey = key;
    final bunq = BunqClient(state, client: client);
    final accounts = await bunq.accounts();
    expect(accounts.map((a) => a.iban), ['NL00BUNQ0000000000']);
    final s = await bunq.payments(accounts.single, DateTime(2026, 9, 1));
    expect(s.rows.map((r) => r.id), ['1', '2']);
    expect(s.rows.first.kind, TxnKind.expense);
    expect(s.rows[1].kind, TxnKind.income);
    expect(s.accountRef, 'NL00BUNQ0000000000');
    // The expired session was renewed once, and the device was registered once.
    expect(sessions, 2);
    expect(seen.where((s) => s.contains('installation')), hasLength(1));

    // Saved and loaded again, the state needs no new registration.
    final again = BunqState.fromJson(jsonDecode(jsonEncode(state.toJson())) as Map<String, dynamic>);
    expect(again.installationToken, 'inst-token');
    expect(again.privateKey!.modulus, key.modulus);
  });
}
