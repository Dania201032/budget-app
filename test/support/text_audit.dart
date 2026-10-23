import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show DebugCreator;
import 'package:flutter_test/flutter_test.dart';

/// Loads the app's real fonts, so text in tests is measured as on the phone (the default test
/// font is much wider and hides or invents wrapping).
Future<void> loadAppFonts() async {
  final fonts = {
    'IBMPlexSans': ['Regular', 'Medium', 'SemiBold'],
    'IBMPlexMono': ['Regular', 'Medium', 'SemiBold'],
  };
  for (final e in fonts.entries) {
    final loader = FontLoader(e.key);
    for (final w in e.value) {
      loader.addFont(rootBundle.load('assets/fonts/${e.key}-$w.ttf'));
    }
    await loader.load();
  }
}

/// Finds text that looks broken on screen: short labels wrapped onto a second line, words split
/// in the middle, and labels cut off with "…". Collected per language into build/text_audit_LANG.txt.
class TextAudit {
  final String lang;
  final _issues = <String>{};
  TextAudit(this.lang);

  static final _letter = RegExp(r'[\p{L}\p{N}]', unicode: true);
  static final _cjk = RegExp(r'[　-鿿＀-￯]');

  void check(WidgetTester tester, String where) {
    for (final p in tester.allRenderObjects.whereType<RenderParagraph>()) {
      if (!p.attached || !p.hasSize || p.size.isEmpty) continue;
      final text = p.text.toPlainText().replaceAll('\n', ' ').trim();
      if (text.isEmpty || !_letter.hasMatch(text)) continue;
      // The paragraph laid out again the same way, to read its lines.
      final painter = TextPainter(
        text: p.text,
        textDirection: p.textDirection,
        textAlign: p.textAlign,
        textScaler: p.textScaler,
        maxLines: p.maxLines,
        ellipsis: p.overflow == TextOverflow.ellipsis ? '…' : null,
        locale: p.locale,
        strutStyle: p.strutStyle,
        textWidthBasis: p.textWidthBasis,
        textHeightBehavior: p.textHeightBehavior,
      )..layout(maxWidth: p.constraints.maxWidth);
      final lines = painter.computeLineMetrics();
      if (p.didExceedMaxLines) {
        final chain = p.debugCreator is DebugCreator ? (p.debugCreator! as DebugCreator).element.debugGetCreatorChain(6) : '';
        _issues.add('CUT     | $where | "$text" | ${chain.length > 300 ? chain.substring(0, 300) : chain}');
        continue;
      }
      if (lines.length < 2) continue;
      final words = text.split(RegExp(r'\s+'));
      if (words.length <= 2 && text.length <= 30) {
        _issues.add('WRAP    | $where | "$text" (${lines.length} lines, ${p.size.width.toStringAsFixed(0)} wide)');
        continue;
      }
      // A line ending inside a word: letters on both sides of the break.
      final raw = p.text.toPlainText();
      for (var i = 0; i < lines.length - 1; i++) {
        final l = lines[i];
        final pos = painter.getPositionForOffset(Offset(l.left + l.width - 0.5, l.baseline - l.ascent / 2)).offset;
        if (pos <= 0 || pos >= raw.length) continue;
        final before = raw[pos - 1];
        final after = raw[pos];
        // Chinese breaks between any characters.
        if (_cjk.hasMatch(before) || _cjk.hasMatch(after)) continue;
        if (_letter.hasMatch(before) && _letter.hasMatch(after)) {
          _issues.add('SPLIT   | $where | "${raw.substring((pos - 12).clamp(0, pos), pos)}|${raw.substring(pos, (pos + 12).clamp(pos, raw.length))}"');
          break;
        }
      }
    }
  }

  void write() {
    Directory('build').createSync(recursive: true);
    final sorted = _issues.toList()..sort();
    File('build/text_audit_$lang.txt').writeAsStringSync('${sorted.join('\n')}\n');
  }
}
