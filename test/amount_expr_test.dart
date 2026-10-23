import 'package:budget_app/ui/txn_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('plain amounts', () {
    expect(evaluateAmount('45'), 4500);
    expect(evaluateAmount('45,5'), 4550);
    expect(evaluateAmount('0,07'), 7);
  });

  test('sums and differences from the keypad', () {
    expect(evaluateAmount('12+30,5'), 4250);
    expect(evaluateAmount('100−20,25'), 7975);
    expect(evaluateAmount('100-20'), 8000);
    expect(evaluateAmount('10+5+'), 1500); // trailing operator ignored
  });

  test('invalid or non-positive', () {
    expect(evaluateAmount(''), isNull);
    expect(evaluateAmount('5−10'), isNull);
    expect(evaluateAmount('0'), isNull);
    expect(evaluateAmount('1,2,3'), isNull);
  });
}
