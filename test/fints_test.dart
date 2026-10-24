import 'dart:convert';

import 'package:budget_app/data/models.dart';
import 'package:budget_app/import/fints/fints_client.dart';
import 'package:budget_app/import/fints/fints_message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A German bank played by a fake FinTS server: sync dialog, login with a decoupled TAN (confirmed
/// in the bank's app), an account statement in two pages. Names and numbers are made up.

class _Ui implements FintsUi {
  final asked = <FintsChallenge>[];
  List<FintsTanMethod>? offered;
  @override
  Future<String?> chooseTanMethod(List<FintsTanMethod> methods) async {
    offered = methods;
    return methods.firstWhere((m) => m.decoupled).code;
  }

  @override
  Future<String?> askTanMedium() async => 'Mein Handy';

  @override
  Future<String?> askTan(FintsChallenge c) async {
    asked.add(c);
    return c.decoupled ? '' : '123456';
  }
}

/// HITANS v7 parameters of one method (26 items).
List<String> _method(String code, String name, {bool decoupled = false}) => [
      code, '2', decoupled ? 'Decoupled' : 'HHD1.4', decoupled ? 'Decoupled' : 'HHD', '1.4', name, '6', '1', 'TAN', '3',
      'N', '2', 'N', '0', '0', 'N', 'J', '00', '2', 'N', '1', decoupled ? '60' : '', decoupled ? '5' : '', decoupled ? '2' : '',
      decoupled ? 'J' : '', decoupled ? 'J' : '',
    ];

const _mt940a = ':20:STARTUMS\r\n:25:12030000/1234567890\r\n:60F:C260901EUR100,00\r\n'
    ':61:2609150915DR12,50NDDTNONREF\r\n:86:106?00KARTENZAHLUNG?20SVWZ+Brot?32Baeckerei Beispiel\r\n-';
const _mt940b = ':20:STARTUMS\r\n:25:12030000/1234567890\r\n:60F:C260916EUR87,50\r\n'
    ':61:2609200920CR1000,00NTRFNONREF\r\n:86:166?00GUTSCHRIFT?20SVWZ+Lohn?32Firma Beispiel GmbH\r\n-';

void main() {
  test('messages: escaping, binary data, envelope unpacked when parsing', () {
    expect(fintsEscape("a+b:c'd?e@f"), "a?+b?:c?'d??e?@f");
    final inner = "${fintsSegment('HIRMS', 3, 2, [['0010', '', 'Nachricht ?+ OK']], reference: 1)}"
        "${fintsSegment('HIKAZ', 4, 6, [fintsBinary("x'y+z")], reference: 3)}";
    final msg = "${fintsSegment('HNHBK', 1, 3, ['000000000000', '300', 'D1', '1'])}"
        "${fintsSegment('HNVSD', 999, 1, [fintsBinary(inner)])}";
    final segs = parseFints(msg);
    expect(segs.map((s) => s.name), ['HNHBK', 'HIRMS', 'HIKAZ']);
    expect(segs[1].reference, 1);
    expect(fintsReturns(segs).single.text, 'Nachricht + OK');
    expect(segs[2].at(0), "x'y+z");
  });

  test('sync, login with a decoupled TAN, statement in two pages', () async {
    final steps = <String>[];
    var initDone = false;
    var polls = 0;
    final client = MockClient((req) async {
      final text = latin1Text(base64Decode(req.body));
      final segs = parseFints(text);
      final names = segs.map((s) => s.name).toList();
      steps.add(names.where((n) => n.startsWith('HK')).join(','));
      // The length in the header is the message's length.
      expect(int.parse(segs.first.at(0)), text.length);
      final sha = segs.firstWhere((s) => s.name == 'HNSHA');
      expect(sha.elements[2].first, 'geheim');
      final hnshk = segs.firstWhere((s) => s.name == 'HNSHK');
      String answer(List<String> body) =>
          "${fintsSegment('HNHBK', 1, 3, ['000000000000', '300', 'DIALOG1', '1'])}${body.join()}${fintsSegment('HNHBS', 99, 1, ['1'])}";
      http.Response ok(List<String> body) => http.Response(base64Encode(latin1Bytes(answer(body))), 200);

      if (names.contains('HKSYN')) {
        expect(hnshk.at(1), '999');
        expect(segs.firstWhere((s) => s.name == 'HKVVB').at(3), 'TESTPRODUCT');
        return ok([
          fintsSegment('HIRMG', 2, 2, [['0010', '', 'Nachricht entgegengenommen.']]),
          fintsSegment('HIRMS', 3, 2, [['3920', '', 'Zugelassene Verfahren', '921', '942']], reference: 4),
          fintsSegment('HISYN', 4, 4, ['SYS-42'], reference: 6),
          fintsSegment('HITANS', 5, 7, ['1', '1', '0', ['J', 'N', '0', ..._method('921', 'pushTAN', decoupled: true), ..._method('942', 'mobile TAN')]], reference: 4),
          fintsSegment('HIPINS', 6, 1, ['1', '1', '0', ['5', '20', '6', 'Benutzer', 'Kunde', 'HKKAZ', 'N', 'HKSAL', 'N']], reference: 4),
          fintsSegment('HIKAZS', 7, 6, ['1', '1', '0', ['360', 'J', 'N']], reference: 4),
          fintsSegment('HIUPD', 8, 6, [['1234567890', '', '280', '12030000'], 'DE00120300001234567890', 'kunde', '1', 'EUR', 'Alex Beispiel', '', 'Girokonto']),
        ]);
      }
      if (names.contains('HKEND')) return ok([fintsSegment('HIRMG', 2, 2, [['0100', '', 'Dialog beendet.']])]);
      if (names.contains('HKIDN')) {
        expect(hnshk.at(1), '921');
        expect(segs.firstWhere((s) => s.name == 'HKIDN').at(2), 'SYS-42');
        expect(segs.firstWhere((s) => s.name == 'HKTAN').version, 7);
        return ok([
          fintsSegment('HIRMG', 2, 2, [['3060', '', 'Bitte beachten Sie die Hinweise.']]),
          fintsSegment('HIRMS', 3, 2, [['0030', '', 'Auftrag empfangen - Sicherheitsfreigabe erforderlich'], ['3955', '', 'Sicherheitsfreigabe erfolgt über anderen Kanal']], reference: 5),
          fintsSegment('HITAN', 4, 7, ['4', '', 'TASK-1', fintsEscape('Bitte bestätigen Sie in der App.')], reference: 5),
        ]);
      }
      if (names.contains('HKTAN') && !names.contains('HKKAZ')) {
        final tan = segs.firstWhere((s) => s.name == 'HKTAN');
        expect(tan.at(0), 'S');
        expect(tan.at(4), 'TASK-1');
        polls++;
        if (polls == 1) return ok([fintsSegment('HIRMS', 3, 2, [['3956', '', 'Starke Kundenauthentifizierung noch ausstehend.']], reference: 3)]);
        initDone = true;
        return ok([fintsSegment('HIRMS', 3, 2, [['0020', '', 'Der Auftrag wurde ausgeführt.']], reference: 3)]);
      }
      if (names.contains('HKKAZ')) {
        expect(initDone, isTrue);
        final kaz = segs.firstWhere((s) => s.name == 'HKKAZ');
        expect(kaz.elements[0].first, '1234567890');
        // HIPINS said HKKAZ needs no TAN.
        expect(names.contains('HKTAN'), isFalse);
        final second = kaz.at(5) == 'NEXT';
        return ok([
          if (!second) fintsSegment('HIRMS', 3, 2, [['3040', '', 'Es liegen weitere Informationen vor.', 'NEXT']], reference: 3),
          fintsSegment('HIKAZ', 4, 6, [fintsBinary(second ? _mt940b : _mt940a)], reference: 3),
        ]);
      }
      return http.Response('?', 500);
    });

    final ui = _Ui();
    final fints = FintsClient(
      url: 'https://fints.example.test/fints30',
      blz: '12030000',
      userId: 'alex',
      pin: 'geheim',
      ui: ui,
      client: client,
      productId: 'TESTPRODUCT',
    );
    await fints.open();
    expect(fints.systemId, 'SYS-42');
    expect(fints.securityFunction, '921');
    expect(ui.offered!.map((m) => m.code), ['921', '942']);
    expect(ui.asked.map((c) => c.stillWaiting), [false, true]);
    expect(ui.asked.first.text, 'Bitte bestätigen Sie in der App.');
    expect(fints.accounts.single.iban, 'DE00120300001234567890');

    final s = await fints.statement(fints.accounts.single, DateTime(2026, 9, 1));
    await fints.close();
    expect(s.rows, hasLength(2));
    expect(s.rows[0].kind, TxnKind.expense);
    expect(s.rows[0].payee, 'Baeckerei Beispiel');
    expect(s.rows[1].amountMinor, 100000);
    expect(steps.last, 'HKEND');
  });

  test('no product registration: refuses before contacting the bank', () async {
    final fints = FintsClient(
      url: 'https://fints.example.test',
      blz: '1',
      userId: 'u',
      pin: 'p',
      ui: _Ui(),
      productId: '',
      client: MockClient((_) async => fail('must not be called')),
    );
    await expectLater(fints.open(), throwsA(isA<FintsNotRegistered>()));
  });
}
