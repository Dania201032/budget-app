import 'dart:io';

import 'package:budget_app/l10n/strings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every tr() key used in the code exists, in all languages', () {
    final keyRe = RegExp(r"""tr\(\s*'([a-z0-9_]+)'""");
    final missing = <String>{};
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      for (final m in keyRe.allMatches(f.readAsStringSync())) {
        if (!hasTr(m.group(1)!)) missing.add('${m.group(1)} (${f.path})');
      }
    }
    expect(missing, isEmpty);
  });

  test('dynamic keys exist', () {
    for (final k in ['food', 'drinks', 'transport', 'fun', 'shopping', 'housing', 'subscriptions', 'health', 'education',
        'other', 'transfers_out', 'stipend', 'salary', 'transfers_in', 'other_income']) {
      expect(hasTr('cat_$k'), isTrue, reason: k);
    }
    for (final c in ['CN', 'RU', 'KZ', 'DE', 'NL']) {
      expect(hasTr('country_$c'), isTrue);
    }
    for (final p in ['day', 'week', 'month', 'year']) {
      expect(hasTr('period_$p'), isTrue);
    }
    for (var i = 1; i <= 5; i++) {
      expect(hasTr('guide${i}_t') && hasTr('guide${i}_b'), isTrue);
    }
    for (final h in ['budget', 'capture', 'review', 'overview', 'split', 'money', 'currency', 'backup']) {
      expect(hasTr('help_${h}_t') && hasTr('help_${h}_b'), isTrue);
    }
  });

  test('switching language changes text and placeholders work', () {
    final saved = currentLanguage;
    for (final (lang, expected) in [
      ('ru', 'Вам должны: 5 ¥'),
      ('en', 'Owed to you: 5 ¥'),
      ('zh', '别人欠你：5 ¥'),
      ('kk', 'Сізге қарыз: 5 ¥'),
      ('de', 'Man schuldet Ihnen: 5 ¥'),
      ('nl', 'Men is u verschuldigd: 5 ¥'),
    ]) {
      currentLanguage = lang;
      expect(tr('owed_to_you', ['5 ¥']), expected);
    }
    currentLanguage = 'fr';
    expect(currentLanguage, 'en', reason: 'unsupported languages fall back to English');
    currentLanguage = saved;
  });
}
