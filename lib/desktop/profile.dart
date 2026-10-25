import 'dart:convert';

import '../data/repository.dart';
import '../domain/envelopes.dart';
import '../domain/holding.dart';
import '../ui/onboarding.dart' as phone show countries;

export '../domain/holding.dart';

/// What the computer version keeps besides the shared data: the user's countries, investments,
/// category plans, forecast scenarios, hint rules and tax inputs. Stored as JSON settings, so they
/// travel with backups and sync like every other setting.

/// A country the app knows: currency, typical banks and wallets, formats, VAT and how complete the
/// tax rules are ('full' — salary by month, deductions, deadlines; 'basic' — rates and deadlines;
/// 'soon' — incomes are kept for later).
class CountryInfo {
  final String code;
  final String currency;
  final List<String> banks;

  /// 'dmy.' 24.10.2026, 'dmy/' 24/10/2026, 'dmy-' 24-10-2026, 'mdy' 10/24/2026, 'iso' 2026-10-24,
  /// 'ymd/' 2026/10/24, 'ymd.' 2026.10.24
  final String dateStyle;

  /// 'space' 1 234,50, 'dot' 1.234,50, 'comma' 1,234.50
  final String numberStyle;
  final bool weekStartsSunday;

  /// Standard and reduced VAT (or GST), percent; null = no VAT (US sales tax).
  final double? vat;
  final double? vatReduced;
  final String taxTier;

  const CountryInfo(this.code, this.currency, this.banks,
      {this.dateStyle = 'dmy.',
      this.numberStyle = 'space',
      this.weekStartsSunday = false,
      this.vat,
      this.vatReduced,
      this.taxTier = 'soon'});
}

const countryInfos = <CountryInfo>[
  CountryInfo('RU', 'RUB', ['Сбер', 'ВТБ', 'Т-Банк', 'Альфа-Банк', 'Точка'], vat: 22, vatReduced: 10, taxTier: 'full'),
  CountryInfo('CN', 'CNY', ['Alipay', 'WeChat Pay', 'ICBC', 'Bank of China', 'China Merchants Bank'],
      dateStyle: 'iso', numberStyle: 'comma', vat: 13, vatReduced: 9, taxTier: 'full'),
  CountryInfo('KZ', 'KZT', ['Kaspi', 'Halyk', 'Freedom', 'Jusan'], vat: 16, vatReduced: 16, taxTier: 'full'),
  CountryInfo('DE', 'EUR', ['Sparkasse', 'Deutsche Bank', 'DKB', 'ING', 'N26', 'PayPal'],
      numberStyle: 'dot', vat: 19, vatReduced: 7, taxTier: 'full'),
  CountryInfo('NL', 'EUR', ['ING', 'ABN AMRO', 'Rabobank', 'bunq'],
      dateStyle: 'dmy-', numberStyle: 'dot', vat: 21, vatReduced: 9, taxTier: 'full'),
  CountryInfo('US', 'USD', ['Chase', 'Bank of America', 'Wells Fargo', 'PayPal', 'Venmo'],
      dateStyle: 'mdy', numberStyle: 'comma', weekStartsSunday: true, taxTier: 'basic'),
  CountryInfo('GB', 'GBP', ['Barclays', 'HSBC', 'Lloyds', 'Monzo', 'Revolut'],
      dateStyle: 'dmy/', numberStyle: 'comma', vat: 20, vatReduced: 5, taxTier: 'basic'),
  CountryInfo('FR', 'EUR', ['BNP Paribas', 'Crédit Agricole', 'Société Générale', 'Boursorama'],
      dateStyle: 'dmy/', vat: 20, vatReduced: 5.5),
  CountryInfo('ES', 'EUR', ['Santander', 'BBVA', 'CaixaBank', 'Bizum'],
      dateStyle: 'dmy/', numberStyle: 'dot', vat: 21, vatReduced: 10, taxTier: 'basic'),
  CountryInfo('PL', 'PLN', ['PKO BP', 'mBank', 'Pekao', 'BLIK'], vat: 23, vatReduced: 8, taxTier: 'basic'),
  CountryInfo('TR', 'TRY', ['Ziraat', 'Garanti BBVA', 'İş Bankası', 'Papara'],
      numberStyle: 'dot', vat: 20, vatReduced: 10),
  CountryInfo('GE', 'GEL', ['TBC', 'Bank of Georgia'], vat: 18, vatReduced: 18, taxTier: 'basic'),
  CountryInfo('AE', 'AED', ['Emirates NBD', 'ADCB', 'FAB'], dateStyle: 'dmy/', numberStyle: 'comma', vat: 5, vatReduced: 5),
  CountryInfo('IN', 'INR', ['SBI', 'HDFC', 'ICICI', 'Paytm', 'PhonePe'],
      dateStyle: 'dmy/', numberStyle: 'comma', vat: 18, vatReduced: 5),
  CountryInfo('JP', 'JPY', ['MUFG', 'SMBC', 'Mizuho', 'PayPay'],
      dateStyle: 'ymd/', numberStyle: 'comma', weekStartsSunday: true, vat: 10, vatReduced: 8),
  CountryInfo('KR', 'KRW', ['KB', 'Shinhan', 'KakaoPay', 'Toss'],
      dateStyle: 'ymd.', numberStyle: 'comma', weekStartsSunday: true, vat: 10, vatReduced: 10),
  CountryInfo('UZ', 'UZS', ['Kapitalbank', 'Uzum', 'Click', 'Payme'], vat: 12, vatReduced: 12),
  CountryInfo('AM', 'AMD', ['Ameriabank', 'Ardshinbank'], vat: 20, vatReduced: 20),
  CountryInfo('BY', 'BYN', ['Беларусбанк', 'Приорбанк'], vat: 20, vatReduced: 10),
  CountryInfo('TH', 'THB', ['Kasikornbank', 'SCB', 'PromptPay'],
      dateStyle: 'dmy/', numberStyle: 'comma', weekStartsSunday: true, vat: 7, vatReduced: 7),
  CountryInfo('VN', 'VND', ['Vietcombank', 'MoMo'], dateStyle: 'dmy/', numberStyle: 'dot', vat: 10, vatReduced: 5),
  CountryInfo('BR', 'BRL', ['Itaú', 'Nubank', 'Pix'], dateStyle: 'dmy/', numberStyle: 'dot', weekStartsSunday: true),
];

final countryByCode = {for (final c in countryInfos) c.code: c};

/// Countries a person can choose: the same list the phone offers at the first start
/// (lib/ui/onboarding.dart), so the two never disagree.
List<CountryInfo> get appCountries => [for (final code in phone.countries) ?countryByCode[code]];

/// The user's countries: where they live ('home') and where incomes come from ('income').
class MyCountry {
  final String code;
  final bool home;
  const MyCountry(this.code, this.home);
  Map<String, Object?> toJson() => {'code': code, 'home': home};
}

/// A "what if" for the forecast: a one-off or monthly amount (+ income, − spending) from a month on.
class Scenario {
  final String id;
  final String name;
  final int amountMinor;
  final bool monthly;
  final DateTime from;

  /// Number of months for a monthly one; 0 = until the end of the horizon.
  final int months;
  final bool enabled;

  const Scenario({
    required this.id,
    required this.name,
    required this.amountMinor,
    required this.monthly,
    required this.from,
    this.months = 0,
    this.enabled = true,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'amount': amountMinor,
        'monthly': monthly,
        'from': from.millisecondsSinceEpoch,
        'months': months,
        'enabled': enabled,
      };

  factory Scenario.fromJson(Map<String, dynamic> j) => Scenario(
        id: j['id'] as String? ?? '${DateTime.now().microsecondsSinceEpoch}',
        name: j['name'] as String? ?? '',
        amountMinor: (j['amount'] as num?)?.toInt() ?? 0,
        monthly: j['monthly'] as bool? ?? false,
        from: DateTime.fromMillisecondsSinceEpoch((j['from'] as num?)?.toInt() ?? 0),
        months: (j['months'] as num?)?.toInt() ?? 0,
        enabled: j['enabled'] as bool? ?? true,
      );

  Scenario toggled() =>
      Scenario(id: id, name: name, amountMinor: amountMinor, monthly: monthly, from: from, months: months, enabled: !enabled);
}

/// The hint rules on the Summary: which are on and at what threshold (index into the rule's levels).
class HintRule {
  final String key;
  final List<num> levels;
  final int defaultLevel;
  const HintRule(this.key, this.levels, this.defaultLevel);
}

const hintRules = <HintRule>[
  HintRule('over', [5, 50, 0], 0), // category forecast above plan: by 5 %, by 50 (base units), at once
  HintRule('up', [20, 30, 50], 1), // category above the 3-month median, %
  HintRule('down', [20, 30, 50], 1), // category below the median, %
  HintRule('review', [1, 5, 10], 0), // operations waiting for review
  HintRule('fx', [1, 2, 5], 1), // a foreign account's currency moved, % per month
  HintRule('big', [1, 3, 5], 1), // a regular payment soon bigger than N daily limits
  HintRule('dup', [2, 10, 60], 0), // same amount and payee within N minutes
  HintRule('debt', [7, 14, 30], 1), // a friend's debt open for N days
];

/// Everything above, loaded from and saved to the settings table.
class DeskProfile {
  List<MyCountry> countries = [];
  List<Holding> holdings = [];
  Map<int, int> categoryPlan = {};
  List<Scenario> scenarios = [];
  Map<String, bool> hintsOn = {};
  Map<String, int> hintLevels = {};
  int hintsShown = 4;
  Set<String> hiddenHints = {};
  List<String> displayCurrencies = [];
  Map<String, String> taxInputs = {};
  Set<String> reminders = {};
  String themeMode = 'system';
  bool compact = false;
  double textScale = 1;
  bool autoMonthReport = false;
  bool autoExcel = false;
  String excelOptions = '';
  String? documentsFolder;
  String? lastAutoReport;

  bool hintOn(String key) => hintsOn[key] ?? key != 'debt';
  num hintLevel(HintRule r) => r.levels[(hintLevels[r.key] ?? r.defaultLevel).clamp(0, r.levels.length - 1)];

  String homeCountry(String fallback) => countries.where((c) => c.home).map((c) => c.code).firstOrNull ?? fallback;

  static Future<DeskProfile> load(Repository repo, {required String country, required String baseCurrency}) async {
    final p = DeskProfile();
    Future<Object?> json(String key) async {
      final s = await repo.setting(key);
      if (s == null || s.isEmpty) return null;
      try {
        return jsonDecode(s);
      } catch (_) {
        return null;
      }
    }

    final c = await json('desk_countries');
    p.countries = c is List
        ? [for (final e in c.whereType<Map>()) MyCountry(e['code'] as String, e['home'] == true)]
        : [MyCountry(country, true)];
    final h = await json('desk_holdings');
    if (h is List) p.holdings = [for (final e in h.whereType<Map>()) Holding.fromJson(e.cast<String, dynamic>())];
    // The plan by category is the envelopes' monthly plan, shared with the phone; an older plan
    // kept only on the computer is used until the first save.
    final shared = await envelopePlanById(repo);
    final plan = await json('desk_category_plan');
    if (shared.isNotEmpty) {
      p.categoryPlan = shared;
    } else if (plan is Map) {
      p.categoryPlan = {for (final e in plan.entries) int.parse(e.key as String): (e.value as num).toInt()};
    }
    final sc = await json('desk_scenarios');
    if (sc is List) p.scenarios = [for (final e in sc.whereType<Map>()) Scenario.fromJson(e.cast<String, dynamic>())];
    final hints = await json('desk_hints');
    if (hints is Map) {
      p.hintsOn = {for (final e in ((hints['on'] as Map?) ?? {}).entries) e.key as String: e.value == true};
      p.hintLevels = {for (final e in ((hints['level'] as Map?) ?? {}).entries) e.key as String: (e.value as num).toInt()};
      p.hintsShown = (hints['shown'] as num?)?.toInt() ?? 4;
      p.hiddenHints = {...((hints['hidden'] as List?) ?? []).whereType<String>()};
    }
    final cur = await json('desk_display_currencies');
    p.displayCurrencies = cur is List ? cur.whereType<String>().toList() : [];
    if (!p.displayCurrencies.contains(baseCurrency)) p.displayCurrencies.insert(0, baseCurrency);
    final tax = await json('desk_tax_inputs');
    if (tax is Map) p.taxInputs = {for (final e in tax.entries) e.key as String: '${e.value}'};
    final rem = await json('desk_reminders');
    if (rem is List) p.reminders = {...rem.whereType<String>()};
    final look = await json('desk_look');
    if (look is Map) {
      p.themeMode = look['theme'] as String? ?? 'system';
      p.compact = look['compact'] == true;
      p.textScale = (look['scale'] as num?)?.toDouble() ?? 1;
    }
    final files = await json('desk_files');
    if (files is Map) {
      p.autoMonthReport = files['month'] == true;
      p.autoExcel = files['excel'] == true;
      p.documentsFolder = files['folder'] as String?;
      p.lastAutoReport = files['last'] as String?;
    }
    p.excelOptions = await repo.setting('desk_excel') ?? '';
    return p;
  }

  Future<void> save(Repository repo) async {
    await repo.setSetting('desk_countries', jsonEncode([for (final c in countries) c.toJson()]));
    await repo.setSetting('desk_holdings', jsonEncode([for (final h in holdings) h.toJson()]));
    await repo.setSetting('desk_category_plan', jsonEncode({for (final e in categoryPlan.entries) '${e.key}': e.value}));
    await setEnvelopePlanById(repo, categoryPlan);
    await repo.setSetting('desk_scenarios', jsonEncode([for (final s in scenarios) s.toJson()]));
    await repo.setSetting(
        'desk_hints', jsonEncode({'on': hintsOn, 'level': hintLevels, 'shown': hintsShown, 'hidden': hiddenHints.toList()}));
    await repo.setSetting('desk_display_currencies', jsonEncode(displayCurrencies));
    await repo.setSetting('desk_tax_inputs', jsonEncode(taxInputs));
    await repo.setSetting('desk_reminders', jsonEncode(reminders.toList()));
    await repo.setSetting('desk_look', jsonEncode({'theme': themeMode, 'compact': compact, 'scale': textScale}));
    await repo.setSetting('desk_files', jsonEncode({
      'month': autoMonthReport,
      'excel': autoExcel,
      'folder': documentsFolder,
      'last': lastAutoReport,
    }));
    await repo.setSetting('desk_excel', excelOptions);
  }
}
