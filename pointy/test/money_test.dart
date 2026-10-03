import 'package:flutter_test/flutter_test.dart';
import 'package:pointy/money.dart';

void main() {
  test('formats paise with Indian grouping', () {
    expect(formatPaise(0), '₹0');
    expect(formatPaise(50000), '₹500');
    expect(formatPaise(843000), '₹8,430');
    expect(formatPaise(12000000), '₹1,20,000');
    expect(formatPaise(1234567800), '₹1,23,45,678');
    expect(formatPaise(184050), '₹1,840.50');
    expect(formatPaise(184005), '₹1,840.05');
    expect(formatPaise(100, alwaysPaise: true), '₹1.00');
    expect(formatPaise(-50000), '-₹500');
  });

  test('parses typed amounts to paise without floats', () {
    expect(parseToPaise('1840'), 184000);
    expect(parseToPaise('1,840.5'), 184050);
    expect(parseToPaise('₹ 1840.05'), 184005);
    expect(parseToPaise('0.10'), 10);
    expect(parseToPaise('0'), isNull);
    expect(parseToPaise('12.345'), isNull);
    expect(parseToPaise('abc'), isNull);
    expect(parseToPaise(''), isNull);
  });

  test('splits like the backend: leftover paise go to the first people', () {
    expect(splitPaise(1000, [1, 1, 1]), [334, 333, 333]);
    expect(splitPaise(184000, [1, 1, 1, 1]), [46000, 46000, 46000, 46000]);
    expect(splitPaise(1000, [2, 1]), [667, 333]);
    expect(splitPaise(1000, []), isEmpty);
  });

  test('round-trips paise through an input field', () {
    expect(paiseToInput(184050), '1840.50');
    expect(parseToPaise(paiseToInput(184050)), 184050);
    expect(paiseToInput(300000), '3000');
  });
}
