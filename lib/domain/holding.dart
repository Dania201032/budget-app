/// Money outside the accounts: a deposit, savings, bonds, shares, a fund, property — or a loan
/// (what is owed, counted against the net worth). Kept as the JSON setting "desk_holdings",
/// which every device of the budget shares.
class Holding {
  final String id;

  /// deposit | savings | bonds | stocks | fund | property | other — or loan (owed)
  final String type;
  final String name;
  final String where;
  final String currency;
  final int amountMinor;

  /// Yearly rate, percent (interest, coupon, expected growth).
  final double ratePct;

  /// monthly | quarterly | twice | yearly | daily | none
  final String payout;

  /// Paid so far this year (after tax), minor units.
  final int receivedMinor;
  final DateTime? nextPayment;
  final DateTime? maturity;

  /// Counted in "All money" and the forecast.
  final bool counted;

  const Holding({
    required this.id,
    required this.type,
    required this.name,
    this.where = '',
    required this.currency,
    required this.amountMinor,
    this.ratePct = 0,
    this.payout = 'monthly',
    this.receivedMinor = 0,
    this.nextPayment,
    this.maturity,
    this.counted = false,
  });

  /// A loan or a mortgage: owed, it lowers the net worth.
  bool get isLoan => type == 'loan';

  /// The amount as it counts: negative for a loan.
  int get signedMinor => isLoan ? -amountMinor : amountMinor;

  /// Expected payment per month (minor units), from the yearly rate; a loan's interest is a cost.
  double get monthlyIncome => payout == 'none' ? 0 : signedMinor * ratePct / 100 / 12;

  Map<String, Object?> toJson() => {
        'id': id,
        'type': type,
        'name': name,
        'where': where,
        'currency': currency,
        'amount': amountMinor,
        'rate': ratePct,
        'payout': payout,
        'received': receivedMinor,
        'next': nextPayment?.millisecondsSinceEpoch,
        'maturity': maturity?.millisecondsSinceEpoch,
        'counted': counted,
      };

  factory Holding.fromJson(Map<String, dynamic> j) {
    DateTime? d(Object? v) => v == null ? null : DateTime.fromMillisecondsSinceEpoch((v as num).toInt());
    return Holding(
      id: j['id'] as String? ?? '${DateTime.now().microsecondsSinceEpoch}',
      type: j['type'] as String? ?? 'other',
      name: j['name'] as String? ?? '',
      where: j['where'] as String? ?? '',
      currency: j['currency'] as String? ?? 'USD',
      amountMinor: (j['amount'] as num?)?.toInt() ?? 0,
      ratePct: (j['rate'] as num?)?.toDouble() ?? 0,
      payout: j['payout'] as String? ?? 'monthly',
      receivedMinor: (j['received'] as num?)?.toInt() ?? 0,
      nextPayment: d(j['next']),
      maturity: d(j['maturity']),
      counted: j['counted'] as bool? ?? false,
    );
  }

  Holding copyWith({bool? counted}) => Holding(
        id: id,
        type: type,
        name: name,
        where: where,
        currency: currency,
        amountMinor: amountMinor,
        ratePct: ratePct,
        payout: payout,
        receivedMinor: receivedMinor,
        nextPayment: nextPayment,
        maturity: maturity,
        counted: counted ?? this.counted,
      );
}
