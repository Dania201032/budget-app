import 'package:flutter/material.dart';

/// Thin line icons for the bottom bar, drawn on a 24×24 grid in the ledger style.
enum LedgerGlyph { home, overview, analytics, money, settings }

class LedgerIcon extends StatelessWidget {
  final LedgerGlyph glyph;
  final bool selected;
  final double size;
  const LedgerIcon(this.glyph, {super.key, this.selected = false, this.size = 24});

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _GlyphPainter(glyph, color, selected)),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  final LedgerGlyph glyph;
  final Color color;
  final bool selected;
  _GlyphPainter(this.glyph, this.color, this.selected);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = selected ? 2.1 : 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = color;
    void line(double x1, double y1, double x2, double y2) => canvas.drawLine(Offset(x1, y1), Offset(x2, y2), stroke);

    switch (glyph) {
      case LedgerGlyph.home: // a calendar page; today's cell filled when selected
        canvas.drawRect(const Rect.fromLTRB(4, 6, 20, 20), stroke);
        line(4, 10, 20, 10);
        line(9, 3, 9, 7);
        line(15, 3, 15, 7);
        if (selected) canvas.drawRect(const Rect.fromLTRB(13, 13, 17, 17), fill);
      case LedgerGlyph.overview: // a pie with one share pulled out
        final pie = Path()
          ..moveTo(12, 3)
          ..arcToPoint(const Offset(21, 12), radius: const Radius.circular(9), largeArc: true, clockwise: false)
          ..lineTo(12, 12)
          ..close();
        final share = Path()
          ..moveTo(15, 3.5)
          ..arcToPoint(const Offset(20.5, 9), radius: const Radius.circular(9))
          ..lineTo(15, 9)
          ..close();
        canvas.drawPath(pie, stroke);
        canvas.drawPath(share, selected ? fill : stroke);
      case LedgerGlyph.analytics: // three columns on a baseline
        line(3, 20, 21, 20);
        if (selected) {
          canvas.drawRect(const Rect.fromLTRB(4, 11, 7, 20), fill);
          canvas.drawRect(const Rect.fromLTRB(10.5, 5, 13.5, 20), fill);
          canvas.drawRect(const Rect.fromLTRB(17, 14, 20, 20), fill);
        } else {
          line(5.5, 20, 5.5, 11);
          line(12, 20, 12, 5);
          line(18.5, 20, 18.5, 14);
        }
      case LedgerGlyph.money: // a wallet with a card tucked in
        final wallet = Path()
          ..moveTo(3, 7)
          ..lineTo(18, 7)
          ..arcToPoint(const Offset(21, 10), radius: const Radius.circular(3))
          ..lineTo(21, 18)
          ..arcToPoint(const Offset(19, 20), radius: const Radius.circular(2))
          ..lineTo(5, 20)
          ..arcToPoint(const Offset(3, 18), radius: const Radius.circular(2))
          ..close();
        canvas.drawPath(wallet, stroke);
        canvas.drawPath(
          Path()
            ..moveTo(3, 7)
            ..lineTo(15, 3)
            ..lineTo(15, 7),
          stroke,
        );
        if (selected) {
          canvas.drawRect(const Rect.fromLTRB(15, 12.5, 19, 15.5), fill);
        } else {
          line(16, 14, 18, 14);
        }
      case LedgerGlyph.settings: // two sliders
        line(4, 7, 14, 7);
        line(18, 7, 20, 7);
        line(4, 17, 8, 17);
        line(12, 17, 20, 17);
        if (selected) {
          canvas.drawRect(const Rect.fromLTRB(14.5, 4.5, 17.5, 9.5), fill);
          canvas.drawRect(const Rect.fromLTRB(8.5, 14.5, 11.5, 19.5), fill);
        } else {
          line(16, 5, 16, 9);
          line(10, 15, 10, 19);
        }
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.glyph != glyph || old.color != color || old.selected != selected;
}
