import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../ui/ledger.dart';

/// Shared pieces of the computer version, in the ledger look: paper, ink, emerald, hairlines.

const warnColor = Color(0xFFB4532A);
const warnDark = Color(0xFF9A3F1C);
const softWarn = Color(0xFFFBE0D2);
const goldColor = Color(0xFFC08A1E);
const blueColor = Color(0xFF3E6A8A);

Color panelOf(BuildContext c) => Ledger.isDark(c) ? const Color(0xFF161D1B) : const Color(0xFFFFFEFA);
Color sidebarOf(BuildContext c) => Ledger.isDark(c) ? const Color(0xFF0F1513) : const Color(0xFFF5F1E7);
Color warnOf(BuildContext c) => Ledger.isDark(c) ? const Color(0xFFF2A69D) : warnDark;

TextStyle sans(BuildContext c, {double size = 14, FontWeight weight = FontWeight.w400, Color? color, double? height}) =>
    TextStyle(fontFamily: Ledger.sansFamily, fontSize: size, fontWeight: weight, color: color ?? Ledger.inkOf(c), height: height);

/// Page frame: a header with title, subtitle and actions, then the scrolling content.
class DeskPage extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final List<Widget> children;
  final Widget? crumb;
  final ScrollController? controller;
  const DeskPage({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    required this.children,
    this.crumb,
    this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.fromLTRB(32, 18, 32, 16),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Ledger.ruleOf(context)))),
        child: Wrap(
          spacing: 12,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 260, maxWidth: 720),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                ?crumb,
                Text(title, style: sans(context, size: 24, weight: FontWeight.w600)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: sans(context, size: 13, color: Ledger.mutedOf(context))),
                ],
              ]),
            ),
            Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
          ],
        ),
      ),
      Expanded(
        child: ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 48),
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(height: 20),
              children[i],
            ],
          ],
        ),
      ),
    ]);
  }
}

/// A bordered block with an optional title line.
class Panel extends StatelessWidget {
  final String? title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;
  final Color? color;
  final Color? borderColor;
  final EdgeInsetsGeometry padding;
  const Panel({
    super.key,
    this.title,
    this.subtitle,
    this.trailing,
    required this.child,
    this.color,
    this.borderColor,
    this.padding = const EdgeInsets.fromLTRB(20, 18, 20, 18),
  });

  @override
  Widget build(BuildContext context) {
    // A Material (not a decorated box), so list tiles inside paint their ink on it.
    return Material(
      color: color ?? panelOf(context),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: borderColor ?? Ledger.ruleOf(context)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
      padding: padding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (title != null) ...[
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 6,
            children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(title!, style: sans(context, size: 16, weight: FontWeight.w600, color: color == null ? null : _onColor(context))),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(subtitle!, style: sans(context, size: 12.5, color: color == null ? Ledger.mutedOf(context) : _onColor(context).withValues(alpha: .75))),
                  ),
              ]),
              ?trailing,
            ],
          ),
          const SizedBox(height: 12),
        ],
        child,
      ]),
      ),
    );
  }

  Color _onColor(BuildContext context) =>
      color != null && ThemeData.estimateBrightnessForColor(color!) == Brightness.dark ? Ledger.paper : Ledger.inkOf(context);
}

/// A key figure: label, big value, note.
class Kpi extends StatelessWidget {
  final String label;
  final String value;
  final String? note;
  final bool accent;
  final Color? valueColor;
  final VoidCallback? onTap;
  const Kpi(this.label, this.value, {super.key, this.note, this.accent = false, this.valueColor, this.onTap});

  @override
  Widget build(BuildContext context) {
    final on = accent ? Ledger.paper : Ledger.inkOf(context);
    final sub = accent ? const Color(0xFFCFE6DC) : Ledger.mutedOf(context);
    final box = Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: accent ? Ledger.emerald : panelOf(context),
        border: Border.all(color: accent ? Ledger.emerald : Ledger.ruleOf(context)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: sans(context, size: 13, color: sub)),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value, style: mono(size: 26, weight: FontWeight.w600, color: valueColor ?? on)),
        ),
        if (note != null) ...[
          const SizedBox(height: 6),
          Text(note!, style: sans(context, size: 12.5, color: sub), maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      ]),
    );
    return onTap == null ? box : InkWell(onTap: onTap, borderRadius: BorderRadius.circular(8), child: box);
  }
}

/// Lays children out in as many columns as fit, each at least [minWidth] wide.
class AutoGrid extends StatelessWidget {
  final double minWidth;
  final double spacing;
  final List<Widget> children;
  const AutoGrid({super.key, required this.minWidth, this.spacing = 16, required this.children});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = (c.maxWidth + spacing) ~/ (minWidth + spacing);
      final n = cols.clamp(1, children.isEmpty ? 1 : children.length);
      final w = (c.maxWidth - spacing * (n - 1)) / n;
      return Wrap(spacing: spacing, runSpacing: spacing, children: [
        for (final ch in children) SizedBox(width: w, child: ch),
      ]);
    });
  }
}

/// Side-by-side blocks that stack when the window is narrow. [parts]: (flex, min width, child).
class SplitRow extends StatelessWidget {
  final List<(int, double, Widget)> parts;
  final double spacing;
  final CrossAxisAlignment align;
  const SplitRow(this.parts, {super.key, this.spacing = 20, this.align = CrossAxisAlignment.start});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final need = parts.fold<double>(0, (s, p) => s + p.$2) + spacing * (parts.length - 1);
      if (c.maxWidth < need) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < parts.length; i++) ...[if (i > 0) SizedBox(height: spacing), parts[i].$3],
        ]);
      }
      return Row(crossAxisAlignment: align, children: [
        for (var i = 0; i < parts.length; i++) ...[
          if (i > 0) SizedBox(width: spacing),
          Expanded(flex: parts[i].$1, child: parts[i].$3),
        ],
      ]);
    });
  }
}

/// Rounded choice chip.
class Pill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final bool dashed;
  final Widget? trailing;
  final bool dense;
  const Pill(this.label, {super.key, this.selected = false, this.onTap, this.dashed = false, this.trailing, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final accent = Ledger.accentOf(context);
    return Semantics(
      button: onTap != null,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          constraints: BoxConstraints(minHeight: dense ? 30 : 34),
          padding: EdgeInsets.symmetric(horizontal: dense ? 10 : 12),
          decoration: BoxDecoration(
            color: selected ? accent : (dashed ? Colors.transparent : Theme.of(context).scaffoldBackgroundColor),
            border: Border.all(color: selected ? accent : (dashed ? accent : Ledger.ruleOf(context))),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label,
                style: sans(context,
                    size: dense ? 12.5 : 13,
                    color: selected ? (Ledger.isDark(context) ? Ledger.ink : Ledger.paper) : (dashed ? accent : null))),
            if (trailing != null) ...[const SizedBox(width: 4), trailing!],
          ]),
        ),
      ),
    );
  }
}

/// A row of pills where exactly one is chosen.
class Choice<T> extends StatelessWidget {
  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;
  final bool dense;
  const Choice({super.key, required this.options, required this.value, required this.onChanged, this.dense = false});

  @override
  Widget build(BuildContext context) => Wrap(spacing: 6, runSpacing: 6, children: [
        for (final (v, label) in options) Pill(label, selected: v == value, dense: dense, onTap: () => onChanged(v)),
      ]);
}

/// Segmented control with an ink border.
class Seg<T> extends StatelessWidget {
  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;
  const Seg({super.key, required this.options, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final ink = Ledger.inkOf(context);
    return Container(
      decoration: BoxDecoration(border: Border.all(color: ink), borderRadius: BorderRadius.circular(6)),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0) VerticalDivider(width: 1, thickness: 1, color: ink),
            InkWell(
              onTap: () => onChanged(options[i].$1),
              child: Container(
                constraints: const BoxConstraints(minHeight: 36),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 13),
                color: options[i].$1 == value ? ink : Colors.transparent,
                child: Text(options[i].$2,
                    style: sans(context,
                        size: 13,
                        weight: FontWeight.w500,
                        color: options[i].$1 == value ? Theme.of(context).scaffoldBackgroundColor : ink)),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

class DeskButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final IconData? icon;
  final String? shortcut;
  final bool small;
  final Color? color;
  const DeskButton(this.label,
      {super.key, this.onTap, this.primary = false, this.icon, this.shortcut, this.small = false, this.color});

  @override
  Widget build(BuildContext context) {
    final ink = Ledger.inkOf(context);
    final accent = Ledger.accentOf(context);
    final fg = primary ? (Ledger.isDark(context) ? Ledger.ink : Ledger.paper) : (color ?? ink);
    return Material(
      color: primary ? accent : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: primary ? accent : (color ?? ink)),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          constraints: BoxConstraints(minHeight: small ? 34 : 40),
          padding: EdgeInsets.symmetric(horizontal: small ? 10 : 14),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 17, color: fg), const SizedBox(width: 7)],
            Text(label, style: sans(context, size: small ? 13 : 14, weight: FontWeight.w500, color: fg)),
            if (shortcut != null) ...[const SizedBox(width: 8), KeyCap(shortcut!, color: fg)],
          ]),
        ),
      ),
    );
  }
}

class KeyCap extends StatelessWidget {
  final String text;
  final Color? color;
  const KeyCap(this.text, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Ledger.mutedOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(border: Border.all(color: c.withValues(alpha: .7)), borderRadius: BorderRadius.circular(4)),
      child: Text(text, style: mono(size: 10.5, weight: FontWeight.w500, color: c)),
    );
  }
}

/// Progress bar with an optional "where we should be" tick.
class Meter extends StatelessWidget {
  final double value;
  final double? marker;
  final Color? color;
  final double height;
  const Meter(this.value, {super.key, this.marker, this.color, this.height = 8});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height + 6,
      child: LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth;
        return Stack(clipBehavior: Clip.none, alignment: Alignment.centerLeft, children: [
          Container(height: height, decoration: BoxDecoration(color: Ledger.trackOf(context), borderRadius: BorderRadius.circular(height / 2))),
          Container(
            height: height,
            width: w * value.clamp(0, 1),
            decoration: BoxDecoration(color: color ?? Ledger.accentOf(context), borderRadius: BorderRadius.circular(height / 2)),
          ),
          if (marker != null)
            Positioned(
              left: (w * marker!.clamp(0, 1)) - 1,
              top: 0,
              bottom: 0,
              child: Container(width: 2, color: Ledger.inkOf(context).withValues(alpha: .55)),
            ),
        ]);
      }),
    );
  }
}

/// A small switch in the ledger colours.
class Toggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semantics;
  const Toggle(this.value, {super.key, this.onChanged, this.semantics});

  @override
  Widget build(BuildContext context) => Semantics(
        label: semantics,
        toggled: value,
        child: Transform.scale(
          scale: .8,
          child: Switch(value: value, onChanged: onChanged),
        ),
      );
}

/// A two-column "label — value" line.
class LineItem extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;
  final Color? color;
  final String? sub;
  const LineItem(this.label, this.value, {super.key, this.bold = false, this.color, this.sub});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: sans(context, size: 13.5, weight: bold ? FontWeight.w600 : FontWeight.w400)),
              if (sub != null) Text(sub!, style: sans(context, size: 12, color: Ledger.mutedOf(context))),
            ]),
          ),
          const SizedBox(width: 12),
          Text(value, style: mono(size: 13.5, weight: bold ? FontWeight.w600 : FontWeight.w500, color: color)),
        ]),
      );
}

/// Table header and rows with fixed column flexes.
class TableHead extends StatelessWidget {
  final List<(String, int, bool)> cols; // label, flex, right-aligned
  const TableHead(this.cols, {super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Ledger.inkOf(context)))),
        child: Row(children: [
          for (final (label, flex, right) in cols)
            Expanded(
              flex: flex,
              child: Text(label,
                  textAlign: right ? TextAlign.right : TextAlign.left,
                  style: sans(context, size: 12, color: Ledger.mutedOf(context))),
            ),
        ]),
      );
}

class TableLine extends StatelessWidget {
  final List<(Widget, int)> cells;
  final VoidCallback? onTap;
  final Color? color;
  final double padding;
  const TableLine(this.cells, {super.key, this.onTap, this.color, this.padding = 9});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Container(
          color: color,
          padding: EdgeInsets.symmetric(vertical: padding),
          decoration: color == null ? BoxDecoration(border: Border(bottom: BorderSide(color: Ledger.trackOf(context)))) : null,
          foregroundDecoration: color != null ? BoxDecoration(border: Border(bottom: BorderSide(color: Ledger.trackOf(context)))) : null,
          child: Row(children: [
            for (final (w, flex) in cells) Expanded(flex: flex, child: w),
          ]),
        ),
      );
}

Widget numCell(BuildContext context, String text, {Color? color, bool bold = false, double size = 13}) => Text(
      text,
      textAlign: TextAlign.right,
      style: mono(size: size, weight: bold ? FontWeight.w600 : FontWeight.w500, color: color),
    );

Widget textCell(BuildContext context, String text, {String? sub, bool bold = false, Color? color}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: sans(context, size: 13.5, weight: bold ? FontWeight.w600 : FontWeight.w400, color: color)),
        if (sub != null && sub.isNotEmpty)
          Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: sans(context, size: 12, color: Ledger.mutedOf(context))),
      ],
    );

/// A coloured square for categories and legends.
class Swatch extends StatelessWidget {
  final Color color;
  final double size;
  const Swatch(this.color, {super.key, this.size = 10});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
      );
}

/// Small status label.
class Tag extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;
  const Tag(this.text, {super.key, required this.bg, required this.fg});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
        child: Text(text, style: sans(context, size: 12, color: fg)),
      );
}

Tag tagGood(BuildContext c, String t) => Tag(t, bg: Ledger.withinOf(c), fg: Ledger.accentOf(c));
Tag tagWarn(BuildContext c, String t) => Tag(t, bg: Ledger.overOf(c), fg: Ledger.isDark(c) ? Ledger.paper : const Color(0xFF5C4300));
Tag tagPlain(BuildContext c, String t) => Tag(t, bg: Ledger.trackOf(c), fg: Ledger.inkOf(c));

/// Text field with a label above and an optional suffix; [onChanged] gets the raw text.
class FieldBox extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? suffix;
  final ValueChanged<String>? onChanged;
  final String? hint;
  final bool numeric;
  const FieldBox(this.label, this.controller,
      {super.key, this.suffix, this.onChanged, this.hint, this.numeric = true});

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: sans(context, size: 12, color: Ledger.mutedOf(context))),
        const SizedBox(height: 4),
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) => TextField(
            controller: controller,
            onChanged: onChanged,
            keyboardType: numeric ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
            style: mono(size: 14),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              suffixText: suffix,
              suffixIcon: clearIcon(controller, () => onChanged?.call('')),
              suffixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            ),
          ),
        ),
      ]);
}

/// A small × inside a filled field that empties it; null (no icon) while the field is empty.
/// Use inside a ListenableBuilder on [c] so it appears as soon as something is typed.
Widget? clearIcon(TextEditingController c, [VoidCallback? cleared]) => c.text.isEmpty
    ? null
    : IconButton(
        tooltip: tr('d_clear'),
        visualDensity: VisualDensity.compact,
        iconSize: 16,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        icon: const Icon(Icons.close),
        onPressed: () {
          c.clear();
          cleared?.call();
        },
      );

/// "Clear all" for a form with several fields.
class ClearAllButton extends StatelessWidget {
  final VoidCallback? onTap;
  final bool small;
  const ClearAllButton({super.key, required this.onTap, this.small = false});
  @override
  Widget build(BuildContext context) => DeskButton(tr('d_clear_all'), icon: Icons.backspace_outlined, small: small, onTap: onTap);
}

/// Parses "1 234,5" / "1,234.5" / "12" as a number (null when empty or not a number).
double? parseNum(String s) {
  var t = s.replaceAll(RegExp(r'[\s  ]'), '');
  if (t.isEmpty) return null;
  if (t.contains(',') && t.contains('.')) {
    t = t.lastIndexOf(',') > t.lastIndexOf('.') ? t.replaceAll('.', '').replaceAll(',', '.') : t.replaceAll(',', '');
  } else {
    t = t.replaceAll(',', '.');
  }
  return double.tryParse(t);
}
