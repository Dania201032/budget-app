import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/currencies.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../ui/ledger.dart';
import '../ui/sync_screen.dart';
import 'kit.dart';
import 'profile.dart';
import 'shell.dart' show AbacusMark;
import 'taxes_page.dart' show countryName;

/// A country from the full list (search by name or code).
Future<String?> pickCountry(BuildContext context, {Set<String> exclude = const {}}) => showDialog<String>(
      context: context,
      builder: (c) {
        var q = '';
        return StatefulBuilder(builder: (c, set) {
          final list = appCountries
              .where((x) => !exclude.contains(x.code))
              .where((x) => q.isEmpty || countryName(x.code).toLowerCase().contains(q.toLowerCase()) || x.code.toLowerCase() == q.toLowerCase())
              .toList();
          return AlertDialog(
            title: Text(tr('d_add_country')),
            content: SizedBox(
              width: 420,
              height: 420,
              child: Column(children: [
                TextField(autofocus: true, decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: tr('d_find_country')), onChanged: (v) => set(() => q = v)),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView(children: [
                    for (final x in list)
                      ListTile(
                        title: Text(countryName(x.code)),
                        subtitle: Text('${x.currency} · ${tr('d_tier_${x.taxTier}')}'),
                        trailing: Text(x.code, style: mono(size: 12)),
                        onTap: () => Navigator.pop(c, x.code),
                      ),
                  ]),
                ),
              ]),
            ),
          );
        });
      },
    );

/// Account type for a bank name, so payment notifications and statements find their account.
String bankType(String name) => switch (name.toLowerCase().replaceAll(RegExp(r'[\s-]'), '')) {
      'alipay' => 'alipay',
      'wechatpay' || 'wechat' => 'wechat',
      'сбер' => 'sber',
      'втб' => 'vtb',
      'тбанк' => 'tbank',
      'точка' => 'tochka',
      'kaspi' => 'kaspi',
      'halyk' => 'halyk',
      'dkb' => 'dkb',
      'sparkasse' => 'sparkasse',
      'ing' => 'ing',
      'bunq' => 'bunq',
      'n26' => 'n26',
      'revolut' => 'revolut',
      'paypal' => 'paypal',
      _ => 'bank',
    };

class FirstRunPage extends StatefulWidget {
  const FirstRunPage({super.key});
  @override
  State<FirstRunPage> createState() => _FirstRunPageState();
}

class _FirstRunPageState extends State<FirstRunPage> {
  final picked = <MyCountry>[];
  String? base;
  final banksOff = <String>{};
  final banksOn = <String>{};
  String q = '';
  final search = TextEditingController();
  bool busy = false;

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>();
    final guess = countryByCode.containsKey(s.country) ? s.country : 'CN';
    picked.add(MyCountry(guess, true));
  }

  String get home => picked.where((c) => c.home).map((c) => c.code).firstOrNull ?? (picked.isEmpty ? 'CN' : picked.first.code);

  List<String> get currencies => {for (final c in picked) countryByCode[c.code]!.currency}.toList();

  String get baseCurrency => base != null && currencies.contains(base) ? base! : countryByCode[home]!.currency;

  bool bankOn(String code, String name, int i) {
    final k = '$code:$name';
    return banksOn.contains(k) || (i < 2 && !banksOff.contains(k));
  }

  List<(String, String)> get chosenBanks => [
        for (final c in picked)
          for (var i = 0; i < countryByCode[c.code]!.banks.length; i++)
            if (bankOn(c.code, countryByCode[c.code]!.banks[i], i)) (countryByCode[c.code]!.banks[i], countryByCode[c.code]!.currency),
      ];

  Future<void> _finish() async {
    if (busy || picked.isEmpty) return;
    setState(() => busy = true);
    final s = context.read<AppState>();
    await s.completeDesktopSetup(
      home: home,
      base: baseCurrency,
      accounts: [for (final (name, cur) in chosenBanks) (name, cur, bankType(name))],
      countriesJson: jsonEncode([for (final c in picked) c.toJson()]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final info = countryByCode[home]!;
    final muted = Ledger.mutedOf(context);
    final options = appCountries
        .where((c) => !picked.any((p) => p.code == c.code))
        .where((c) => q.isEmpty || countryName(c.code).toLowerCase().contains(q.toLowerCase()))
        .toList();
    final dates = {'dmy.': '24.10.2026', 'dmy/': '24/10/2026', 'dmy-': '24-10-2026', 'mdy': '10/24/2026', 'iso': '2026-10-24', 'ymd/': '2026/10/24', 'ymd.': '2026.10.24'};
    final numbers = {'space': '1 234,50', 'dot': '1.234,50', 'comma': '1,234.50'};

    Widget step(int n, String title, String lead, List<Widget> children) => Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: Ledger.emerald, borderRadius: BorderRadius.circular(13)),
                child: Text('$n', style: mono(size: 13, weight: FontWeight.w600, color: Ledger.paper)),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(title, style: sans(context, size: 18, weight: FontWeight.w600))),
            ]),
            const SizedBox(height: 6),
            Text(lead, style: sans(context, size: 13.5, color: muted, height: 1.45)),
            const SizedBox(height: 12),
            ...children,
          ]),
        );

    return Scaffold(
      body: Column(children: [
        Container(
          color: sidebarOf(context),
          padding: const EdgeInsets.fromLTRB(32, 18, 32, 18),
          child: Wrap(spacing: 16, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, alignment: WrapAlignment.spaceBetween, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              const AbacusMark(size: 34),
              const SizedBox(width: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('d_welcome'), style: sans(context, size: 22, weight: FontWeight.w600)),
                  Text(tr('d_welcome_sub'), style: sans(context, size: 13, color: muted)),
                ]),
              ),
            ]),
            Wrap(spacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
              DeskButton(tr('d_have_phone'), onTap: () async {
                final joined = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const SyncScreen(closeWhenJoined: true)));
                if (joined == true) await _finish();
              }),
            ]),
          ]),
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(32, 24, 32, 48), children: [
            // First of all, before any text the person may not read: the language, named in itself.
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Ledger.shadeOf(context), borderRadius: BorderRadius.circular(10)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.language, size: 20, color: Ledger.accentOf(context)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Language · Язык · 语言 · Тіл · Sprache · Taal',
                        style: sans(context, size: 14, weight: FontWeight.w600)),
                  ),
                ]),
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final l in supportedLanguages)
                    ChoiceChip(
                      label: Text(languageNames[l]!, style: sans(context, size: 14, weight: FontWeight.w500, color: l == currentLanguage ? Ledger.paper : null)),
                      selected: l == currentLanguage,
                      selectedColor: Ledger.emerald,
                      showCheckmark: false,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      onSelected: (_) => s.setLanguage(l),
                    ),
                ]),
              ]),
            ),
            const SizedBox(height: 20),
            SplitRow([
              (
                3,
                620,
                Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  step(1, tr('d_fr_countries'), tr('d_fr_countries_lead'), [
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final c in picked)
                        Pill(
                          '${countryName(c.code)} · ${c.home ? tr('d_live') : tr('d_income_role')}',
                          selected: c.home,
                          onTap: () => setState(() {
                            final i = picked.indexOf(c);
                            if (!c.home) {
                              for (var k = 0; k < picked.length; k++) {
                                picked[k] = MyCountry(picked[k].code, false);
                              }
                              picked[i] = MyCountry(c.code, true);
                            } else {
                              picked[i] = MyCountry(c.code, false);
                            }
                          }),
                          trailing: InkWell(
                            onTap: () => setState(() => picked.remove(c)),
                            child: Icon(Icons.close, size: 14, color: c.home ? Ledger.paper : muted),
                          ),
                        ),
                    ]),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: 420,
                      child: TextField(
                        controller: search,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: clearIcon(search, () => setState(() => q = '')),
                          hintText: tr('d_find_country'),
                          isDense: true,
                        ),
                        onChanged: (v) => setState(() => q = v),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      for (final c in options)
                        Pill(countryName(c.code), onTap: () => setState(() => picked.add(MyCountry(c.code, picked.every((p) => !p.home))))),
                    ]),
                    const SizedBox(height: 8),
                    Text(tr('d_fr_roles'), style: sans(context, size: 12.5, color: muted)),
                  ]),
                  const SizedBox(height: 16),
                  step(2, tr('d_fr_currencies'), tr('d_fr_currencies_lead'), [
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final c in currencies)
                        Pill('${currencySymbol(c)} $c${c == baseCurrency ? ' · ${tr('d_main')}' : ''}', selected: c == baseCurrency, onTap: () => setState(() => base = c)),
                    ]),
                  ]),
                  const SizedBox(height: 16),
                  step(3, tr('d_fr_banks'), tr('d_fr_banks_lead'), [
                    for (final c in picked) ...[
                      Text(countryName(c.code), style: sans(context, size: 13, weight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        for (var i = 0; i < countryByCode[c.code]!.banks.length; i++)
                          () {
                            final name = countryByCode[c.code]!.banks[i];
                            final on = bankOn(c.code, name, i);
                            return Pill(name, selected: on, onTap: () => setState(() {
                                  final k = '${c.code}:$name';
                                  if (on) {
                                    banksOn.remove(k);
                                    banksOff.add(k);
                                  } else {
                                    banksOff.remove(k);
                                    banksOn.add(k);
                                  }
                                }));
                          }(),
                      ]),
                      const SizedBox(height: 12),
                    ],
                    Text(tr('d_fr_banks_note'), style: sans(context, size: 12.5, color: muted)),
                  ]),
                  const SizedBox(height: 16),
                  step(4, tr('d_fr_formats'), tr('d_fr_formats_lead'), [
                    AutoGrid(minWidth: 170, spacing: 10, children: [
                      Kpi(tr('d_fr_date'), dates[info.dateStyle]!),
                      Kpi(tr('d_fr_numbers'), numbers[info.numberStyle]!),
                      Kpi(tr('d_fr_week'), info.weekStartsSunday ? tr('d_fr_sunday') : tr('d_fr_monday')),
                    ]),
                  ]),
                  const SizedBox(height: 16),
                  step(5, tr('d_fr_taxes'), tr('d_fr_taxes_lead'), [
                    for (final c in picked)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(children: [
                          SizedBox(width: 180, child: Text('${countryName(c.code)} · ${c.home ? tr('d_live') : tr('d_income_role')}', style: sans(context, size: 13.5, weight: FontWeight.w600))),
                          switch (countryByCode[c.code]!.taxTier) {
                            'full' => tagGood(context, tr('d_tier_full')),
                            'basic' => tagPlain(context, tr('d_tier_basic')),
                            _ => tagWarn(context, tr('d_tier_soon')),
                          },
                          const SizedBox(width: 10),
                          Expanded(child: Text(tr('d_tier_${countryByCode[c.code]!.taxTier}_d'), style: sans(context, size: 12.5, color: muted))),
                        ]),
                      ),
                  ]),
                  const SizedBox(height: 16),
                  Wrap(alignment: WrapAlignment.end, spacing: 10, children: [
                    DeskButton(tr('skip'), onTap: busy ? null : _finish),
                    DeskButton(tr('d_fr_done'), primary: true, onTap: busy || picked.isEmpty ? null : _finish),
                  ]),
                ]),
              ),
              (
                1,
                280,
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(color: Ledger.emerald, borderRadius: BorderRadius.circular(10)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text(tr('d_fr_summary'), style: sans(context, size: 16, weight: FontWeight.w600, color: Ledger.paper)),
                    for (final (k, v) in [
                      (tr('d_fr_countries'), picked.map((c) => countryName(c.code) + (c.home ? ' (${tr('d_live')})' : '')).join(', ')),
                      (tr('d_base_currency'), '$baseCurrency · ${currencySymbol(baseCurrency)}'),
                      (tr('d_fr_banks'), chosenBanks.isEmpty ? tr('d_fr_manual_only') : chosenBanks.map((b) => b.$1).join(', ')),
                      (tr('d_fr_formats'), '${dates[info.dateStyle]} · ${numbers[info.numberStyle]}'),
                      (tr('d_fr_taxes'), picked.map((c) => '${countryName(c.code)}: ${tr('d_tier_${countryByCode[c.code]!.taxTier}')}').join('; ')),
                    ])
                      Container(
                        margin: const EdgeInsets.only(top: 10),
                        padding: const EdgeInsets.only(top: 10),
                        decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFF2E5A52)))),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(k, style: sans(context, size: 12, color: const Color(0xFFA9D6C3))),
                          Text(v, style: sans(context, size: 14, color: Ledger.paper)),
                        ]),
                      ),
                    const SizedBox(height: 14),
                    Text(tr('d_fr_privacy'), style: sans(context, size: 12, color: const Color(0xFFA9D6C3), height: 1.45)),
                  ]),
                ),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }
}
