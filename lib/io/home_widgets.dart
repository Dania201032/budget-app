import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../data/models.dart';
import '../domain/currencies.dart';
import '../domain/money.dart';
import '../domain/runway.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';

/// Sends the figures shown by the five home-screen widgets to the Android side, which draws them
/// (android/.../widgets). Everything is formatted and localized here, so the widgets show the
/// same numbers as the app.
class HomeWidgetsBridge {
  static const _channel = MethodChannel('budget/widgets');
  static Future<void>? _running;
  static bool _again = false;

  /// Coalesces bursts of updates: at most one push runs, the last change always gets through.
  /// The returned future completes when the widgets show the newest figures.
  static Future<void> push(AppState state) {
    if (!Platform.isAndroid) return Future.value();
    if (_running != null) {
      _again = true;
      return _running!;
    }
    return _running = _loop(state).whenComplete(() => _running = null);
  }

  static Future<void> _loop(AppState state) async {
    try {
      do {
        _again = false;
        final json = jsonEncode(await snapshot(state));
        await _channel.invokeMethod('update', {'json': json});
      } while (_again);
    } catch (_) {
      // Widgets are a convenience: never let them break the app.
    }
  }

  /// In the running app: Android asks for a refresh after a background capture or at midnight.
  static void listen(AppState state) {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'refresh') {
        await state.refresh();
        await push(state);
      }
      return null;
    });
  }

  /// Asks the launcher to place a widget ([kind]: CALENDAR, SUMMARY, TODAY, RUNWAY, QUICK).
  static Future<bool> pin(String kind) async {
    try {
      return await _channel.invokeMethod<bool>('pin', {'kind': kind}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// In the headless engine: tells Android the work is done, so it can shut the engine down.
  static Future<void> backgroundDone() async {
    try {
      await _channel.invokeMethod('backgroundDone');
    } catch (_) {}
  }

  static Future<Map<String, Object?>> snapshot(AppState s) async {
    final now = DateTime.now();
    String n(num v) => formatAmount(v.round(), pattern: '#,##0');
    String signed(num v) => '${v >= 0 ? '+' : '−'}${n(v.abs())}';
    final month = s.currentMonthStats();
    final today = s.todayStats;

    // Day codes for the calendar: 0 future / nothing, 1 within the limit, 2 over it, 3 spent (no budget).
    final buckets = month.period.buckets;
    final days = <int>[
      for (var i = 0; i < buckets.length; i++)
        if (buckets[i].isAfter(now))
          0
        else if (s.budgetEnabled && month.budgetByBucket[i] > 0)
          month.spentByBucket[i] > month.budgetByBucket[i] ? 2 : 1
        else
          month.spentByBucket[i] > 0 ? 3 : 0,
    ];
    final daysLeft = month.daysTotal - month.daysPassed;
    final pace = month.daysTotal == 0 ? 0.0 : month.budgetMinor * month.daysPassed / month.daysTotal - month.spentMinor;

    Map<String, Object?>? runway;
    try {
      final r = await s.computeRunwayFor(s.runwayConfig);
      final left = r.daysLeft(now);
      // The projection runs for years; the sparkline shows it up to the day the money runs out.
      final end = r.runsOutOn == null ? -1 : r.projection.indexWhere((p) => !p.day.isBefore(r.runsOutOn!));
      final pts = end > 0 ? r.projection.sublist(0, end + 1) : r.projection;
      final top = pts.fold<int>(1, (m, p) => p.balanceMinor > m ? p.balanceMinor : m);
      const samples = 12;
      runway = {
        'date': r.runsOutOn == null ? '∞' : (left! <= 0 ? '—' : DateFormat('dd.MM', intlLocale).format(r.runsOutOn!)),
        'sub': r.runsOutOn == null
            ? tr('runway_forever', [maxYears])
            : left! <= 0
                ? tr('runway_now')
                : (left ~/ 30 > 0 ? tr('runway_months_days', [left ~/ 30, left % 30]) : tr('runway_days', [left])),
        'points': [
          if (pts.length > 1)
            for (var i = 0; i < samples; i++)
              (pts[(i * (pts.length - 1) / (samples - 1)).round()].balanceMinor / top).clamp(0.0, 1.0),
        ],
      };
    } catch (_) {
      runway = null;
    }

    return {
      'date': DateFormat('yyyy-MM-dd').format(now),
      'cur': currencySymbol(s.baseCurrency),
      'budgetOn': s.budgetEnabled,
      'labels': {
        'today': tr('w_today'),
        'over': tr('today_over'),
        'open': tr('w_open_app'),
        'budgetOff': tr('w_budget_off'),
        'of': tr('w_of'),
        'runway': tr('w_runway'),
        'spent': tr('expenses'),
        'left': tr('left'),
        'leftLower': tr('w_left_lower'),
        'perDay': tr('w_per_day'),
        'pace': tr('w_pace'),
        'income': tr('income'),
        'byDays': tr('by_days'),
        'record': tr('w_record'),
      },
      if (today != null)
        'today': {
          'left': n(today.todayLeft.abs()),
          'allowance': n(today.todayAllowance),
          'over': today.todayLeft < 0,
          'spentShare': today.todayAllowance <= 0 ? 1.0 : (today.spentTodayMinor / today.todayAllowance).clamp(0.0, 1.0),
        },
      'month': {
        'name': DateFormat.LLLL(intlLocale).format(now).toUpperCase(),
        'spent': n(month.spentMinor),
        'budget': n(month.budgetMinor),
        'left': n(month.remainingMinor),
        'perDay': daysLeft > 0 ? n(month.remainingMinor / daysLeft) : '—',
        'pace': signed(pace),
        'paceGood': pace >= 0,
        'income': n(month.incomeMinor),
        'spentShare': month.budgetMinor == 0 ? 0.0 : (month.spentMinor / month.budgetMinor).clamp(0.0, 1.0),
        'elapsed': month.daysTotal == 0 ? 0.0 : month.daysPassed / month.daysTotal,
        'lead': buckets.isEmpty ? 0 : buckets.first.weekday - 1,
        'today': now.day,
        'days': days,
      },
      'runway': runway,
      'quick': [
        for (final c in s.frequentExpenseCategories(4)) {'id': c.id, 'name': s.categoryName(c), 'color': c.color},
      ],
    };
  }
}

/// Where a widget tap should lead (set from the pending action, handled by the shell).
class WidgetRoute {
  final String route; // add | home | overview_calendar | analytics
  final int? categoryId;
  const WidgetRoute(this.route, this.categoryId);

  /// A new transaction draft for "add" taps (with the tapped category, if any).
  Txn draft(String currency) =>
      Txn(time: DateTime.now(), amountMinor: 0, currency: currency, kind: TxnKind.expense, categoryId: categoryId);
}
