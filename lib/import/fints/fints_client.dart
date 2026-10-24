import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../bank_formats.dart';
import '../statement.dart';
import 'fints_message.dart';

/// The app's product registration number from the Deutsche Kreditwirtschaft (hbci-zka.de). German
/// banks reject FinTS clients without one. Empty until the registration comes through.
const fintsProductId = '';
const fintsProductVersion = '0.12';

/// FinTS 3.0 with PIN/TAN, the protocol German banks (Sparkassen, DKB, ING, Volksbanken,
/// Comdirect…) offer to programs like this one: the device talks to the bank directly, no third
/// party in between. Only reading: accounts (UPD) and account statements (HKKAZ → MT940).
///
/// PSD2 strong authentication: the bank asks for a TAN at login (every 90 days or so) and maybe
/// for the statement; "decoupled" methods (pushTAN in the bank's app) are confirmed there.
class FintsClient {
  FintsClient({
    required this.url,
    required this.blz,
    required this.userId,
    required this.pin,
    required this.ui,
    String? customerId,
    this.systemId = '0',
    this.securityFunction,
    this.tanMedium,
    http.Client? client,
    this.productId = fintsProductId,
  })  : customerId = customerId ?? userId,
        _http = client ?? http.Client();

  final String url;
  final String blz;
  final String userId;
  final String customerId;
  final String pin;
  final FintsUi ui;
  final String productId;
  final http.Client _http;

  /// Given by the bank on the first sync; kept between uses ([FintsLogin]).
  String systemId;

  /// The chosen TAN method ("921", "942"…), and the device it goes to, if the bank wants its name.
  String? securityFunction;
  String? tanMedium;

  /// Return codes and segment names of every exchange, for the developer (no PIN, no data).
  final log = <String>[];

  // From the bank's parameters (BPD) and the user's (UPD).
  final _tanMethods = <FintsTanMethod>[];
  final _allowedFunctions = <String>[];
  final _needsTan = <String, bool>{};
  int _hktanVersion = 6;
  int _hkkazVersion = 6;
  final accounts = <FintsAccount>[];

  String _dialogId = '0';
  int _messageNo = 1;

  bool get _oneStep => securityFunction == null || securityFunction == '999';

  // --- Messages ---

  String _date(DateTime d) => '${d.year}${_pad(d.month)}${_pad(d.day)}';
  String _time(DateTime d) => '${_pad(d.hour)}${_pad(d.minute)}${_pad(d.second)}';
  String _pad(int v) => v.toString().padLeft(2, '0');

  /// Wraps business segments (numbered from 3) into a signed, "encrypted" PIN/TAN message.
  String _message(List<String Function(int number)> segments, {String? tan}) {
    final now = DateTime.now();
    final func = securityFunction ?? '999';
    final profile = _oneStep ? ['PIN', '1'] : ['PIN', '2'];
    final ref = '${Random().nextInt(900000000) + 100000000}';
    final kik = ['280', fintsEscape(blz), fintsEscape(userId)];
    final inner = StringBuffer();
    inner.write(fintsSegment('HNSHK', 2, 4, [
      profile, func, ref, '1', '1', ['1', '', fintsEscape(systemId)], '1', ['1', _date(now), _time(now)], ['1', '999', '1'],
      ['6', '10', '16'], [...kik, 'S', '0', '0'],
    ]));
    var n = 3;
    for (final s in segments) {
      inner.write(s(n++));
    }
    inner.write(fintsSegment('HNSHA', n, 2, [ref, '', [fintsEscape(pin), if (tan != null) fintsEscape(tan)]]));
    final last = n + 1;
    final body = StringBuffer()
      ..write(fintsSegment('HNVSK', 998, 3, [
        profile, '998', '1', ['1', '', fintsEscape(systemId)], ['1', _date(now), _time(now)],
        ['2', '2', '13', fintsBinary('00000000'), '5', '1'], [...kik, 'V', '0', '0'], '0',
      ]))
      ..write(fintsSegment('HNVSD', 999, 1, [fintsBinary(inner.toString())]))
      ..write(fintsSegment('HNHBS', last, 1, ['$_messageNo']));
    String header(int length) =>
        fintsSegment('HNHBK', 1, 3, [length.toString().padLeft(12, '0'), '300', fintsEscape(_dialogId), '$_messageNo']);
    final size = header(0).length + body.length;
    return header(size) + body.toString();
  }

  Future<List<FintsSegment>> _send(List<String Function(int)> segments, {String? tan, String what = ''}) async {
    final msg = _message(segments, tan: tan);
    final res = await _http.post(
      Uri.parse(url),
      headers: {'Content-Type': 'text/plain; charset=ISO-8859-1'},
      body: base64Encode(latin1Bytes(msg)),
    );
    if (res.statusCode != 200) throw FintsError('HTTP ${res.statusCode}', log);
    final text = latin1Text(base64Decode(utf8.decode(res.bodyBytes).replaceAll(RegExp(r'\s'), '')));
    final answer = parseFints(text);
    _messageNo++;
    final head = answer.where((s) => s.name == 'HNHBK').firstOrNull;
    if (head != null && head.at(2).isNotEmpty) _dialogId = head.at(2);
    final codes = fintsReturns(answer);
    log.add('$what → ${answer.map((s) => s.name).toSet().join(' ')} | ${codes.join(' | ')}');
    _learn(answer);
    final errors = codes.where((c) => c.isError).toList();
    if (errors.isNotEmpty) {
      if (errors.any((e) => e.code == '9931' || e.code == '9942' || e.code == '9340')) throw FintsPinWrong(errors.join('; '), log);
      throw FintsError(errors.map((e) => e.toString()).join('; '), log);
    }
    return answer;
  }

  // --- What the answers teach ---

  void _learn(List<FintsSegment> answer) {
    for (final s in answer) {
      switch (s.name) {
        case 'HISYN':
          if (s.at(0).isNotEmpty) systemId = s.at(0);
        case 'HITANS':
          if (s.version >= 6 && s.version <= 7 && s.version > (_tanSeen ?? 0)) _tanSeen = s.version;
          _readTanParameters(s);
        case 'HIKAZS':
          if (s.version >= 5 && s.version <= 7 && s.version > (_kazSeen ?? 0)) _kazSeen = s.version;
        case 'HIPINS':
          // Pairs "segment:J|N" after five leading items: J = needs a TAN.
          final p = s.elements.elementAtOrNull(3) ?? const [];
          for (var i = 5; i + 1 < p.length; i += 2) {
            _needsTan[p[i]] = p[i + 1] == 'J';
          }
        case 'HIUPD':
          final acc = FintsAccount.fromUpd(s, blz);
          if (acc != null && !accounts.any((a) => a.number == acc.number && a.iban == acc.iban)) accounts.add(acc);
      }
    }
    for (final r in fintsReturns(answer).where((r) => r.code == '3920')) {
      _allowedFunctions
        ..clear()
        ..addAll(r.params.where((p) => p.isNotEmpty));
    }
    if (_kazSeen != null) _hkkazVersion = _kazSeen!;
    if (_tanSeen != null) _hktanVersion = _tanSeen!;
  }

  int? _kazSeen;
  int? _tanSeen;

  void _readTanParameters(FintsSegment s) {
    // HITANS v6/v7: element 3 holds 3 items, then 21 (v6) or 26 (v7) per method.
    final p = s.elements.elementAtOrNull(3) ?? const [];
    final per = s.version >= 7 ? 26 : 21;
    // The last method's trailing empty items may be left out.
    String item(int i) => i < p.length ? p[i] : '';
    for (var i = 3; i < p.length; i += per) {
      final code = item(i);
      if (code.isEmpty || _tanMethods.any((m) => m.code == code)) continue;
      _tanMethods.add(FintsTanMethod(
        code: code,
        name: item(i + 5),
        needsMediumName: item(i + 18) == '2',
        decoupled: s.version >= 7 && (item(i + 3).toLowerCase().contains('decoupled') || item(i + 21).isNotEmpty),
      ));
    }
  }

  // --- Segments ---

  String Function(int) _hkidn() => (n) => fintsSegment('HKIDN', n, 2, [['280', fintsEscape(blz)], fintsEscape(customerId), fintsEscape(systemId), '1']);
  String Function(int) _hkvvb() => (n) => fintsSegment('HKVVB', n, 3, ['0', '0', '0', fintsEscape(productId), fintsEscape(fintsProductVersion)]);
  String Function(int) _hksyn() => (n) => fintsSegment('HKSYN', n, 3, ['0']);
  String Function(int) _hkend() => (n) => fintsSegment('HKEND', n, 1, [fintsEscape(_dialogId)]);

  /// HKTAN process 4: "the segment before me needs strong authentication if the bank wants it".
  String Function(int) _hktan4(String segment) => (n) => fintsSegment('HKTAN', n, _hktanVersion, [
        '4', segment, '', '', '', '', '', '', '', '', tanMedium == null ? '' : fintsEscape(tanMedium!),
      ]);

  /// HKTAN process 2 (here is the TAN) or S (decoupled: has it been confirmed?).
  String Function(int) _hktanAnswer(String process, String taskReference) =>
      (n) => fintsSegment('HKTAN', n, _hktanVersion, [process, '', '', '', fintsEscape(taskReference), 'N']);

  String Function(int) _hkkaz(FintsAccount a, DateTime from, DateTime to, String? touchdown) => (n) {
        final ktv = [fintsEscape(a.number), fintsEscape(a.subAccount), '280', fintsEscape(a.blz)];
        final account = _hkkazVersion >= 7 ? [fintsEscape(a.iban ?? ''), fintsEscape(a.bic ?? ''), ...ktv] : ktv;
        return fintsSegment('HKKAZ', n, _hkkazVersion, [account, 'N', _date(from), _date(to), '', touchdown == null ? '' : fintsEscape(touchdown)]);
      };

  // --- Dialogs ---

  /// Returns the answer once any TAN the bank asked for has been given.
  Future<List<FintsSegment>> _withTan(List<FintsSegment> answer, String what) async {
    var current = answer;
    for (var round = 0; round < 30; round++) {
      final codes = fintsReturns(current);
      final hitan = current.where((s) => s.name == 'HITAN').firstOrNull;
      final needsTan = codes.any((c) => c.code == '0030') && hitan != null;
      final pending = codes.any((c) => c.code == '3956');
      if (!needsTan && !pending) return current;
      final reference = hitan?.at(2) ?? _lastTaskReference;
      if (reference == null || reference.isEmpty) return current;
      _lastTaskReference = reference;
      final decoupled = codes.any((c) => c.code == '3955') || pending || (_method?.decoupled ?? false);
      final challenge = FintsChallenge(
        text: _cleanChallenge(hitan?.at(3) ?? ''),
        decoupled: decoupled,
        image: _challengeImage(hitan?.at(4) ?? ''),
        stillWaiting: pending,
      );
      final tan = await ui.askTan(challenge);
      if (tan == null) throw const FintsCancelled();
      current = decoupled
          ? await _send([_hktanAnswer('S', reference)], what: '$what: decoupled check')
          : await _send([_hktanAnswer('2', reference)], tan: tan, what: '$what: TAN');
    }
    throw FintsError('TAN: too many attempts', log);
  }

  String? _lastTaskReference;

  FintsTanMethod? get _method => _tanMethods.where((m) => m.code == securityFunction).firstOrNull;

  Future<void> _endDialog() async {
    if (_dialogId == '0') return;
    try {
      await _send([_hkend()], what: 'end');
    } catch (_) {
      // The bank may have ended it already.
    }
    _dialogId = '0';
    _messageNo = 1;
  }

  /// Logs in: a sync dialog (system id, TAN methods, accounts), then the real dialog.
  Future<void> open() async {
    if (productId.isEmpty) throw const FintsNotRegistered();
    if (systemId == '0' || securityFunction == null) {
      final saved = securityFunction;
      securityFunction = null; // the first dialog is one-step ("999")
      _dialogId = '0';
      _messageNo = 1;
      try {
        await _send([_hkidn(), _hkvvb(), _hktan4('HKIDN'), _hksyn()], what: 'sync');
      } on FintsPinWrong {
        rethrow;
      } on FintsError {
        // Some banks refuse HKTAN in a one-step dialog: once more without it.
        _dialogId = '0';
        _messageNo = 1;
        await _send([_hkidn(), _hkvvb(), _hksyn()], what: 'sync without HKTAN');
      }
      await _endDialog();
      securityFunction = saved != null && _allowedFunctions.contains(saved) ? saved : null;
      if (securityFunction == null) {
        final offered = _tanMethods.where((m) => _allowedFunctions.isEmpty || _allowedFunctions.contains(m.code)).toList();
        if (offered.isEmpty) {
          securityFunction = _allowedFunctions.firstOrNull ?? '999';
        } else if (offered.length == 1) {
          securityFunction = offered.single.code;
        } else {
          securityFunction = await ui.chooseTanMethod(offered);
          if (securityFunction == null) throw const FintsCancelled();
        }
      }
      if ((_method?.needsMediumName ?? false) && tanMedium == null) {
        tanMedium = await ui.askTanMedium();
        if (tanMedium == null) throw const FintsCancelled();
      }
    }
    _dialogId = '0';
    _messageNo = 1;
    final init = await _send([_hkidn(), _hkvvb(), _hktan4('HKIDN')], what: 'init');
    await _withTan(init, 'init');
  }

  /// The account statement of [account] from [from] to today (booked operations; MT940).
  Future<Statement> statement(FintsAccount account, DateTime from) async {
    final mt940 = StringBuffer();
    String? touchdown;
    var page = 0;
    do {
      final needsTan = _needsTan['HKKAZ'] ?? true;
      var answer = await _send([
        _hkkaz(account, from, DateTime.now(), touchdown),
        if (needsTan && !_oneStep) _hktan4('HKKAZ'),
      ], what: 'HKKAZ $page');
      answer = await _withTan(answer, 'HKKAZ');
      for (final s in answer.where((s) => s.name == 'HIKAZ')) {
        // Pages end with "-": the next one starts on a line of its own.
        mt940.writeln(s.at(0));
      }
      touchdown = fintsReturns(answer).where((r) => r.code == '3040').firstOrNull?.params.firstOrNull;
      page++;
    } while (touchdown != null && page < 50);
    final s = readMt940(mt940.toString());
    return Statement(format: 'fints', app: null, accountRef: account.iban ?? account.number, rows: s.rows);
  }

  Future<void> close() => _endDialog();

  static String _cleanChallenge(String s) => s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n').replaceAll(RegExp(r'<[^>]+>'), '');

  /// photoTAN and QR-TAN put a picture in the challenge: 2 bytes length + MIME type, 2 bytes
  /// length + image.
  static Uint8List? _challengeImage(String hhduc) {
    if (hhduc.length < 4) return null;
    final b = latin1Bytes(hhduc);
    final mimeLen = (b[0] << 8) | b[1];
    if (mimeLen <= 0 || 2 + mimeLen + 2 > b.length) return null;
    final mime = latin1Text(b.sublist(2, 2 + mimeLen));
    if (!mime.startsWith('image/')) return null;
    final at = 2 + mimeLen;
    final imgLen = (b[at] << 8) | b[at + 1];
    if (at + 2 + imgLen > b.length) return null;
    return Uint8List.fromList(b.sublist(at + 2, at + 2 + imgLen));
  }
}

class FintsTanMethod {
  final String code;
  final String name;
  final bool needsMediumName;
  final bool decoupled;
  const FintsTanMethod({required this.code, required this.name, this.needsMediumName = false, this.decoupled = false});
}

class FintsChallenge {
  final String text;
  final bool decoupled;
  final Uint8List? image;

  /// The bank has not seen the confirmation yet (asked again after "done").
  final bool stillWaiting;
  const FintsChallenge({required this.text, required this.decoupled, this.image, this.stillWaiting = false});
}

/// An account from the user parameters (HIUPD).
class FintsAccount {
  final String number;
  final String subAccount;
  final String blz;
  final String? iban;
  final String? bic;
  final String currency;
  final String name;
  const FintsAccount({
    required this.number,
    this.subAccount = '',
    required this.blz,
    this.iban,
    this.bic,
    this.currency = 'EUR',
    this.name = '',
  });

  /// HIUPD v6: KTV, IBAN, customer, type, currency, holder 1, holder 2, product name…
  static FintsAccount? fromUpd(FintsSegment s, String blz) {
    final ktv = s.elements.elementAtOrNull(0) ?? const [];
    final number = ktv.elementAtOrNull(0) ?? '';
    final iban = s.at(1);
    if (number.isEmpty && iban.isEmpty) return null;
    final product = s.at(7);
    return FintsAccount(
      number: number,
      subAccount: ktv.elementAtOrNull(1) ?? '',
      blz: (ktv.elementAtOrNull(3) ?? '').isEmpty ? blz : ktv[3],
      iban: iban.isEmpty ? null : iban,
      currency: s.at(4).isEmpty ? 'EUR' : s.at(4),
      name: product.isNotEmpty ? product : s.at(5),
    );
  }
}

/// What the screens supply: choices and TANs.
abstract class FintsUi {
  Future<String?> chooseTanMethod(List<FintsTanMethod> methods);
  Future<String?> askTanMedium();

  /// The TAN typed by the user; for a decoupled method, any non-null value once they confirmed
  /// in the bank's app. Null cancels.
  Future<String?> askTan(FintsChallenge challenge);
}

class FintsError implements Exception {
  final String message;
  final List<String> log;
  const FintsError(this.message, [this.log = const []]);
  @override
  String toString() => message;
}

class FintsPinWrong extends FintsError {
  const FintsPinWrong(super.message, [super.log]);
}

class FintsNotRegistered implements Exception {
  const FintsNotRegistered();
}

class FintsCancelled implements Exception {
  const FintsCancelled();
}
