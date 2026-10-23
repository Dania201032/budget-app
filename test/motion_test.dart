import 'package:budget_app/domain/money.dart';
import 'package:budget_app/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget app(int minor, {bool noAnimations = false}) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: noAnimations),
          child: Scaffold(body: AnimatedMoney(minor, 'CNY')),
        ),
      );

  testWidgets('a sum shows at once, then rolls to a new value', (tester) async {
    await tester.pumpWidget(app(10000));
    expect(find.text(formatMoney(10000, 'CNY')), findsOneWidget);

    await tester.pumpWidget(app(20000));
    await tester.pump(motionMedium ~/ 2);
    expect(find.text(formatMoney(10000, 'CNY')), findsNothing);
    expect(find.text(formatMoney(20000, 'CNY')), findsNothing);

    await tester.pumpAndSettle();
    expect(find.text(formatMoney(20000, 'CNY')), findsOneWidget);
  });

  testWidgets('no rolling when the phone asks for no animations', (tester) async {
    await tester.pumpWidget(app(10000, noAnimations: true));
    await tester.pumpWidget(app(20000, noAnimations: true));
    await tester.pump();
    expect(find.text(formatMoney(20000, 'CNY')), findsOneWidget);
  });
}
