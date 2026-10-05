import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pointy/api.dart';
import 'package:pointy/models.dart';
import 'package:pointy/payment_lock.dart';
import 'package:pointy/screens/money/pay_flow.dart';
import 'package:pointy/theme.dart';

import 'fakes.dart';

/// A lock that answers without the phone: [device] is what the fingerprint
/// prompt returns (null: the phone has no lock, so the PIN is asked).
class FakeLock extends PaymentLock {
  FakeLock({this.on = true, this.device});
  final bool on;
  final bool? device;
  final asked = <String>[];

  @override
  Future<bool> isOn() async => on;

  @override
  Future<bool?> deviceCheck(String reason) async {
    asked.add(reason);
    return device;
  }
}

const _paid = '{"id":"exp_1","kind":"transfer","description":"Chai","category":"other","amount_paise":20000,'
    '"payee":"Dev Mehta","shares":[],"at":"2026-10-05T12:00:00+05:30"}';

void main() {
  final sent = <http.Request>[];
  bool paid() => sent.any((r) => r.url.path == '/api/payments/personal');

  setUp(() {
    AppText.useGoogleFonts = false;
    sent.clear();
    api = fakeApi(log: sent, overrides: {
      'POST /api/payments/personal': (201, _paid),
      'POST /api/auth/verify-pin': (200, '{"ok":true}'),
    });
  });
  tearDown(() => PaymentLock.instance = PaymentLock());

  Future<void> openReview(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.7;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: PayConfirmScreen(person: Person(id: 'u_dev', name: 'Dev Mehta', phone: '9123456780'), amountPaise: 20000, note: 'Chai'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pay ₹200'));
    await tester.pumpAndSettle();
  }

  testWidgets('a fingerprint that is accepted pays', (tester) async {
    final lock = FakeLock(device: true);
    PaymentLock.instance = lock;
    await openReview(tester);
    expect(lock.asked, ['Pay ₹200 to Dev Mehta']);
    expect(paid(), isTrue);
    expect(find.text('Paid'), findsOneWidget);
  });

  testWidgets('cancelling the fingerprint does not pay', (tester) async {
    PaymentLock.instance = FakeLock(device: false);
    await openReview(tester);
    expect(paid(), isFalse);
    expect(find.text('Pay ₹200'), findsOneWidget);
  });

  testWidgets('with no screen lock the Pointy PIN is asked, and a wrong one is refused', (tester) async {
    PaymentLock.instance = FakeLock();
    api = fakeApi(log: sent, overrides: {
      'POST /api/payments/personal': (201, _paid),
      'POST /api/auth/verify-pin': (401, '{"error":{"code":"wrong_pin","message":"wrong PIN","details":{"attempts_left":4}}}'),
    });
    await openReview(tester);
    expect(find.text('Enter your PIN'), findsOneWidget);
    for (final d in '135790'.split('')) {
      await tester.tap(find.text(d).last);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('Wrong PIN. 4 tries left.'), findsOneWidget);
    expect(paid(), isFalse);
  });

  testWidgets('the right PIN pays', (tester) async {
    PaymentLock.instance = FakeLock();
    await openReview(tester);
    for (final d in '246810'.split('')) {
      await tester.tap(find.text(d).last);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    final pin = sent.firstWhere((r) => r.url.path == '/api/auth/verify-pin');
    expect(pin.body, '{"pin":"246810"}');
    expect(paid(), isTrue);
  });

  testWidgets('turned off, nothing is asked', (tester) async {
    final lock = FakeLock(on: false);
    PaymentLock.instance = lock;
    await openReview(tester);
    expect(lock.asked, isEmpty);
    expect(paid(), isTrue);
  });
}
