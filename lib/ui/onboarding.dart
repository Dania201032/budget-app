import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'data_screens.dart';
import 'lock_screen.dart';

/// Countries offered at the first start and in Settings, in this order.
const countries = ['CN', 'RU', 'KZ', 'DE', 'NL'];
const countryFlags = {'CN': '🇨🇳', 'RU': '🇷🇺', 'KZ': '🇰🇿', 'DE': '🇩🇪', 'NL': '🇳🇱'};
const _countryDefaultLanguage = {'CN': 'zh', 'RU': 'ru', 'KZ': 'kk', 'DE': 'de', 'NL': 'nl'};

/// First start: country -> language -> app lock offer -> short guide.
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({super.key});

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  int _step = 0;
  String _country = 'CN';
  late String _lang;

  @override
  void initState() {
    super.initState();
    _lang = currentLanguage;
    _country = context.read<AppState>().country;
  }

  void _setLang(String l) => setState(() {
        _lang = l;
        currentLanguage = l;
      });

  Future<void> _finish() async {
    await context.read<AppState>().completeOnboarding(country: _country, lang: _lang);
  }

  @override
  Widget build(BuildContext context) {
    return switch (_step) {
      0 => _ChoicePage(
          title: tr('choose_country'),
          subtitle: tr('choose_country_sub'),
          options: [for (final c in countries) (c, '${countryFlags[c]}  ${tr('country_$c')}')],
          selected: _country,
          onSelect: (c) => setState(() {
            _country = c;
            // Suggest the country's language unless the phone language is already supported.
            if (!supportedLanguages.contains(WidgetsBinding.instance.platformDispatcher.locale.languageCode)) {
              _setLang(_countryDefaultLanguage[c]!);
            }
          }),
          onNext: () => setState(() => _step = 1),
          footer: TextButton.icon(
            icon: const Icon(Icons.restore),
            label: Text(tr('have_backup')),
            onPressed: () => restoreFromBackupFile(context),
          ),
        ),
      1 => _ChoicePage(
          title: tr('choose_language'),
          options: [for (final e in languageNames.entries) (e.key, e.value)],
          selected: _lang,
          onSelect: _setLang,
          onBack: () => setState(() => _step = 0),
          onNext: () => setState(() => _step = 2),
        ),
      2 => _LockOfferPage(onBack: () => setState(() => _step = 1), onNext: () => setState(() => _step = 3)),
      _ => GuideScreen(onFinish: _finish),
    };
  }
}

class _ChoicePage extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<(String, String)> options;
  final String selected;
  final ValueChanged<String> onSelect;
  final VoidCallback onNext;
  final VoidCallback? onBack;
  final Widget? footer;

  const _ChoicePage({
    required this.title,
    this.subtitle,
    required this.options,
    required this.selected,
    required this.onSelect,
    required this.onNext,
    this.onBack,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(leading: onBack == null ? null : BackButton(onPressed: onBack)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('welcome'), style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.primary)),
            const SizedBox(height: 8),
            Text(title, style: theme.textTheme.headlineSmall),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(subtitle!, style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: 24),
            // Scrolls on small screens: five countries, six languages.
            Expanded(
              child: ListView(children: [
                for (final (value, label) in options)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Card(
                      color: value == selected ? theme.colorScheme.primaryContainer : null,
                      child: ListTile(
                        title: Text(label, style: theme.textTheme.titleMedium),
                        trailing: value == selected ? const Icon(Icons.check_circle) : null,
                        onTap: () => onSelect(value),
                      ),
                    ),
                  ),
              ]),
            ),
            ?footer,
            FilledButton(onPressed: onNext, child: Text(tr('next'))),
          ]),
        ),
      ),
    );
  }
}


/// First start, after the language: an offer to protect the app with a PIN (and the fingerprint);
/// "Not now" leaves it off — it can be turned on later in Settings.
class _LockOfferPage extends StatefulWidget {
  final VoidCallback onBack;
  final VoidCallback onNext;
  const _LockOfferPage({required this.onBack, required this.onNext});

  @override
  State<_LockOfferPage> createState() => _LockOfferPageState();
}

class _LockOfferPageState extends State<_LockOfferPage> {
  bool _bioAvailable = false;

  @override
  void initState() {
    super.initState();
    appLock.addListener(_changed);
    appLock.biometricsAvailable().then((v) {
      if (mounted) setState(() => _bioAvailable = v);
    });
  }

  @override
  void dispose() {
    appLock.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  Future<void> _setPin() async {
    final pin = await askNewPin(context);
    if (pin == null) return;
    await appLock.setPin(pin);
    if (_bioAvailable) await appLock.setBiometrics(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final on = appLock.enabled;
    return Scaffold(
      appBar: AppBar(leading: BackButton(onPressed: widget.onBack)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('welcome'), style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.primary)),
            const SizedBox(height: 8),
            Text(tr('lock_offer_t'), style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(tr('lock_offer_b'), style: theme.textTheme.bodyMedium),
            const SizedBox(height: 24),
            if (on) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.lock_outline, color: theme.colorScheme.primary),
                title: Text(tr('lock_offer_done')),
              ),
              if (_bioAvailable)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: appLock.biometrics,
                  onChanged: appLock.setBiometrics,
                  title: Text(tr('lock_bio')),
                ),
            ],
            const Spacer(),
            if (on)
              FilledButton(onPressed: widget.onNext, child: Text(tr('next')))
            else ...[
              FilledButton.icon(
                icon: const Icon(Icons.lock_outline),
                label: Text(tr('lock_offer_yes')),
                onPressed: _setPin,
              ),
              const SizedBox(height: 8),
              TextButton(onPressed: widget.onNext, child: Text(tr('lock_offer_no'))),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Up to 5 swipeable steps. From onboarding: [onFinish]; from settings: [closeOnFinish].
class GuideScreen extends StatefulWidget {
  final Future<void> Function()? onFinish;
  final bool closeOnFinish;
  const GuideScreen({super.key, this.onFinish, this.closeOnFinish = false});

  @override
  State<GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends State<GuideScreen> {
  final _pages = PageController();
  int _index = 0;

  static const _steps = [
    ('guide1', Icons.today),
    ('guide2', Icons.auto_awesome),
    ('guide3', Icons.call_split),
    ('guide4', Icons.savings_outlined),
    ('guide5', Icons.cloud_done_outlined),
  ];

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _done() async {
    if (widget.onFinish != null) await widget.onFinish!();
    if (widget.closeOnFinish && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = _index == _steps.length - 1;
    return Scaffold(
      appBar: AppBar(actions: [if (!last) TextButton(onPressed: _done, child: Text(tr('skip')))]),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: PageView(
              controller: _pages,
              onPageChanged: (i) => setState(() => _index = i),
              children: [
                for (final (key, icon) in _steps)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      CircleAvatar(
                        radius: 48,
                        backgroundColor: theme.colorScheme.primaryContainer,
                        child: Icon(icon, size: 48, color: theme.colorScheme.primary),
                      ),
                      const SizedBox(height: 32),
                      Text(tr('${key}_t'), style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      Text(tr('${key}_b'), style: theme.textTheme.bodyLarge, textAlign: TextAlign.center),
                    ]),
                  ),
              ],
            ),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < _steps.length; i++)
              Container(
                margin: const EdgeInsets.all(4),
                width: i == _index ? 20 : 8,
                height: 8,
                decoration: BoxDecoration(
                  color: i == _index ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
          ]),
          Padding(
            padding: const EdgeInsets.all(24),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: last
                    ? _done
                    : () => _pages.nextPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut),
                child: Text(last ? tr('start') : tr('next')),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
