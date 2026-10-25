import 'dart:convert';

import '../data/repository.dart';

/// Tax marks: what spending may lower the tax (a deduction, work expenses…). They don't fill in a
/// return; they gather what one needs for it, with the receipts. Categories carry a default mark
/// (setting "tax_tags", by category uid, shared by the devices); an operation may have its own.
const taxTagKeys = ['medical', 'education', 'sport', 'charity', 'work', 'housing', 'children', 'other'];

Future<Map<String, String>> loadTaxTags(Repository repo) async {
  final s = await repo.setting('tax_tags');
  if (s == null) return {};
  try {
    final j = jsonDecode(s) as Map<String, dynamic>;
    return {for (final e in j.entries) e.key: e.value as String};
  } catch (_) {
    return {};
  }
}

Future<void> saveTaxTags(Repository repo, Map<String, String> tags) => repo.setSetting('tax_tags', jsonEncode(tags));
