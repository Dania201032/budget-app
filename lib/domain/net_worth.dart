import 'dart:convert';

import '../data/repository.dart';
import 'holding.dart';

/// Everything one has minus everything one owes, in the base currency.
class NetWorth {
  /// Accounts with money on them, and accounts in the minus (credit cards).
  final int accounts;
  final int cards;

  /// Money put aside in goals (it left the accounts when put aside).
  final int goals;

  /// Deposits, savings, bonds, shares, funds; property; loans (positive here, subtracted).
  final int investments;
  final int property;
  final int loans;

  /// What friends owe.
  final int owedToMe;

  const NetWorth({
    this.accounts = 0,
    this.cards = 0,
    this.goals = 0,
    this.investments = 0,
    this.property = 0,
    this.loans = 0,
    this.owedToMe = 0,
  });

  int get assets => accounts + goals + investments + property + owedToMe;
  int get debts => cards + loans;
  int get total => assets - debts;
}

Future<List<Holding>> loadHoldings(Repository repo) async {
  final s = await repo.setting('desk_holdings');
  if (s == null) return [];
  final j = jsonDecode(s);
  return j is List ? [for (final e in j.whereType<Map>()) Holding.fromJson(e.cast<String, dynamic>())] : [];
}

Future<void> saveHoldings(Repository repo, List<Holding> holdings) =>
    repo.setSetting('desk_holdings', jsonEncode([for (final h in holdings) h.toJson()]));

/// The net worth at the end of each month ("2026-10" -> base minor units), as recorded.
Future<Map<String, int>> loadNetWorthHistory(Repository repo) async {
  final s = await repo.setting('networth_history');
  if (s == null) return {};
  final j = jsonDecode(s);
  return j is Map ? {for (final e in j.entries) e.key as String: (e.value as num).toInt()} : {};
}
