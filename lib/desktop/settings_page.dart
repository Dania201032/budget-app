import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/currencies.dart';
import '../domain/money.dart';
import '../l10n/strings.dart';
import '../ui/lock_screen.dart' show appLock;
import '../state/app_state.dart';
import '../ui/data_screens.dart' show BackupScreen, SheetImportScreen;
import '../ui/home_screen.dart' show chooseDailyLimitMode;
import '../ui/ledger.dart';
import '../ui/lock_screen.dart' show LockSettingsScreen;
import '../ui/settings_screen.dart' show CategoriesScreen, RatesScreen, accountDialog, chooseLanguage, pickCurrency;
import '../ui/sync_screen.dart';
import '../ui/widgets.dart' show askAmount;
import 'documents_page.dart' show documentsDir, openPath;
import 'first_run_page.dart' show pickCountry;
import 'kit.dart';
import 'profile.dart';
import 'shell.dart';
import 'taxes_page.dart' show countryName;

class DeskSettingsPage extends StatefulWidget {
  const DeskSettingsPage({super.key});
  @override
  State<DeskSettingsPage> createState() => _DeskSettingsPageState();
}

class _DeskSettingsPageState extends State<DeskSettingsPage> {
  final scroll = ScrollController();
  final keys = {for (final k in _sections) k: GlobalKey()};

  static const _sections = ['general', 'accounts', 'currencies', 'categories', 'hints', 'sync', 'files', 'look', 'security', 'keys', 'about'];

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  void _jump(String k) {
    final c = keys[k]?.currentContext;
    if (c != null) Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 250));
  }

  Future<void> _push(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final desk = context.watch<DeskController>();
    final p = desk.profile;
    final muted = Ledger.mutedOf(context);
    Widget section(String k, String title, List<Widget> rows, {String? lead, Widget? action, bool accent = false}) => Container(
          key: keys[k],
          margin: const EdgeInsets.only(bottom: 20),
          child: Panel(
            borderColor: accent ? Ledger.accentOf(context) : null,
            title: title,
            subtitle: lead,
            trailing: action,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
          ),
        );
    Widget row(String label, String? sub, Widget control) => Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: Ledger.trackOf(context)))),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 24,
            runSpacing: 8,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 240, maxWidth: 520),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: sans(context, size: 14, weight: FontWeight.w500)),
                  if (sub != null) Text(sub, style: sans(context, size: 12.5, color: muted)),
                ]),
              ),
              control,
            ],
          ),
        );

    final content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      section('general', tr('d_set_general'), [
        row(tr('d_base_currency'), tr('d_base_currency_sub'),
            DeskButton('${currencySymbol(s.baseCurrency)} ${s.baseCurrency}', onTap: () async {
              final c = await pickCurrency(context, selected: s.baseCurrency);
              if (c != null) await s.setBaseCurrency(c);
            })),
        row(tr('d_my_countries'), tr('d_my_countries_sub'), Wrap(spacing: 6, runSpacing: 6, children: [
          for (final c in p.countries)
            Pill('${countryName(c.code)} · ${c.home ? tr('d_live') : tr('d_income_role')}',
                selected: c.home,
                onTap: () {
                  final i = p.countries.indexOf(c);
                  if (!c.home) {
                    p.countries = [for (final x in p.countries) MyCountry(x.code, false)];
                    p.countries[i] = MyCountry(c.code, true);
                    s.setCountry(c.code);
                  } else {
                    p.countries[i] = MyCountry(c.code, false);
                  }
                  desk.saveProfile();
                },
                trailing: p.countries.length > 1
                    ? InkWell(
                        onTap: () {
                          p.countries.remove(c);
                          desk.saveProfile();
                        },
                        child: Icon(Icons.close, size: 14, color: c.home ? Ledger.paper : muted),
                      )
                    : null),
          Pill(tr('d_add_country'), dashed: true, onTap: () async {
            final code = await pickCountry(context, exclude: {for (final c in p.countries) c.code});
            if (code == null) return;
            p.countries.add(MyCountry(code, p.countries.isEmpty));
            await desk.saveProfile();
          }),
        ])),
        row(tr('language'), tr('d_language_sub'), DeskButton(languageNames[currentLanguage]!, onTap: () => chooseLanguage(context))),
        row(tr('d_daily_limit_mode'), tr('d_daily_limit_mode_sub'),
            DeskButton(s.fixedDailyLimit ? tr('d_fixed') : tr('d_even'), onTap: () => chooseDailyLimitMode(context))),
      ]),
      section('accounts', tr('d_accounts'), [
        for (final a in s.accounts)
          row('${s.accountName(a)} · ${a.currency}', s.balances[a.id] == null ? tr('d_no_balance') : formatMoney(s.balances[a.id]!, a.currency),
              Wrap(spacing: 6, children: [
                DeskButton(tr('d_set_balance'), small: true, onTap: () async {
                  final v = await askAmount(context, title: s.accountName(a), suffix: a.currency);
                  if (v != null) await s.setAccountBalance(a, v);
                }),
                DeskButton(tr('d_edit'), small: true, onTap: () async {
                  final r = await accountDialog(context, title: tr('account'), name: a.name, currency: a.currency);
                  if (r != null) await s.updateAccount(a, name: r.$1, currency: r.$2);
                }),
              ])),
      ], action: DeskButton(tr('d_add_account'), icon: Icons.add, onTap: () async {
        final r = await accountDialog(context, title: tr('new_account'), currency: s.baseCurrency);
        if (r != null) await s.addAccount(r.$1, r.$2);
      })),
      section('currencies', tr('d_currencies'), [
        row(tr('d_display_currencies'), tr('d_display_currencies_sub'), Wrap(spacing: 6, runSpacing: 6, children: [
          for (final c in p.displayCurrencies)
            Pill('${currencySymbol(c)} $c',
                selected: c == s.baseCurrency,
                trailing: c == s.baseCurrency
                    ? null
                    : InkWell(
                        onTap: () {
                          p.displayCurrencies.remove(c);
                          desk.saveProfile(refold: false);
                        },
                        child: Icon(Icons.close, size: 14, color: muted),
                      )),
          Pill(tr('d_add_currency'), dashed: true, onTap: () async {
            final c = await pickCurrency(context);
            if (c != null && !p.displayCurrencies.contains(c)) {
              p.displayCurrencies.add(c);
              await desk.saveProfile(refold: false);
            }
          }),
        ])),
        row(tr('rates'), tr('d_rates_sub'), DeskButton(tr('d_open'), onTap: () => _push(const RatesScreen()))),
      ]),
      section('categories', tr('categories'), [
        row(tr('d_edit_categories'), tr('d_edit_categories_sub'), DeskButton(tr('d_open'), onTap: () => _push(const CategoriesScreen()))),
        row(tr('d_category_plan'), tr('d_category_plan_sub'), DeskButton(tr('d_open'), onTap: () => desk.go(DeskPages.forecast))),
      ]),
      section('hints', tr('d_hints'), [
        row(tr('d_hints_count'), null,
            Choice(options: [(2, '2'), (4, '4'), (6, '6'), (99, tr('d_all'))], value: p.hintsShown, onChanged: (v) {
              p.hintsShown = v;
              desk.saveProfile(refold: false);
            }, dense: true)),
        for (final r in hintRules)
          row(
            tr('d_hint_${r.key}'),
            '${tr('d_hint_${r.key}_d')} · ${tr('d_weight_${r.key}')}',
            Row(mainAxisSize: MainAxisSize.min, children: [
              Opacity(
                opacity: p.hintOn(r.key) ? 1 : .45,
                child: Choice(
                  options: [for (var i = 0; i < r.levels.length; i++) (i, tr('d_lvl_${r.key}_$i'))],
                  value: p.hintLevels[r.key] ?? r.defaultLevel,
                  onChanged: (v) {
                    p.hintLevels[r.key] = v;
                    desk.saveProfile();
                  },
                  dense: true,
                ),
              ),
              const SizedBox(width: 8),
              Toggle(p.hintOn(r.key), onChanged: (v) {
                p.hintsOn[r.key] = v;
                desk.saveProfile();
              }),
            ]),
          ),
        row(tr('d_hidden_hints'), tr('d_hidden_hints_sub', [p.hiddenHints.length]),
            DeskButton(tr('d_show_hidden'), onTap: p.hiddenHints.isEmpty
                ? null
                : () {
                    p.hiddenHints.clear();
                    desk.saveProfile();
                  })),
      ], lead: tr('d_hints_lead'), accent: true),
      section('sync', tr('d_sync'), [
        ListenableBuilder(
          listenable: s.sync,
          builder: (context, _) => row(
            s.sync.enabled ? tr('d_sync_on') : tr('d_sync_off'),
            [
              ?s.sync.folderLabel,
              if (s.sync.enabled) s.sync.lastSync == null ? tr('d_sync_never') : tr('d_sync_ago', [whenText(s.sync.lastSync!)]),
              if (s.sync.otherDeviceSeen != null) tr('d_phone_seen', [whenText(s.sync.otherDeviceSeen!)]),
              if (s.sync.lastCheck != null) tr('d_sync_checked', [whenText(s.sync.lastCheck!)]),
              if (s.sync.lastError != null) '${tr('d_sync_failed')}: ${s.sync.lastError}',
            ].join('\n'),
            Wrap(spacing: 6, children: [
              DeskButton(tr('d_open'), onTap: () => _push(const SyncScreen())),
              if (s.sync.enabled) DeskButton(s.sync.busy ? tr('d_syncing') : tr('d_sync_now'), primary: true, onTap: s.sync.busy ? null : s.syncNow),
            ]),
          ),
        ),
        row(tr('import_excel'), tr('import_excel_sub'), DeskButton(tr('d_open'), onTap: () => _push(const SheetImportScreen()))),
        row(tr('d_backups'), tr('d_backups_sub'), DeskButton(tr('d_open'), onTap: () => _push(const BackupScreen()))),
      ]),
      section('files', tr('d_files'), [
        row(tr('d_docs_folder'), p.documentsFolder ?? tr('d_docs_folder_default'), Wrap(spacing: 6, children: [
          DeskButton(tr('d_change'), onTap: () async {
            final path = await appLock.whileInSystemScreen(() => FilePicker.getDirectoryPath(dialogTitle: tr('d_docs_folder')));
            if (path == null) return;
            p.documentsFolder = path;
            await desk.saveProfile(refold: false);
          }),
          DeskButton(tr('d_open'), onTap: () async => openPath((await documentsDir(desk)).path)),
        ])),
        row(tr('d_auto_month'), tr('d_auto_month_sub'), Toggle(p.autoMonthReport, onChanged: (v) {
          p.autoMonthReport = v;
          desk.saveProfile(refold: false);
        })),
        row(tr('d_x_auto'), tr('d_x_auto_d'), Toggle(p.autoExcel, onChanged: (v) {
          p.autoExcel = v;
          desk.saveProfile(refold: false);
        })),
      ]),
      section('look', tr('d_look'), [
        row(tr('d_theme'), null, Choice(
          options: [('light', tr('d_theme_light')), ('dark', tr('d_theme_dark')), ('system', tr('d_theme_system'))],
          value: p.themeMode,
          onChanged: (v) {
            p.themeMode = v;
            desk.saveProfile(refold: false);
          },
          dense: true,
        )),
        row(tr('d_density'), tr('d_density_sub'), Choice(
          options: [(false, tr('d_normal')), (true, tr('d_compact'))],
          value: p.compact,
          onChanged: (v) {
            p.compact = v;
            desk.saveProfile(refold: false);
          },
          dense: true,
        )),
        row(tr('d_text_size'), null, Choice(
          options: [(0.9, '90%'), (1.0, '100%'), (1.1, '110%'), (1.25, '125%')],
          value: p.textScale,
          onChanged: (v) {
            p.textScale = v;
            desk.saveProfile(refold: false);
          },
          dense: true,
        )),
      ], lead: tr('d_this_computer')),
      section('security', tr('d_security'), [
        row(tr('d_app_lock'), tr('d_app_lock_sub'), DeskButton(tr('d_open'), onTap: () => _push(const LockSettingsScreen()))),
      ]),
      section('keys', tr('d_keys'), [
        for (final (k, what) in [
          ('1 … 7', tr('d_k_pages')),
          ('N', tr('d_new_expense')),
          ('I', tr('d_new_income')),
          ('/', tr('d_search_ops')),
          ('Ctrl K', tr('d_find_or_do')),
          ('J / K', tr('d_k_move')),
          ('X', tr('d_k_check')),
          ('Enter', tr('d_k_confirm')),
          ('E', tr('d_k_edit')),
          ('Del', tr('delete')),
          ('Ctrl S', tr('d_k_save_excel')),
        ])
          row(what, null, KeyCap(k)),
      ]),
      section('about', tr('d_about'), [
        row(tr('d_app_name'), tr('d_about_sub'), Wrap(spacing: 6, children: [
          DeskButton(tr('d_check_updates'), onTap: () => openPath('https://github.com/Dania201032/budget-app/releases')),
        ])),
      ]),
    ]);

    return DeskPage(
      title: tr('settings'),
      subtitle: tr('d_settings_sub'),
      controller: scroll,
      children: [
        SplitRow([
          (
            1,
            200,
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final k in _sections)
                InkWell(
                  onTap: () => _jump(k),
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    decoration: k == 'hints' ? BoxDecoration(color: Ledger.withinOf(context), borderRadius: BorderRadius.circular(6)) : null,
                    child: Text(tr('d_set_$k'), style: sans(context, size: 13.5, weight: k == 'hints' ? FontWeight.w600 : FontWeight.w400)),
                  ),
                ),
            ]),
          ),
          (4, 560, content),
        ]),
      ],
    );
  }
}

