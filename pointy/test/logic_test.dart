import 'package:flutter_test/flutter_test.dart';
import 'package:pointy/dates.dart';
import 'package:pointy/models.dart';
import 'package:pointy/screens/money/my_qr.dart';
import 'package:pointy/screens/pay/scan.dart';
import 'package:pointy/screens/trips/expense_flow.dart';

void main() {
  test('reads API times as IST wall-clock time', () {
    expect(formatDateTime(parseIst('2026-10-13T20:42:00+05:30')), 'Tue 13 Oct, 8:42 pm');
    expect(formatDateTime(parseIst('2026-10-13T15:12:00Z')), 'Tue 13 Oct, 8:42 pm');
    expect(toIsoIst(DateTime(2026, 10, 20)), '2026-10-20T00:00:00+05:30');
  });

  test('a Pointy QR code round-trips to the person', () {
    final p = Person(id: 'u_abc123', name: 'Asha Rao', phone: '9876543210');
    expect(userIdFromQr(qrPayload(p)), 'u_abc123');
    expect(userIdFromQr('upi://pay?pa=shop@upi&pn=Shop'), isNull); // PayPal cannot pay UPI codes
    expect(userIdFromQr('hello'), isNull);
  });

  test('suggests a category from the description, with the reason', () {
    expect(guessCategory('Dinner at the shack'), ('food', '"dinner" in the description'));
    expect(guessCategory('Ola to airport')?.$1, 'transport');
    expect(guessCategory('Villa for 2 nights')?.$1, 'stay');
    expect(guessCategory('Sunscreen'), isNull);
  });

  test('reads a scanned receipt from the API', () {
    final r = ScannedReceipt.fromJson({'amount_paise': 184050, 'merchant': "Britto's", 'category': 'food', 'description': "Dinner at Britto's", 'date': '2026-10-12'});
    expect(r.amountPaise, 184050);
    expect(r.category, 'food');
    expect(r.merchant, "Britto's");
  });

  test('names, initials and phone formatting', () {
    expect(firstName('  Asha   Rao '), 'Asha');
    expect(initials('asha rao'), 'AR');
    expect(initials('Dev'), 'D');
    expect(formatPhone('9876543210'), '98765 43210');
  });
}
