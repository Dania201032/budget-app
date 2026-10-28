import '../data/models.dart';
import 'money.dart';

/// What the operations search looks for. Empty fields don't filter.
class TxnFilter {
  final String query;
  final TxnKind? kind;
  final DateTime? from;

  /// Exclusive.
  final DateTime? to;
  final Set<int> categories;
  final int? accountId;

  const TxnFilter({this.query = '', this.kind, this.from, this.to, this.categories = const {}, this.accountId});

  bool get isEmpty =>
      query.trim().isEmpty && kind == null && from == null && to == null && categories.isEmpty && accountId == null;

  TxnFilter copyWith({
    String? query,
    TxnKind? Function()? kind,
    DateTime? Function()? from,
    DateTime? Function()? to,
    Set<int>? categories,
    int? Function()? accountId,
  }) =>
      TxnFilter(
        query: query ?? this.query,
        kind: kind != null ? kind() : this.kind,
        from: from != null ? from() : this.from,
        to: to != null ? to() : this.to,
        categories: categories ?? this.categories,
        accountId: accountId != null ? accountId() : this.accountId,
      );
}

/// [categoryName] gives the shown (translated) name of a category id, so "еда" finds Food;
/// [accountName] the account's, so "wechat" or "сбер" finds that account's operations. The app an
/// operation was recorded from ("alipay:screen") is matched too.
/// A number finds that amount: "45" finds 45 and 45,50; "45,5" only 45,50.
bool matchesFilter(Txn t, TxnFilter f, String Function(int? categoryId) categoryName,
    {String Function(int? accountId)? accountName}) {
  if (f.kind != null && t.kind != f.kind) return false;
  if (f.from != null && t.time.isBefore(f.from!)) return false;
  if (f.to != null && !t.time.isBefore(f.to!)) return false;
  if (f.categories.isNotEmpty && !f.categories.contains(t.categoryId)) return false;
  if (f.accountId != null && t.accountId != f.accountId) return false;
  final q = f.query.trim().toLowerCase();
  if (q.isEmpty) return true;

  final number = RegExp(r'^\d+([.,]\d{1,2})?$').hasMatch(q) ? parseAmountToMinor(q) : null;
  if (number != null) {
    final exact = q.contains(RegExp('[.,]'));
    if (exact ? t.amountMinor == number : t.amountMinor ~/ 100 == number ~/ 100) return true;
  }
  final app = t.source.split(':').first;
  return [t.merchant, t.note, categoryName(t.categoryId), accountName?.call(t.accountId), app]
      .any((s) => s != null && s.toLowerCase().contains(q));
}
