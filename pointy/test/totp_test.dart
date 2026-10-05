import 'package:flutter_test/flutter_test.dart';
import 'package:pointy/totp.dart';

void main() {
  test('approval codes match RFC 6238 and the server', () {
    // RFC 6238 key "12345678901234567890" at T=59 s: 94287082, last 6 digits.
    final t = Totp('GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ');
    expect(t.code(DateTime.fromMillisecondsSinceEpoch(59 * 1000)), '287082');
    // T=1111111109 s: 07081804 -> 081804.
    expect(t.code(DateTime.fromMillisecondsSinceEpoch(1111111109 * 1000)), '081804');
    expect(Totp.secondsLeft(DateTime.fromMillisecondsSinceEpoch(59 * 1000)), 1);
  });
}
