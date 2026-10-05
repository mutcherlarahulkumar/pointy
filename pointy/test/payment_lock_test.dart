import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pointy/api.dart';
import 'package:pointy/models.dart';
import 'package:pointy/payment_lock.dart';
import 'package:pointy/screens/money/pay_flow.dart';
import 'package:pointy/screens/profile/payment_check.dart';
import 'package:pointy/theme.dart';

import 'fakes.dart';

/// A lock that answers without the phone. [mode] is the chosen check and
/// [scan] what the fingerprint prompt returns.
class FakeLock extends PaymentLock {
  FakeLock({this.check = PayCheck.pin, this.scan = false});
  PayCheck check;
  final bool scan;
  final asked = <String>[];

  @override
  Future<PayCheck> mode() async => check;

  @override
  Future<void> setMode(PayCheck m) async => check = m;

  @override
  Future<bool> canUseBiometrics() async => true;

  @override
  Future<bool> biometricCheck(String reason) async {
    asked.add(reason);
    return scan;
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

  Future<void> typePin(WidgetTester tester, String pin) async {
    for (final d in pin.split('')) {
      await tester.tap(find.text(d).last);
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('by default every payment asks for the Pointy PIN, not the fingerprint', (tester) async {
    final lock = FakeLock();
    PaymentLock.instance = lock;
    await openReview(tester);
    expect(lock.asked, isEmpty);
    expect(find.text('Enter your PIN'), findsOneWidget);
    expect(paid(), isFalse);
    await typePin(tester, '246810');
    final pin = sent.firstWhere((r) => r.url.path == '/api/auth/verify-pin');
    expect(pin.body, '{"pin":"246810"}');
    expect(paid(), isTrue);
  });

  testWidgets('a wrong PIN is refused and nothing is paid', (tester) async {
    PaymentLock.instance = FakeLock();
    api = fakeApi(log: sent, overrides: {
      'POST /api/payments/personal': (201, _paid),
      'POST /api/auth/verify-pin': (401, '{"error":{"code":"wrong_pin","message":"wrong PIN","details":{"attempts_left":4}}}'),
    });
    await openReview(tester);
    await typePin(tester, '135790');
    expect(find.text('Wrong PIN. 4 tries left.'), findsOneWidget);
    expect(paid(), isFalse);
  });

  testWidgets('with fingerprint chosen, a good scan pays without the PIN', (tester) async {
    final lock = FakeLock(check: PayCheck.biometric, scan: true);
    PaymentLock.instance = lock;
    await openReview(tester);
    expect(lock.asked, ['Pay ₹200 to Dev Mehta']);
    expect(find.text('Enter your PIN'), findsNothing);
    expect(paid(), isTrue);
    expect(find.text('Paid'), findsOneWidget);
  });

  testWidgets('with fingerprint chosen, a failed scan falls back to the PIN', (tester) async {
    final lock = FakeLock(check: PayCheck.biometric, scan: false);
    PaymentLock.instance = lock;
    await openReview(tester);
    expect(lock.asked, hasLength(1));
    expect(find.text('Enter your PIN'), findsOneWidget);
    expect(paid(), isFalse);
    await typePin(tester, '246810');
    expect(paid(), isTrue);
  });

  testWidgets('switching to fingerprint needs the PIN and one good scan', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.7;
    addTearDown(tester.view.reset);
    final lock = FakeLock(scan: true);
    PaymentLock.instance = lock;
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const PaymentCheckScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Default'), findsOneWidget);
    await tester.tap(find.text('Fingerprint or face'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your PIN'), findsOneWidget);
    await typePin(tester, '246810');
    expect(lock.check, PayCheck.biometric);
    expect(lock.asked, ['Scan to turn on fingerprint for payments']);
  });
}
