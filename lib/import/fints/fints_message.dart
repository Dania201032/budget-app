import 'dart:convert';

/// FinTS 3.0 messages as text: segments end with "'", data elements are separated by "+", their
/// group items by ":"; "?" escapes those characters, "@n@" starts n bytes of binary data. Text is
/// ISO-8859-1, and over HTTPS each message travels base64-encoded.

String fintsEscape(String s) => s.replaceAllMapped(RegExp(r"[?'+:@]"), (m) => '?${m[0]}');

/// Binary data element: `@length@bytes` (bytes as Latin-1 characters).
String fintsBinary(String latin1Data) => '@${latin1Data.length}@$latin1Data';

/// One segment to send: "NAME:number:version[:reference]" followed by its data elements. An
/// element is a String (taken as is: escape free text with [fintsEscape]) or a List of group items
/// (joined with ":"). Trailing empty elements are dropped, as the standard asks.
String fintsSegment(String name, int number, int version, List<Object?> elements, {int? reference}) {
  final parts = <String>[
    [name, '$number', '$version', if (reference != null) '$reference'].join(':'),
    for (final e in elements) e is List ? _trimGroup(e.map((x) => x?.toString() ?? '').toList()).join(':') : (e?.toString() ?? ''),
  ];
  while (parts.length > 1 && parts.last.isEmpty) {
    parts.removeLast();
  }
  return "${parts.join('+')}'";
}

List<String> _trimGroup(List<String> g) {
  final out = [...g];
  while (out.length > 1 && out.last.isEmpty) {
    out.removeLast();
  }
  return out;
}

/// A received segment: its header and data elements, each a list of group items. Binary items are
/// kept as Latin-1 strings.
class FintsSegment {
  final String name;
  final int number;
  final int version;
  final int? reference;
  final List<List<String>> elements;
  const FintsSegment(this.name, this.number, this.version, this.reference, this.elements);

  /// Item [item] of element [index] (0 = the first after the header), or ''.
  String at(int index, [int item = 0]) =>
      index < elements.length && item < elements[index].length ? elements[index][item] : '';

  @override
  String toString() => '$name:$number:$version${reference == null ? '' : ':$reference'} $elements';
}

/// Splits a message into segments; the content of an encryption envelope (HNVSD) is unpacked in
/// place, so callers see the bank's answer segments directly.
List<FintsSegment> parseFints(String message) {
  final segments = <FintsSegment>[];
  var elements = <List<String>>[];
  var group = <String>[];
  final item = StringBuffer();
  var i = 0;

  void endItem() {
    group.add(item.toString());
    item.clear();
  }

  void endElement() {
    endItem();
    elements.add(group);
    group = <String>[];
  }

  void endSegment() {
    endElement();
    final head = elements.first;
    if (head.isNotEmpty && head.first.isNotEmpty) {
      final s = FintsSegment(
        head.first,
        int.tryParse(head.elementAtOrNull(1) ?? '') ?? 0,
        int.tryParse(head.elementAtOrNull(2) ?? '') ?? 0,
        int.tryParse(head.elementAtOrNull(3) ?? ''),
        elements.sublist(1),
      );
      if (s.name == 'HNVSD' && s.elements.isNotEmpty) {
        segments.addAll(parseFints(s.at(0)));
      } else {
        segments.add(s);
      }
    }
    elements = <List<String>>[];
  }

  while (i < message.length) {
    final c = message[i];
    if (c == '?' && i + 1 < message.length) {
      item.write(message[i + 1]);
      i += 2;
    } else if (c == '@') {
      final end = message.indexOf('@', i + 1);
      final n = end < 0 ? null : int.tryParse(message.substring(i + 1, end));
      if (n == null) {
        item.write(c);
        i++;
      } else {
        item.write(message.substring(end + 1, (end + 1 + n).clamp(0, message.length)));
        i = end + 1 + n;
      }
    } else if (c == ':') {
      endItem();
      i++;
    } else if (c == '+') {
      endElement();
      i++;
    } else if (c == "'") {
      endSegment();
      i++;
    } else if ((c == '\r' || c == '\n') && item.isEmpty && group.isEmpty && elements.isEmpty) {
      i++; // line breaks some servers put between segments
    } else {
      item.write(c);
      i++;
    }
  }
  return segments;
}

/// A return code of the bank (HIRMG for the whole message, HIRMS for one segment):
/// 0xxx success, 3xxx warning or information, 9xxx error.
class FintsReturn {
  final String code;
  final String text;
  final List<String> params;
  final int? reference;
  const FintsReturn(this.code, this.text, this.params, this.reference);

  bool get isError => code.startsWith('9');
  @override
  String toString() => '$code $text${params.isEmpty ? '' : ' ${params.join(',')}'}';
}

List<FintsReturn> fintsReturns(List<FintsSegment> segments) => [
      for (final s in segments.where((s) => s.name == 'HIRMG' || s.name == 'HIRMS'))
        for (final e in s.elements)
          if (e.isNotEmpty && e.first.isNotEmpty) FintsReturn(e.first, e.elementAtOrNull(2) ?? '', e.length > 3 ? e.sublist(3) : const [], s.reference),
    ];

String latin1Text(List<int> bytes) => latin1.decode(bytes, allowInvalid: true);
List<int> latin1Bytes(String s) => latin1.encode(s.replaceAllMapped(RegExp(r'[^\x00-\xFF]'), (_) => '?'));
