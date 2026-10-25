import 'dart:convert';

import '../data/repository.dart';

/// Envelope budgeting (as in YNAB or Actual), an optional mode: each expense category gets an
/// amount every month; what isn't spent stays in its envelope for the next months, overspending
/// is carried too, and money can be moved between envelopes. Kept as the JSON setting
/// "envelopes" (shared by the devices); categories by uid, as they are the same everywhere.
class EnvelopeSettings {
  bool on;

  /// First month counted ("2026-10"): envelopes carry from there.
  String? start;

  /// Every month's amount per category uid, unless [months] says otherwise for a month.
  Map<String, int> plan;
  Map<String, Map<String, int>> months;

  EnvelopeSettings({this.on = false, this.start, Map<String, int>? plan, Map<String, Map<String, int>>? months})
      : plan = plan ?? {},
        months = months ?? {};

  int allocated(String uid, String month) => months[month]?[uid] ?? plan[uid] ?? 0;

  Map<String, Object?> toJson() => {'on': on, 'start': start, 'plan': plan, 'months': months};

  factory EnvelopeSettings.fromJson(Map<String, dynamic> j) => EnvelopeSettings(
        on: j['on'] as bool? ?? false,
        start: j['start'] as String?,
        plan: {for (final e in ((j['plan'] as Map?) ?? {}).entries) e.key as String: (e.value as num).toInt()},
        months: {
          for (final m in ((j['months'] as Map?) ?? {}).entries)
            m.key as String: {for (final e in (m.value as Map).entries) e.key as String: (e.value as num).toInt()},
        },
      );
}

Future<EnvelopeSettings> loadEnvelopes(Repository repo) async {
  final s = await repo.setting('envelopes');
  if (s == null) return EnvelopeSettings();
  try {
    return EnvelopeSettings.fromJson(jsonDecode(s) as Map<String, dynamic>);
  } catch (_) {
    return EnvelopeSettings();
  }
}

Future<void> saveEnvelopes(Repository repo, EnvelopeSettings e) => repo.setSetting('envelopes', jsonEncode(e.toJson()));

Future<Map<int, String>> _uids(Repository repo) async => {
      for (final r in await repo.db.query('categories', columns: ['id', 'uid']))
        if (r['uid'] != null) r['id'] as int: r['uid'] as String,
    };

/// The monthly plan by local category id (the computer's "plan by category" uses ids).
Future<Map<int, int>> envelopePlanById(Repository repo) async {
  final e = await loadEnvelopes(repo);
  final byUid = {for (final x in (await _uids(repo)).entries) x.value: x.key};
  return {for (final p in e.plan.entries) if (byUid[p.key] != null) byUid[p.key]!: p.value};
}

Future<void> setEnvelopePlanById(Repository repo, Map<int, int> plan) async {
  final e = await loadEnvelopes(repo);
  final uids = await _uids(repo);
  e.plan = {for (final p in plan.entries) if (uids[p.key] != null && p.value > 0) uids[p.key]!: p.value};
  await saveEnvelopes(repo, e);
}

/// One envelope in a month.
class Envelope {
  final int categoryId;
  final int allocated;
  final int spent;

  /// What is left: everything put in since the start minus everything spent (negative: overspent).
  final int available;
  const Envelope(this.categoryId, this.allocated, this.spent, this.available);
}

/// "2026-10" for the month of [d].
String envelopeMonth(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';

/// The months from [start] to [month] inclusive.
List<String> envelopeMonthsUpTo(String start, String month) {
  final s = start.split('-').map(int.parse).toList();
  final e = month.split('-').map(int.parse).toList();
  final out = <String>[];
  var y = s[0], m = s[1];
  while (y < e[0] || (y == e[0] && m <= e[1])) {
    out.add('$y-${m.toString().padLeft(2, '0')}');
    m++;
    if (m > 12) {
      m = 1;
      y++;
    }
    if (out.length > 600) break;
  }
  return out;
}
