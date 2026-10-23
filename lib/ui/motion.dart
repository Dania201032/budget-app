import 'package:flutter/material.dart';

import '../domain/money.dart';

/// Motion in the app is short and only shows what changed: figures roll to their new value, bars
/// grow, a new payment slides into the list. Off when the phone asks for no animations
/// (Accessibility → Remove animations).
const motionShort = Duration(milliseconds: 180);
const motionMedium = Duration(milliseconds: 320);
const motionCurve = Curves.easeOutCubic;

Duration motion(BuildContext context, Duration d) =>
    MediaQuery.maybeDisableAnimationsOf(context) == true ? Duration.zero : d;

/// A number that rolls from its previous value to the new one; no animation on the first build.
class AnimatedValue extends StatelessWidget {
  final double value;
  final Widget Function(BuildContext context, double value) builder;
  const AnimatedValue({super.key, required this.value, required this.builder});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: value, end: value),
      duration: motion(context, motionMedium),
      curve: motionCurve,
      builder: (context, v, _) => builder(context, v),
    );
  }
}

/// A sum of money ([minor] units) that rolls to its new value.
class AnimatedMoney extends StatelessWidget {
  final int minor;
  final String currency;
  final TextStyle? style;
  final bool signed;
  const AnimatedMoney(this.minor, this.currency, {super.key, this.style, this.signed = false});

  @override
  Widget build(BuildContext context) => AnimatedValue(
    value: minor.toDouble(),
    builder: (context, v) => Text(formatMoney(v.round(), currency, signed: signed), style: style),
  );
}

/// Fades and unfolds its child once, when it first appears (a payment just added or captured).
class AppearIn extends StatefulWidget {
  final Widget child;
  final bool animate;
  const AppearIn({super.key, required this.child, this.animate = true});

  @override
  State<AppearIn> createState() => _AppearInState();
}

class _AppearInState extends State<AppearIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: motionMedium);
  late final Animation<double> _a = CurvedAnimation(parent: _c, curve: motionCurve);

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (MediaQuery.maybeDisableAnimationsOf(context) == true) {
          _c.value = 1;
        } else {
          _c.forward();
        }
      });
    } else {
      _c.value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizeTransition(
    sizeFactor: _a,
    alignment: Alignment.topCenter,
    child: FadeTransition(opacity: _a, child: widget.child),
  );
}
