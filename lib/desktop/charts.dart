import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/strings.dart';
import '../ui/ledger.dart';
import '../ui/motion.dart';

/// Charts of the computer version, on fl_chart like the phone: a tooltip under the mouse,
/// a click on a point or a bar, and motion — values grow in on first show and roll on change.

String compactNum(num v) => NumberFormat.compact(locale: intlLocale).format(v);

TextStyle _tipStyle(BuildContext c) => TextStyle(
      fontFamily: Ledger.monoFamily,
      fontSize: 12,
      height: 1.4,
      color: Ledger.isDark(c) ? Ledger.ink : Ledger.paper,
    );

/// Starts with zeros and switches to the real values after the first frame, so fl_chart
/// animates the growth (no motion when the system asks for none).
mixin _GrowIn<T extends StatefulWidget> on State<T> {
  bool shown = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => shown = true);
    });
  }

  double grow(double v) => shown || MediaQuery.maybeDisableAnimationsOf(context) == true ? v : 0;
}

class DLine {
  final List<double?> values;
  final Color color;
  final String label;
  final bool dashed;
  final double width;
  final bool area;
  const DLine(this.values, this.color, this.label, {this.dashed = false, this.width = 2.4, this.area = false});
}

class DeskLineChart extends StatefulWidget {
  final List<DLine> lines;
  final List<String> xLabels;
  final int labelEvery;
  final double height;
  final String Function(double) format;
  final String Function(int)? xTitle;
  final ValueChanged<int>? onTap;
  final List<(double, Color, String)> hLines;
  const DeskLineChart({
    super.key,
    required this.lines,
    required this.xLabels,
    required this.format,
    this.labelEvery = 1,
    this.height = 240,
    this.xTitle,
    this.onTap,
    this.hLines = const [],
  });
  @override
  State<DeskLineChart> createState() => _DeskLineChartState();
}

class _DeskLineChartState extends State<DeskLineChart> with _GrowIn {
  @override
  Widget build(BuildContext context) {
    final all = [for (final l in widget.lines) ...l.values.whereType<double>(), for (final h in widget.hLines) h.$1];
    final maxV = all.isEmpty ? 1.0 : all.reduce(math.max);
    final minV = all.isEmpty ? 0.0 : math.min(0.0, all.reduce(math.min));
    final span = (maxV - minV).abs() < 1e-9 ? 1.0 : maxV - minV;
    final muted = Ledger.mutedOf(context);
    final small = TextStyle(fontFamily: Ledger.monoFamily, fontSize: 10.5, color: muted);
    return SizedBox(
      height: widget.height,
      child: LineChart(
        LineChartData(
          minY: minV - (minV < 0 ? span * .06 : 0),
          maxY: maxV + span * .08,
          minX: 0,
          maxX: math.max(1, widget.xLabels.length - 1).toDouble(),
          gridData: FlGridData(
            drawVerticalLine: false,
            getDrawingHorizontalLine: (v) => FlLine(color: v == 0 ? Ledger.inkOf(context).withValues(alpha: .5) : Ledger.trackOf(context), strokeWidth: 1),
          ),
          borderData: FlBorderData(show: true, border: Border(bottom: BorderSide(color: Ledger.inkOf(context)))),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 48,
                getTitlesWidget: (v, m) => v == m.max || v == m.min && v != 0 ? const SizedBox.shrink() : Text(compactNum(v), style: small),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 22,
                interval: 1,
                getTitlesWidget: (v, m) {
                  final i = v.round();
                  if ((v - i).abs() > .01 || i < 0 || i >= widget.xLabels.length) return const SizedBox.shrink();
                  if (i % widget.labelEvery != 0 && i != widget.xLabels.length - 1) return const SizedBox.shrink();
                  return Padding(padding: const EdgeInsets.only(top: 4), child: Text(widget.xLabels[i], style: small));
                },
              ),
            ),
          ),
          extraLinesData: ExtraLinesData(horizontalLines: [
            for (final (y, color, label) in widget.hLines)
              HorizontalLine(
                y: y,
                color: color,
                strokeWidth: 1.4,
                dashArray: const [6, 5],
                label: HorizontalLineLabel(
                  show: label.isNotEmpty,
                  alignment: Alignment.topLeft,
                  style: TextStyle(fontFamily: Ledger.monoFamily, fontSize: 11, color: color),
                  labelResolver: (_) => label,
                ),
              ),
          ]),
          lineTouchData: LineTouchData(
            touchCallback: (e, r) {
              if (e is FlTapUpEvent && widget.onTap != null) {
                final s = r?.lineBarSpots;
                if (s != null && s.isNotEmpty) widget.onTap!(s.first.x.round());
              }
            },
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => Ledger.inkOf(context),
              fitInsideHorizontally: true,
              fitInsideVertically: true,
              getTooltipItems: (spots) => [
                for (var k = 0; k < spots.length; k++)
                  LineTooltipItem(
                    '${k == 0 && widget.xTitle != null ? '${widget.xTitle!(spots[k].x.round())}\n' : ''}'
                    '${widget.lines[spots[k].barIndex].label}: ${widget.format(spots[k].y)}',
                    _tipStyle(context),
                  ),
              ],
            ),
          ),
          lineBarsData: [
            for (final l in widget.lines)
              LineChartBarData(
                spots: [
                  for (var i = 0; i < l.values.length; i++)
                    l.values[i] == null ? FlSpot.nullSpot : FlSpot(i.toDouble(), grow(l.values[i]!)),
                ],
                color: l.color,
                barWidth: l.width,
                isStrokeCapRound: true,
                dashArray: l.dashed ? const [6, 5] : null,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(show: l.area, color: l.color.withValues(alpha: .12)),
              ),
          ],
        ),
        duration: motion(context, motionMedium * 2),
        curve: motionCurve,
      ),
    );
  }
}

/// One bar of a group: stacked parts (value, colour); [outline] draws it hollow (e.g. spending
/// next to income).
class DRod {
  final List<(double, Color)> parts;
  final Color? outline;
  const DRod(this.parts, {this.outline});
  double get total => parts.fold(0, (a, p) => a + p.$1);
}

class DeskBarChart extends StatefulWidget {
  final List<List<DRod>> groups;
  final List<String> xLabels;
  final String Function(int group) tooltip;
  final ValueChanged<int>? onTap;
  final double height;
  final double rodWidth;
  final int labelEvery;
  final List<(double, Color, String)> hLines;
  const DeskBarChart({
    super.key,
    required this.groups,
    required this.xLabels,
    required this.tooltip,
    this.onTap,
    this.height = 240,
    this.rodWidth = 14,
    this.labelEvery = 1,
    this.hLines = const [],
  });
  @override
  State<DeskBarChart> createState() => _DeskBarChartState();
}

class _DeskBarChartState extends State<DeskBarChart> with _GrowIn {
  int? hover;

  @override
  Widget build(BuildContext context) {
    final totals = [for (final g in widget.groups) for (final r in g) r.total, for (final h in widget.hLines) h.$1];
    final maxV = totals.isEmpty ? 1.0 : math.max(1.0, totals.reduce(math.max));
    final minV = totals.isEmpty ? 0.0 : math.min(0.0, totals.reduce(math.min));
    final muted = Ledger.mutedOf(context);
    final small = TextStyle(fontFamily: Ledger.monoFamily, fontSize: 10.5, color: muted);
    return SizedBox(
      height: widget.height,
      child: BarChart(
        BarChartData(
          maxY: maxV * 1.1,
          minY: minV * 1.1,
          alignment: BarChartAlignment.spaceAround,
          gridData: FlGridData(
            drawVerticalLine: false,
            getDrawingHorizontalLine: (v) => FlLine(color: Ledger.trackOf(context), strokeWidth: 1),
          ),
          borderData: FlBorderData(show: true, border: Border(bottom: BorderSide(color: Ledger.inkOf(context)))),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 48,
                getTitlesWidget: (v, m) => v == m.max ? const SizedBox.shrink() : Text(compactNum(v), style: small),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 22,
                getTitlesWidget: (v, m) {
                  final i = v.round();
                  if (i < 0 || i >= widget.xLabels.length) return const SizedBox.shrink();
                  if (i % widget.labelEvery != 0) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(widget.xLabels[i], style: small.copyWith(color: hover == i ? Ledger.inkOf(context) : muted)),
                  );
                },
              ),
            ),
          ),
          extraLinesData: ExtraLinesData(horizontalLines: [
            for (final (y, color, label) in widget.hLines)
              HorizontalLine(
                y: y,
                color: color,
                strokeWidth: 1.4,
                dashArray: const [6, 5],
                label: HorizontalLineLabel(
                  show: label.isNotEmpty,
                  alignment: Alignment.topLeft,
                  style: TextStyle(fontFamily: Ledger.monoFamily, fontSize: 11, color: color),
                  labelResolver: (_) => label,
                ),
              ),
          ]),
          barTouchData: BarTouchData(
            touchCallback: (e, r) {
              final g = r?.spot?.touchedBarGroupIndex;
              if (e is FlTapUpEvent && g != null) widget.onTap?.call(g);
              final h = e.isInterestedForInteractions ? g : null;
              if (h != hover) setState(() => hover = h);
            },
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => Ledger.inkOf(context),
              fitInsideHorizontally: true,
              fitInsideVertically: true,
              getTooltipItem: (group, gi, rod, ri) => ri == 0 ? BarTooltipItem(widget.tooltip(gi), _tipStyle(context)) : null,
            ),
          ),
          barGroups: [
            for (var i = 0; i < widget.groups.length; i++)
              BarChartGroupData(
                x: i,
                barsSpace: 3,
                barRods: [
                  for (final r in widget.groups[i])
                    () {
                      final dim = hover != null && hover != i;
                      var from = 0.0;
                      final items = <BarChartRodStackItem>[];
                      for (final (v, c) in r.parts) {
                        final to = from + grow(v);
                        items.add(BarChartRodStackItem(from, to, dim ? c.withValues(alpha: .45) : c));
                        from = to;
                      }
                      return BarChartRodData(
                        toY: grow(r.total),
                        width: widget.rodWidth,
                        color: r.outline != null ? r.outline!.withValues(alpha: dim ? .1 : .2) : (r.parts.isEmpty ? Colors.transparent : r.parts.first.$2),
                        borderSide: r.outline == null ? BorderSide.none : BorderSide(color: r.outline!, width: 1.5),
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                        rodStackItems: r.outline == null && r.parts.length > 1 ? items : const [],
                      );
                    }(),
                ],
              ),
          ],
        ),
        duration: motion(context, motionMedium * 2),
        curve: motionCurve,
      ),
    );
  }
}

/// A donut with a highlighted slice under the mouse and the total (or the slice) in the middle.
class DeskDonut extends StatefulWidget {
  final List<(String, double, Color)> slices;
  final String Function(double) format;
  final ValueChanged<int>? onTap;
  final double size;
  const DeskDonut({super.key, required this.slices, required this.format, this.onTap, this.size = 220});
  @override
  State<DeskDonut> createState() => _DeskDonutState();
}

class _DeskDonutState extends State<DeskDonut> with _GrowIn {
  int? touched;
  @override
  Widget build(BuildContext context) {
    final total = widget.slices.fold<double>(0, (a, s) => a + s.$2);
    final t = touched != null && touched! < widget.slices.length ? widget.slices[touched!] : null;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(alignment: Alignment.center, children: [
        AnimatedRotation(
          turns: shown ? 0 : -.15,
          duration: motion(context, motionMedium * 2),
          curve: motionCurve,
          child: AnimatedOpacity(
            opacity: shown ? 1 : 0,
            duration: motion(context, motionMedium),
            child: PieChart(
              PieChartData(
                sectionsSpace: 2,
                centerSpaceRadius: widget.size * .3,
                startDegreeOffset: -90,
                pieTouchData: PieTouchData(touchCallback: (e, r) {
                  final i = e.isInterestedForInteractions ? r?.touchedSection?.touchedSectionIndex : null;
                  if (e is FlTapUpEvent && i != null && i >= 0) widget.onTap?.call(i);
                  if (i != touched) setState(() => touched = i == null || i < 0 ? null : i);
                }),
                sections: [
                  for (var i = 0; i < widget.slices.length; i++)
                    PieChartSectionData(
                      value: math.max(widget.slices[i].$2, total * .002),
                      color: widget.slices[i].$3,
                      radius: touched == i ? widget.size * .17 : widget.size * .14,
                      showTitle: false,
                    ),
                ],
              ),
              duration: motion(context, motionMedium),
              curve: motionCurve,
            ),
          ),
        ),
        Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: widget.size * .5,
            child: Text(t?.$1 ?? tr('d_total'),
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: Ledger.sansFamily, fontSize: 12, color: Ledger.mutedOf(context))),
          ),
          Text(widget.format(t?.$2 ?? total),
              style: TextStyle(fontFamily: Ledger.monoFamily, fontSize: 15, fontWeight: FontWeight.w600, color: Ledger.inkOf(context))),
          if (t != null && total > 0)
            Text('${(t.$2 / total * 100).round()}%', style: TextStyle(fontFamily: Ledger.monoFamily, fontSize: 12, color: Ledger.mutedOf(context))),
        ]),
      ]),
    );
  }
}
