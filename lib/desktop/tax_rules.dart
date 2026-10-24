/// Personal income tax rules by country, tax year 2026, for estimates only. Each rule set says
/// where it comes from and when it was checked; amounts are in the country's currency (whole units).
library;

class TaxBracket {
  /// Upper bound of the bracket (whole currency units); double.infinity for the last one.
  final double upTo;
  final double rate;
  const TaxBracket(this.upTo, this.rate);
}

class TaxDeadline {
  final int month;
  final int day;

  /// Key of the description (translated).
  final String what;
  const TaxDeadline(this.month, this.day, this.what);
}

class TaxRules {
  final String country;
  final String currency;

  /// 'full' or 'basic' (see CountryInfo.taxTier).
  final String tier;

  /// Tax-free part subtracted before the brackets (yearly, whole units).
  final double allowance;
  final List<TaxBracket> brackets;

  /// Flat rate for non-residents (null = same brackets).
  final double? nonResidentRate;
  final String source;
  final String checked;

  /// The figures are not settled in the sources (shown as "checked partly").
  final bool partial;

  /// Deadlines in the year after the tax year.
  final List<TaxDeadline> deadlines;

  /// Linear-progressive zones (Germany's §32a): marginal rate grows from one bound to the next.
  final bool linearZones;

  const TaxRules({
    required this.country,
    required this.currency,
    required this.tier,
    this.allowance = 0,
    required this.brackets,
    this.nonResidentRate,
    required this.source,
    required this.checked,
    this.partial = false,
    this.deadlines = const [],
    this.linearZones = false,
  });

  /// Yearly tax on [income] (whole units) and the marginal rate.
  (double, double) tax(double income, {bool resident = true, double extraDeductions = 0}) {
    if (!resident && nonResidentRate != null) return (income * nonResidentRate!, nonResidentRate!);
    if (linearZones) return _germany(income);
    final base = (income - allowance - extraDeductions).clamp(0, double.infinity);
    var t = 0.0, prev = 0.0, marg = brackets.first.rate;
    for (final b in brackets) {
      if (base > prev) {
        t += ((base < b.upTo ? base : b.upTo) - prev) * b.rate;
        marg = b.rate;
      }
      prev = b.upTo;
    }
    return (t, marg);
  }

  double taxableBase(double income, {double extraDeductions = 0}) =>
      linearZones ? income : (income - allowance - extraDeductions).clamp(0, double.infinity).toDouble();

  /// Gross yearly income that leaves [net] after this tax (income tax only).
  double grossForNet(double net, {bool resident = true}) {
    var lo = net, hi = net * 3 + 1;
    for (var i = 0; i < 60; i++) {
      final mid = (lo + hi) / 2;
      final (t, _) = tax(mid, resident: resident);
      if (mid - t < net) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return (lo + hi) / 2;
  }

  /// § 32a EStG 2026: 0 up to 12 348 €, then 14 % rising to 23.97 % at 17 799 €, to 42 % at
  /// 69 878 €, 42 % up to 277 825 €, 45 % above (integral of the marginal rate).
  static (double, double) _germany(double x) {
    if (x <= 12348) return (0, 0);
    if (x <= 17799) {
      final y = x - 12348;
      return (y * .14 + (.0997 / 5451) * y * y / 2, .14 + .0997 * y / 5451);
    }
    const t1 = 5451 * .14 + .0997 * 5451 / 2;
    if (x <= 69878) {
      final z = x - 17799;
      return (t1 + z * .2397 + (.1803 / 52079) * z * z / 2, .2397 + .1803 * z / 52079);
    }
    const t2 = t1 + 52079 * .2397 + .1803 * 52079 / 2;
    if (x <= 277825) return (t2 + (x - 69878) * .42, .42);
    return (t2 + (277825 - 69878) * .42 + (x - 277825) * .45, .45);
  }
}

const _checked = '24.10.2026';
const kzMrp2026 = 4325.0;

const taxRules = <String, TaxRules>{
  'RU': TaxRules(
    country: 'RU',
    currency: 'RUB',
    tier: 'full',
    brackets: [
      TaxBracket(2400000, .13),
      TaxBracket(5000000, .15),
      TaxBracket(20000000, .18),
      TaxBracket(50000000, .20),
      TaxBracket(double.infinity, .22),
    ],
    nonResidentRate: .30,
    source: 'nalog.gov.ru · НК РФ ст. 207, 214.2, 224',
    checked: _checked,
    deadlines: [TaxDeadline(4, 30, 'd_dl_ru_return'), TaxDeadline(7, 15, 'd_dl_ru_pay'), TaxDeadline(12, 1, 'd_dl_ru_notice')],
  ),
  'CN': TaxRules(
    country: 'CN',
    currency: 'CNY',
    tier: 'full',
    allowance: 60000,
    brackets: [
      TaxBracket(36000, .03),
      TaxBracket(144000, .10),
      TaxBracket(300000, .20),
      TaxBracket(420000, .25),
      TaxBracket(660000, .30),
      TaxBracket(960000, .35),
      TaxBracket(double.infinity, .45),
    ],
    source: 'chinatax.gov.cn',
    checked: _checked,
    deadlines: [TaxDeadline(3, 1, 'd_dl_cn_open'), TaxDeadline(6, 30, 'd_dl_cn_close')],
  ),
  'KZ': TaxRules(
    country: 'KZ',
    currency: 'KZT',
    tier: 'full',
    allowance: 360 * kzMrp2026,
    brackets: [TaxBracket(8500 * kzMrp2026, .10), TaxBracket(double.infinity, .15)],
    source: 'kgd.gov.kz · adilet.zan.kz',
    checked: _checked,
    partial: true,
  ),
  'DE': TaxRules(
    country: 'DE',
    currency: 'EUR',
    tier: 'full',
    brackets: [
      TaxBracket(12348, 0),
      TaxBracket(17799, .14),
      TaxBracket(69878, .2397),
      TaxBracket(277825, .42),
      TaxBracket(double.infinity, .45),
    ],
    linearZones: true,
    source: 'bundesfinanzministerium.de · § 32a EStG',
    checked: _checked,
    deadlines: [TaxDeadline(7, 31, 'd_dl_de_return')],
  ),
  'NL': TaxRules(
    country: 'NL',
    currency: 'EUR',
    tier: 'full',
    brackets: [TaxBracket(38883, .3575), TaxBracket(78426, .3756), TaxBracket(double.infinity, .495)],
    source: 'belastingdienst.nl',
    checked: _checked,
    deadlines: [TaxDeadline(5, 1, 'd_dl_nl_return')],
  ),
  'US': TaxRules(
    country: 'US',
    currency: 'USD',
    tier: 'basic',
    allowance: 16100,
    brackets: [
      TaxBracket(12400, .10),
      TaxBracket(50400, .12),
      TaxBracket(105700, .22),
      TaxBracket(201775, .24),
      TaxBracket(256225, .32),
      TaxBracket(640600, .35),
      TaxBracket(double.infinity, .37),
    ],
    source: 'irs.gov · federal, single filer',
    checked: _checked,
    deadlines: [TaxDeadline(4, 15, 'd_dl_us_return')],
  ),
  'GB': TaxRules(
    country: 'GB',
    currency: 'GBP',
    tier: 'basic',
    allowance: 12570,
    brackets: [TaxBracket(37700, .20), TaxBracket(112570, .40), TaxBracket(double.infinity, .45)],
    source: 'gov.uk · England, Wales, NI',
    checked: _checked,
    deadlines: [TaxDeadline(1, 31, 'd_dl_gb_return')],
  ),
  'PL': TaxRules(
    country: 'PL',
    currency: 'PLN',
    tier: 'basic',
    allowance: 30000,
    brackets: [TaxBracket(90000, .12), TaxBracket(double.infinity, .32)],
    source: 'podatki.gov.pl',
    checked: _checked,
    deadlines: [TaxDeadline(4, 30, 'd_dl_pl_return')],
  ),
  'ES': TaxRules(
    country: 'ES',
    currency: 'EUR',
    tier: 'basic',
    allowance: 5550,
    brackets: [
      TaxBracket(12450, .19),
      TaxBracket(20200, .24),
      TaxBracket(35200, .30),
      TaxBracket(60000, .37),
      TaxBracket(300000, .45),
      TaxBracket(double.infinity, .47),
    ],
    source: 'agenciatributaria.gob.es · state + typical region',
    checked: _checked,
    partial: true,
    deadlines: [TaxDeadline(6, 30, 'd_dl_es_return')],
  ),
  'GE': TaxRules(
    country: 'GE',
    currency: 'GEL',
    tier: 'basic',
    brackets: [TaxBracket(double.infinity, .20)],
    source: 'rs.ge',
    checked: _checked,
    deadlines: [TaxDeadline(3, 31, 'd_dl_ge_return')],
  ),
};
