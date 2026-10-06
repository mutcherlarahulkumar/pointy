import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pointy/api.dart';
import 'package:pointy/payment_lock.dart';
import 'package:pointy/screens/family/child_detail.dart';
import 'package:pointy/screens/family/family.dart';
import 'package:pointy/theme.dart';

import 'fakes.dart';
import 'payment_lock_test.dart' show FakeLock;

const _me = 'u_c190dd4c22ea';
const _kid = 'u_kid';
const _child = '{"link_id":"fl_1","status":"active","child":{"id":"$_kid","name":"Riya Rao","phone":"9000000001"},'
    '"parent":{"id":"$_me","name":"Asha Rao"},"age":12,"balance_paise":5000,"daily_limit_paise":20000,"monthly_limit_paise":300000,'
    '"daily_left_paise":20000,"monthly_left_paise":300000}';
const _family = '{"role":"parent","children":[$_child],"invites":[],"approvals":[],"rules":{}}';
const _paid = '{"id":"exp_1","kind":"transfer","description":"Pocket money","category":"other","amount_paise":10000,'
    '"payee":"Riya Rao","shares":[],"at":"2026-10-05T12:00:00+05:30"}';

void main() {
  final sent = <http.Request>[];

  setUp(() {
    AppText.useGoogleFonts = false;
    sent.clear();
    PaymentLock.instance = FakeLock();
    api = fakeApi(log: sent, overrides: {
      'GET /api/family': (200, _family),
      'GET /api/family/children/$_kid/activity': (200, '[]'),
      'POST /api/payments/personal': (201, _paid),
      'POST /api/auth/verify-pin': (200, '{"ok":true}'),
    })..userId = _me;
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

  // The pages reload afterwards; setState(() => _data = load()) returned the
  // Future, which debug builds reject (and then skip the rebuild).
  testWidgets('sending pocket money from a child\'s page pays and reloads without errors', (tester) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(child: TextButton(onPressed: () => Navigator.of(context).push(familyRoute()), child: const Text('Open family'))),
        ),
      ),
    ));
    await tester.tap(find.text('Open family'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Riya Rao'));
    await tester.pumpAndSettle();
    expect(find.byType(ChildDetailScreen), findsOneWidget);

    await tester.tap(find.text('Pocket money'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '100');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pay ₹100'));
    await tester.pumpAndSettle();
    await typePin(tester);

    expect(find.text('Paid'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
