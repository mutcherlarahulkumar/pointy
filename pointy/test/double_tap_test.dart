import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pointy/api.dart';
import 'package:pointy/models.dart';
import 'package:pointy/payment_lock.dart';
import 'package:pointy/screens/money/pay_flow.dart';
import 'package:pointy/screens/money/top_up.dart';
import 'package:pointy/theme.dart';

import 'fakes.dart';
import 'payment_lock_test.dart' show FakeLock;

const _paid = '{"id":"exp_1","kind":"transfer","description":"Chai","category":"other","amount_paise":20000,'
    '"payee":"Dev Mehta","shares":[],"at":"2026-10-05T12:00:00+05:30"}';

class _CountReplacements extends NavigatorObserver {
  int replaced = 0;
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => replaced++;
}

void main() {
  final sent = <http.Request>[];

  setUp(() {
    AppText.useGoogleFonts = false;
    sent.clear();
    PaymentLock.instance = FakeLock();
    api = fakeApi(log: sent, overrides: {
      'POST /api/payments/personal': (201, _paid),
      'POST /api/auth/verify-pin': (200, '{"ok":true}'),
      'POST /api/trips/trip_7a6c1f73654c/deposits': (201, fixture('trip_open')),
    });
  });
  tearDown(() => PaymentLock.instance = PaymentLock());

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.7;
    addTearDown(tester.view.reset);
  }

  Future<void> typePin(WidgetTester tester) async {
    for (final d in '246810'.split('')) {
      await tester.tap(find.text(d).last);
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('a double tap on Pay opens one PIN sheet, not two', (tester) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: PayConfirmScreen(person: Person(id: 'u_dev', name: 'Dev Mehta', phone: '9123456780'), amountPaise: 20000, note: 'Chai'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pay ₹200'));
    await tester.tap(find.text('Pay ₹200'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your PIN'), findsOneWidget);
    await typePin(tester);
    expect(find.text('Enter your PIN'), findsNothing);
    expect(sent.where((r) => r.url.path == '/api/payments/personal'), hasLength(1));
  });

  testWidgets('a double tap when adding to a trip moves the money once', (tester) async {
    phone(tester);
    final trip = (await api.trips()).first;
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: TopUpScreen(trip: trip, suggestPaise: 50000)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add ₹500'));
    await tester.tap(find.text('Add ₹500'));
    await tester.pumpAndSettle();
    await typePin(tester);
    if (find.text('Enter your PIN').evaluate().isNotEmpty) await typePin(tester);
    expect(sent.where((r) => r.url.path.endsWith('/deposits')), hasLength(1));
  });

  testWidgets('PayPal top-up: two checks finding it paid show the result once', (tester) async {
    phone(tester);
    const created = '{"id":"dep_1","amount_paise":50000,"paypal_order_id":"O1","approve_url":"https://www.sandbox.paypal.com/x","status":"created"}';
    const captured = '{"id":"dep_1","amount_paise":50000,"paypal_order_id":"O1","status":"captured"}';
    api = fakeApi(log: sent, overrides: {'POST /api/topups': (201, created), 'GET /api/deposits/O1': (200, captured)});
    final nav = _CountReplacements();
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), navigatorObservers: [nav], home: const TopUpScreen(suggestPaise: 50000)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue to PayPal'));
    // The waiting screen spins, so it never settles: pump step by step.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    ScaffoldMessenger.of(tester.element(find.text("I've approved it"))).removeCurrentSnackBar(); // no browser in tests
    await tester.pump(const Duration(milliseconds: 500));
    // The automatic check and the person's tap land together.
    await tester.tap(find.text("I've approved it"));
    await tester.tap(find.text("I've approved it"));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('Money added'), findsOneWidget);
    expect(nav.replaced, 1);
  });

  testWidgets('with fingerprint, a double tap pays once', (tester) async {
    phone(tester);
    PaymentLock.instance = FakeLock(check: PayCheck.biometric, scan: true);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: PayConfirmScreen(person: Person(id: 'u_dev', name: 'Dev Mehta', phone: '9123456780'), amountPaise: 20000, note: 'Chai'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pay ₹200'));
    await tester.tap(find.text('Pay ₹200'));
    await tester.pumpAndSettle();
    expect(sent.where((r) => r.url.path == '/api/payments/personal'), hasLength(1));
    expect(find.text('Paid'), findsOneWidget);
  });

  testWidgets('with fingerprint, a double tap when adding to a trip moves the money once', (tester) async {
    phone(tester);
    PaymentLock.instance = FakeLock(check: PayCheck.biometric, scan: true);
    final trip = (await api.trips()).first;
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: TopUpScreen(trip: trip, suggestPaise: 50000)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add ₹500'));
    await tester.tap(find.text('Add ₹500'));
    await tester.pumpAndSettle();
    expect(sent.where((r) => r.url.path.endsWith('/deposits')), hasLength(1));
  });
}
