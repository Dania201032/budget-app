import '../capture/capture_service.dart';
import '../data/models.dart';
import '../data/repository.dart';
import 'statement.dart';

/// What happens to a statement row: added as a new operation, recognised as one the app already
/// has (auto-captured, typed by hand, imported before), or left out.
enum RowFate { add, known, skipped }

class PlannedRow {
  final StatementRow row;
  final RowFate fate;

  /// For [RowFate.skipped]: failed, pending, neutral, deleted (the user deleted it in the app), excel
  /// (a day covered by the spreadsheet import).
  final String? reason;

  /// For [RowFate.known]: the operation it is.
  final Txn? match;
  final int? categoryId;

  /// Kept in the operation's raw text (see [_rowKey]).
  final String key;

  /// The user may untick a row to be added.
  bool include;

  PlannedRow(this.row, this.fate, {required this.key, this.reason, this.match, this.categoryId}) : include = fate == RowFate.add;
}

class StatementPlan {
  final Statement statement;
  final Account account;
  final List<PlannedRow> rows;
  const StatementPlan(this.statement, this.account, this.rows);

  Iterable<PlannedRow> get toAdd => rows.where((r) => r.fate == RowFate.add);
  Iterable<PlannedRow> get known => rows.where((r) => r.fate == RowFate.known);
  Iterable<PlannedRow> get skipped => rows.where((r) => r.fate == RowFate.skipped);
}

/// The account a statement most likely belongs to: the payment app's own account, or the bank's
/// account by its name ("ВТБ", "DKB Girokonto") in the statement's currency.
Future<Account?> guessStatementAccount(Repository repo, Statement s) async {
  final accounts = await repo.myAccounts();
  final app = s.app;
  if (app == null) return null;
  final byType = accounts.where((a) => a.type == app).firstOrNull;
  if (byType != null) return byType;
  final id = await repo.accountForBank(app, s.currency ?? '');
  return id == null ? null : accounts.where((a) => a.id == id).firstOrNull;
}

/// Key of a row in the transaction's raw text: the bank's id, or the row's own fields (with its
/// number among identical rows of the statement) — so importing the same file again adds nothing.
String _rowKey(Statement s, StatementRow r, int n) {
  if (r.id != null) return 'statement|${s.format}|id:${r.id}';
  final d = r.time;
  final day = '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
  return 'statement|${s.format}|$day|${r.kind.name}|${r.amountMinor}|${r.payee ?? ''}|$n';
}

/// Card payments are booked by banks a day or three after they happen, and statements may use
/// another time zone (Sber writes Moscow time): a second, looser pass pairs what the exact one left.
bool _close(StatementRow r, Txn t, {required bool loose}) {
  final dt = t.time.difference(r.time).abs();
  final dateOnly = !r.hasTime || (t.source.contains('bill') && !t.source.contains('notification') && !t.source.contains('screen'));
  if (!loose) {
    if (!dateOnly) return dt <= const Duration(minutes: 15);
    return t.time.year == r.time.year && t.time.month == r.time.month && t.time.day == r.time.day;
  }
  if (!dateOnly) return dt <= const Duration(hours: 14);
  final day = DateTime(r.time.year, r.time.month, r.time.day);
  return !t.time.isBefore(day.subtract(const Duration(days: 3))) && t.time.isBefore(day.add(const Duration(days: 2)));
}

Future<StatementPlan> planStatementImport(Repository repo, Statement s, Account account) async {
  final rows = [...s.rows]..sort((a, b) => a.time.compareTo(b.time));
  final excelUntil = await repo.lastDayOf('excel', TxnKind.expense);
  final categories = await repo.categories();
  final from = s.from ?? DateTime.now();
  final to = s.to ?? DateTime.now();
  final existing = await repo.txnsBetween(from.subtract(const Duration(days: 4)), to.add(const Duration(days: 4)));
  final rawKeys = {for (final t in existing) ...?t.raw?.split('\n').where((l) => l.startsWith('statement|'))};
  final used = <int>{};
  final seen = <String, int>{};

  final planned = List<PlannedRow?>.filled(rows.length, null);
  final keys = <String>[];
  for (var i = 0; i < rows.length; i++) {
    final r = rows[i];
    final base = '${r.time.year}-${r.time.month}-${r.time.day}|${r.kind.name}|${r.amountMinor}|${r.payee}';
    final n = seen[base] = (seen[base] ?? -1) + 1;
    keys.add(_rowKey(s, r, n));
  }

  bool candidate(StatementRow r, Txn t) =>
      !used.contains(t.id) &&
      t.kind == r.kind &&
      t.amountMinor == r.amountMinor &&
      t.currency == _currency(r, account) &&
      (t.accountId == null || t.accountId == account.id);

  // Pass 0: rows imported before. Pass 1: exact time (or same day). Pass 2: loose.
  for (var i = 0; i < rows.length; i++) {
    final r = rows[i];
    if (r.skip != null) {
      planned[i] = PlannedRow(r, RowFate.skipped, key: keys[i], reason: r.skip);
    } else if (excelUntil != null && !DateTime(r.time.year, r.time.month, r.time.day).isAfter(excelUntil)) {
      planned[i] = PlannedRow(r, RowFate.skipped, key: keys[i], reason: 'excel');
    } else if (rawKeys.contains(keys[i])) {
      final t = existing.where((t) => (t.raw ?? '').split('\n').contains(keys[i])).firstOrNull;
      if (t?.id != null) used.add(t!.id!);
      planned[i] = PlannedRow(r, RowFate.known, key: keys[i], match: t);
    }
  }
  for (final loose in [false, true]) {
    for (var i = 0; i < rows.length; i++) {
      if (planned[i] != null) continue;
      final r = rows[i];
      final match = existing.where((t) => candidate(r, t) && _close(r, t, loose: loose)).toList()
        ..sort((a, b) => a.time.difference(r.time).abs().compareTo(b.time.difference(r.time).abs()));
      if (match.isEmpty) continue;
      used.add(match.first.id!);
      planned[i] = PlannedRow(r, RowFate.known, key: keys[i], match: match.first);
    }
  }
  for (var i = 0; i < rows.length; i++) {
    if (planned[i] != null) continue;
    final r = rows[i];
    final app = s.app ?? account.type;
    final deleted = await repo.dismissedCount(
      app: app,
      kind: r.kind,
      amountMinor: r.amountMinor,
      from: r.hasTime ? r.time.subtract(const Duration(minutes: 15)) : DateTime(r.time.year, r.time.month, r.time.day),
      to: r.hasTime ? r.time.add(const Duration(minutes: 15)) : DateTime(r.time.year, r.time.month, r.time.day + 1),
    );
    if (deleted > 0) {
      planned[i] = PlannedRow(r, RowFate.skipped, key: keys[i], reason: 'deleted');
      continue;
    }
    planned[i] = PlannedRow(r, RowFate.add, key: keys[i], categoryId: await _category(repo, s, r, categories));
  }
  return StatementPlan(s, account, planned.cast<PlannedRow>());
}

String _currency(StatementRow r, Account account) => r.currency.isEmpty ? account.currency : r.currency;

/// Adds the ticked new rows and fills in shop names and categories of the known ones.
/// Returns the number of operations added.
Future<int> applyStatementImport(Repository repo, StatementPlan plan) async {
  final s = plan.statement;
  final app = s.app ?? plan.account.type;
  final importer = CaptureImporter(repo);
  var added = 0;
  for (final p in plan.rows) {
    final key = p.key;
    final r = p.row;
    if (p.fate == RowFate.known && p.match != null) {
      final t = p.match!;
      final merchant = t.merchant ?? r.payee;
      final categoryId = t.categoryId ?? await _category(repo, s, r, await repo.categories());
      final raw = (t.raw ?? '').contains(key) ? t.raw : [if (t.raw != null && t.raw!.isNotEmpty) t.raw!, key].join('\n');
      await repo.updateTxn(t.copyWith(
        merchant: () => merchant,
        categoryId: () => categoryId,
        note: () => t.note ?? _note(r),
        needsReview: t.needsReview && categoryId == null,
        raw: raw,
      ));
      continue;
    }
    if (p.fate != RowFate.add || !p.include) continue;
    final id = await repo.insertTxn(Txn(
      time: r.time,
      amountMinor: r.amountMinor,
      currency: _currency(r, plan.account),
      kind: r.kind,
      categoryId: p.categoryId,
      accountId: plan.account.id,
      merchant: r.payee,
      note: _note(r),
      source: '$app:statement',
      needsReview: p.categoryId == null,
      raw: key,
    ));
    added++;
    final t = await repo.txnById(id);
    if (t != null) await importer.checkOwnTransfer(t);
  }
  return added;
}

/// Details worth keeping: the purpose when it says more than the shop's name.
String? _note(StatementRow r) {
  final d = r.details?.trim();
  if (d == null || d.isEmpty || d == r.payee) return null;
  return d.length > 140 ? '${d.substring(0, 140)}…' : d;
}

Future<int?> _category(Repository repo, Statement s, StatementRow r, List<Category> categories) async {
  if (r.payee != null) {
    final learned = await repo.categoryForMerchant(r.payee!, r.kind);
    if (learned != null) return learned;
  }
  final key = switch (s.format) {
        'alipay' => alipayCategoryKey(r.category, r.kind),
        'wechat' => _wechatCategoryKey(r.category, r.kind),
        _ => null,
      } ??
      mccCategoryKey(r.mcc, r.kind) ??
      bankCategoryKey(r.category, r.kind);
  if (key == null) return null;
  return categories.where((c) => c.kind == r.kind && c.key == key).firstOrNull?.id;
}

/// WeChat's "交易类型" is how money moved, not what it was for: only transfers say something.
String? _wechatCategoryKey(String? type, TxnKind kind) {
  if (type == null) return null;
  if (type.contains('转账') || type.contains('红包')) return kind == TxnKind.expense ? 'transfers_out' : 'transfers_in';
  return null;
}

/// Card networks' merchant category codes -> built-in category keys (expenses only).
String? mccCategoryKey(String? mcc, TxnKind kind) {
  final code = int.tryParse(mcc?.trim() ?? '');
  if (code == null || kind != TxnKind.expense) return null;
  bool inR(int a, int b) => code >= a && code <= b;
  if (const {5411, 5412, 5422, 5441, 5451, 5462, 5499, 5811, 5812, 5814}.contains(code)) return 'food';
  if (code == 5813) return 'drinks';
  if (inR(3000, 3299) || inR(3351, 3500) || const {4011, 4111, 4112, 4121, 4131, 4411, 4457, 4468, 4511, 4582, 4784, 4789, 5541, 5542, 5983, 7511, 7512, 7523, 7531}.contains(code)) {
    return 'transport';
  }
  if (const {5912, 5975, 5976, 8011, 8021, 8031, 8041, 8042, 8043, 8049, 8050, 8062, 8071, 8099, 7298}.contains(code)) return 'health';
  if (inR(8211, 8299) || const {5942, 5943}.contains(code)) return 'education';
  if (const {4812, 4814, 4816, 4899, 5815, 5816, 5817, 5818, 7372}.contains(code)) return 'subscriptions';
  if (const {4900, 6513, 7011}.contains(code)) return code == 7011 ? 'fun' : 'housing';
  if (const {7832, 7841, 7922, 7929, 7932, 7933, 7941, 7991, 7992, 7993, 7994, 7996, 7997, 7998, 7999, 4722}.contains(code)) return 'fun';
  if (inR(5200, 5399) || inR(5600, 5699) || inR(5700, 5735) || inR(5900, 5999) || inR(5000, 5199)) return 'shopping';
  if (const {6010, 6011}.contains(code)) return 'other';
  if (const {4829, 6012, 6538, 6540}.contains(code)) return 'transfers_out';
  return null;
}
