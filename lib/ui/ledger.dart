import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'motion.dart';

/// «Тетрадь» (ledger) look: paper, ink, hairline rules, emerald accent, monospaced figures.
/// Status tints match the launcher icon: mint = within the limit, yellow = over it.
class Ledger {
  static const paper = Color(0xFFFBF9F4);
  static const ink = Color(0xFF1B2422);
  static const emerald = Color(0xFF0E3B34);
  static const muted = Color(0xFF5F5E57);
  static const rule = Color(0xFFDDD8CC);
  static const track = Color(0xFFECE8DE);
  static const shade = Color(0xFFF3F0E8);
  static const mintTint = Color(0xFFD5ECDF);
  static const yellowTint = Color(0xFFFBE7B5);
  static const yellow = Color(0xFFE0A93A);
  static const good = Color(0xFF1F7A5C);
  static const bad = Color(0xFFB3261E);

  // Dark ("ink page") counterparts.
  static const darkPaper = Color(0xFF121816);
  static const darkInk = Color(0xFFEDEAE2);
  static const darkMuted = Color(0xFFA3A69E);
  static const darkRule = Color(0xFF2E3633);
  static const darkTrack = Color(0xFF242C29);
  static const darkShade = Color(0xFF1A211E);
  static const darkMintTint = Color(0xFF1E3D33);
  static const darkYellowTint = Color(0xFF4A3B17);
  static const mint = Color(0xFF7FD1AE);
  static const darkGood = Color(0xFF7FD1AE);
  static const darkBad = Color(0xFFF2A69D);

  /// Bundled when present (assets/fonts); otherwise the system monospace / sans font is used.
  static const monoFamily = 'IBMPlexMono';
  static const sansFamily = 'IBMPlexSans';

  static bool isDark(BuildContext context) => Theme.of(context).brightness == Brightness.dark;
  static Color inkOf(BuildContext context) => isDark(context) ? darkInk : ink;
  static Color mutedOf(BuildContext context) => isDark(context) ? darkMuted : muted;
  static Color ruleOf(BuildContext context) => isDark(context) ? darkRule : rule;
  static Color trackOf(BuildContext context) => isDark(context) ? darkTrack : track;
  static Color shadeOf(BuildContext context) => isDark(context) ? darkShade : shade;
  static Color accentOf(BuildContext context) => isDark(context) ? mint : emerald;
  static Color goodOf(BuildContext context) => isDark(context) ? darkGood : good;
  static Color badOf(BuildContext context) => isDark(context) ? darkBad : bad;
  static Color withinOf(BuildContext context) => isDark(context) ? darkMintTint : mintTint;
  static Color overOf(BuildContext context) => isDark(context) ? darkYellowTint : yellowTint;
  static Color signOf(BuildContext context, num v) => v < 0 ? badOf(context) : goodOf(context);
}

/// Monospaced, tabular figures.
TextStyle mono({double size = 14, FontWeight weight = FontWeight.w500, Color? color, double? height, double? spacing}) =>
    TextStyle(
      fontFamily: Ledger.monoFamily,
      fontFamilyFallback: const ['monospace'],
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
      letterSpacing: spacing,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

ThemeData ledgerTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final paper = dark ? Ledger.darkPaper : Ledger.paper;
  final ink = dark ? Ledger.darkInk : Ledger.ink;
  final muted = dark ? Ledger.darkMuted : Ledger.muted;
  final rule = dark ? Ledger.darkRule : Ledger.rule;
  final accent = dark ? Ledger.mint : Ledger.emerald;
  final square = RoundedRectangleBorder(borderRadius: BorderRadius.circular(3));

  final scheme = ColorScheme.fromSeed(seedColor: Ledger.emerald, brightness: brightness).copyWith(
    primary: accent,
    onPrimary: dark ? Ledger.darkPaper : Ledger.paper,
    primaryContainer: dark ? Ledger.darkMintTint : Ledger.mintTint,
    onPrimaryContainer: dark ? Ledger.darkInk : Ledger.emerald,
    secondary: ink,
    onSecondary: paper,
    secondaryContainer: dark ? Ledger.darkTrack : Ledger.track,
    onSecondaryContainer: ink,
    tertiary: dark ? const Color(0xFFF2C14E) : const Color(0xFF8A6514),
    tertiaryContainer: dark ? Ledger.darkYellowTint : Ledger.yellowTint,
    onTertiaryContainer: dark ? Ledger.darkInk : const Color(0xFF4A3A0E),
    error: dark ? Ledger.darkBad : Ledger.bad,
    surface: paper,
    onSurface: ink,
    onSurfaceVariant: muted,
    surfaceContainerLowest: paper,
    surfaceContainerLow: dark ? Ledger.darkShade : Ledger.shade,
    surfaceContainer: dark ? Ledger.darkShade : Ledger.shade,
    surfaceContainerHigh: dark ? Ledger.darkTrack : Ledger.track,
    surfaceContainerHighest: dark ? Ledger.darkTrack : Ledger.track,
    surfaceTint: Colors.transparent,
    outline: muted,
    outlineVariant: rule,
    inverseSurface: ink,
    onInverseSurface: paper,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: Ledger.sansFamily,
    scaffoldBackgroundColor: paper,
    canvasColor: paper,
    dividerColor: rule,
  );
  final text = base.textTheme.apply(bodyColor: ink, displayColor: ink);
  final monoLabel = mono(size: 13, weight: FontWeight.w500);

  return base.copyWith(
    textTheme: text.copyWith(
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: paper,
      foregroundColor: ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      shape: Border(bottom: BorderSide(color: ink)),
      titleTextStyle: TextStyle(fontFamily: Ledger.sansFamily, fontSize: 21, fontWeight: FontWeight.w600, color: ink, letterSpacing: -0.2),
    ),
    cardTheme: CardThemeData(
      color: paper,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3), side: BorderSide(color: rule)),
    ),
    dividerTheme: DividerThemeData(color: rule, thickness: 1, space: 1),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: paper,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 68,
      indicatorColor: Colors.transparent,
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(color: s.contains(WidgetState.selected) ? ink : muted, size: 22),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith((s) {
        final selected = s.contains(WidgetState.selected);
        return mono(
          size: 11,
          weight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected ? ink : muted,
        ).copyWith(decoration: selected ? TextDecoration.underline : null, decorationColor: accent, decorationThickness: 2);
      }),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(2))),
        side: WidgetStatePropertyAll(BorderSide(color: ink)),
        textStyle: WidgetStatePropertyAll(monoLabel),
        visualDensity: VisualDensity.compact,
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? ink : Colors.transparent),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? paper : ink),
        iconColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? paper : ink),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(backgroundColor: accent, foregroundColor: scheme.onPrimary, shape: square, textStyle: monoLabel),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(elevation: 0, shape: square, backgroundColor: paper, foregroundColor: ink),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(shape: square, side: BorderSide(color: ink), foregroundColor: ink, textStyle: monoLabel),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: accent, shape: square, textStyle: monoLabel),
    ),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: ink)),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: ink,
      foregroundColor: paper,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      shape: square,
      extendedTextStyle: mono(size: 14, weight: FontWeight.w500),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(2), borderSide: BorderSide(color: rule)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(2), borderSide: BorderSide(color: rule)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(2), borderSide: BorderSide(color: accent, width: 1.5)),
      // Long translations of hints under fields wrap instead of being cut off.
      helperMaxLines: 3,
      errorMaxLines: 3,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: paper,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4), side: BorderSide(color: ink)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: paper,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
        side: BorderSide(color: ink),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: paper,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3), side: BorderSide(color: rule)),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
      side: BorderSide(color: rule),
    ),
    checkboxTheme: CheckboxThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2))),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: accent, linearTrackColor: dark ? Ledger.darkTrack : Ledger.track),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: ink,
      contentTextStyle: TextStyle(color: paper),
      actionTextColor: dark ? Ledger.emerald : Ledger.mint,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
    ),
    listTileTheme: ListTileThemeData(iconColor: muted),
    // Screens slide in with a fade (Android), as usual on iPhone.
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    }),
  );
}

/// Section caption: "ПО ДНЯМ ……… 1 820,00" over an ink rule.
class LedgerSection extends StatelessWidget {
  final String title;
  final String? trailing;
  final Widget? action;
  final EdgeInsetsGeometry padding;
  const LedgerSection(this.title, {super.key, this.trailing, this.action, this.padding = const EdgeInsets.fromLTRB(16, 20, 16, 0)});

  @override
  Widget build(BuildContext context) {
    final muted = Ledger.mutedOf(context);
    return Padding(
      padding: padding,
      child: Container(
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Ledger.inkOf(context)))),
        padding: EdgeInsets.only(bottom: action == null ? 5 : 0),
        child: Row(children: [
          Expanded(child: Text(title.toUpperCase(), style: mono(size: 11, weight: FontWeight.w500, color: muted, spacing: 1.1))),
          if (trailing != null) Text(trailing!, style: mono(size: 11, weight: FontWeight.w500, color: muted, spacing: 0.4)),
          ?action,
        ]),
      ),
    );
  }
}

/// A ledger line: label on the left, a monospaced figure on the right, hairline under it.
class LedgerRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final bool bold;
  const LedgerRow(this.label, this.value, {super.key, this.valueColor, this.bold = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Ledger.ruleOf(context)))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
        Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
        const SizedBox(width: 12),
        Text(value, style: mono(size: 14, weight: bold ? FontWeight.w600 : FontWeight.w500, color: valueColor)),
      ]),
    );
  }
}

/// Small caps caption above a figure.
class LedgerCaption extends StatelessWidget {
  final String text;
  const LedgerCaption(this.text, {super.key});

  @override
  Widget build(BuildContext context) =>
      Text(text.toUpperCase(), style: mono(size: 10.5, weight: FontWeight.w500, color: Ledger.mutedOf(context), spacing: 1.0));
}

/// Flat bar with an optional tick (e.g. "share of the period elapsed").
class LedgerBar extends StatelessWidget {
  final double value;
  final double? tick;
  final Color? color;
  final double height;
  const LedgerBar({super.key, required this.value, this.tick, this.color, this.height = 8});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      return SizedBox(
        height: height + 8,
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned(left: 0, right: 0, top: 4, height: height, child: ColoredBox(color: Ledger.trackOf(context))),
          // Grows from zero when shown, then moves to each new value.
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: value.clamp(0.0, 1.0)),
            duration: motion(context, motionMedium),
            curve: motionCurve,
            builder: (context, v, child) => Positioned(left: 0, top: 4, height: height, width: w * v, child: child!),
            child: ColoredBox(color: color ?? Ledger.accentOf(context)),
          ),
          if (tick != null)
            Positioned(
              left: (w * tick!.clamp(0.0, 1.0) - 1).clamp(0.0, w - 2),
              top: 0,
              width: 2,
              height: height + 8,
              child: ColoredBox(color: Ledger.inkOf(context)),
            ),
        ]),
      );
    });
  }
}

/// Settings line: label (+ hint) on the left, a monospaced value and a chevron or control on the right.
class LedgerTile extends StatelessWidget {
  final String label;
  final String? hint;
  final String? value;
  final Color? valueColor;
  final Widget? trailing;
  final VoidCallback? onTap;
  const LedgerTile(this.label, {super.key, this.hint, this.value, this.valueColor, this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = Ledger.mutedOf(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Ledger.ruleOf(context)))),
        // The label takes what it needs; the value gets at most 42 % and is cut off first.
        child: LayoutBuilder(
          builder: (context, c) => Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(label, style: theme.textTheme.bodyLarge?.copyWith(fontSize: 15)),
                if (hint != null) Text(hint!, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
              ]),
            ),
            if (value != null)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: c.maxWidth * 0.42),
                child: Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(value!,
                      textAlign: TextAlign.end,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono(size: 13, weight: FontWeight.w400, color: valueColor ?? muted)),
                ),
              ),
            const SizedBox(width: 8),
            trailing ?? (onTap == null ? const SizedBox.shrink() : Icon(Icons.chevron_right, size: 18, color: muted)),
          ]),
        ),
      ),
    );
  }
}

/// A segmented-button label on one line: long translations shrink a little instead of wrapping.
Widget segmentLabel(String text) => FittedBox(fit: BoxFit.scaleDown, child: Text(text, maxLines: 1, softWrap: false));

/// Square on/off toggle in the ledger style.
class LedgerSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const LedgerSwitch({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final ink = Ledger.inkOf(context);
    return Semantics(
      toggled: value,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 11),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 42,
            height: 24,
            padding: const EdgeInsets.all(3),
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            decoration: BoxDecoration(border: Border.all(color: ink), color: value ? Ledger.withinOf(context) : null),
            child: Container(width: 16, height: 16, color: value ? Ledger.accentOf(context) : Ledger.mutedOf(context)),
          ),
        ),
      ),
    );
  }
}
