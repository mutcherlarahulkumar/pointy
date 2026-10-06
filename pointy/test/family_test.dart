import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pointy/api.dart';
import 'package:pointy/models.dart';
import 'package:pointy/payment_lock.dart';
import 'package:pointy/screens/family/add_child.dart';
import 'package:pointy/screens/family/child_detail.dart';
import 'package:pointy/screens/family/family.dart';
import 'package:pointy/screens/money/pay_flow.dart';
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

  testWidgets('the pairing code counts down and says when it ran out', (tester) async {
    phone(tester);
    api = fakeApi(overrides: {'GET /api/family': (200, '{"role":"parent","children":[]}')});
    final pending = _child.replaceFirst('"status":"active"', '"status":"pending"');
    final inv = FamilyInvite.fromJson(jsonDecode('{"child":$pending,"code":"123456","expires":"2026-10-05T12:00:00+05:30"}') as Map<String, dynamic>);
    // Expires in 3 seconds, from now on the phone's clock.
    final soon = FamilyInvite(child: inv.child, code: inv.code, expires: DateTime.now().add(const Duration(seconds: 3)));
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: PairingCodeScreen(invite: soon)));
    expect(find.text('123 456'), findsOneWidget);
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 4)));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('This code ran out. Start again.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // stops its timers
  });

  const approval = '{"id":"ap_1","child":{"id":"$_kid","name":"Riya Rao"},"payee":{"id":"u_shop","name":"Corner shop"},'
      '"amount_paise":50000,"note":"Book","reason":"daily","status":"pending","ends":"2026-10-06T12:00:00+05:30"}';

  testWidgets('approving a child\'s payment sends an Idempotency-Key, new after a refusal', (tester) async {
    phone(tester);
    api = fakeApi(log: sent, overrides: {
      'GET /api/family': (200, '{"role":"parent","children":[$_child],"approvals":[$approval],"rules":{}}'),
      'POST /api/auth/verify-pin': (200, '{"ok":true}'),
      'POST /api/family/approvals/ap_1/approve': (409, '{"error":{"code":"insufficient_balance","message":"not enough"}}'),
    })..userId = _me;
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const FamilyScreen()));
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      await typePin(tester);
      tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger)).removeCurrentSnackBar();
      await tester.pumpAndSettle();
    }
    final keys = [for (final r in sent.where((r) => r.url.path.endsWith('/approve'))) r.headers['Idempotency-Key']];
    expect(keys, hasLength(2));
    expect(keys.every((k) => k != null && k.isNotEmpty), isTrue);
    expect(keys[1], isNot(keys[0]), reason: 'the server keeps the 409 under the first key');
  });

  testWidgets('a child asking a parent sends an Idempotency-Key; three waiting asks get a clear message', (tester) async {
    phone(tester);
    api = fakeApi(log: sent, overrides: {
      'POST /api/auth/verify-pin': (200, '{"ok":true}'),
      'POST /api/payments/personal': (409, '{"error":{"code":"needs_parent","message":"over your daily limit","details":{"parent":"Asha"}}}'),
      'POST /api/family/approvals': (409, '{"error":{"code":"too_many_asks","message":"wait for an answer to the ones you have asked"}}'),
    })..userId = _kid;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: PayConfirmScreen(person: Person(id: 'u_shop', name: 'Corner shop', phone: '9000000002'), amountPaise: 20000, note: 'Book'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pay ₹200'));
    await tester.pumpAndSettle();
    await typePin(tester);
    await tester.tap(find.text('Ask Asha on their phone'));
    await tester.pumpAndSettle();
    final ask = sent.lastWhere((r) => r.url.path == '/api/family/approvals');
    expect(ask.headers['Idempotency-Key'], isNotNull);
    expect(find.text('Asha has 3 asks to answer already. Wait for an answer, then ask again.'), findsOneWidget);
  });

  testWidgets('too many wrong parent codes explains the wait', (tester) async {
    phone(tester);
    api = fakeApi(log: sent, overrides: {
      'POST /api/auth/verify-pin': (200, '{"ok":true}'),
      'POST /api/payments/personal': (
        429,
        '{"error":{"code":"too_many_codes","message":"too many wrong codes; try again in 15 minutes or ask Asha to approve it"}}'
      ),
    })..userId = _kid;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: PayConfirmScreen(person: Person(id: 'u_shop', name: 'Corner shop', phone: '9000000002'), amountPaise: 20000, note: 'Book'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pay ₹200'));
    await tester.pumpAndSettle();
    await typePin(tester);
    expect(find.textContaining('Too many wrong codes'), findsOneWidget);
    expect(find.text('Pay ₹200'), findsOneWidget); // not stuck spinning
  });

  test('inviting a child sends an Idempotency-Key', () async {
    api = fakeApi(log: sent, overrides: {'POST /api/family/invites': (201, '{"child":$_child,"code":"123456"}')});
    await api.inviteChild({'child_phone': '9000000001'}, key: 'k1');
    expect(sent.last.headers['Idempotency-Key'], 'k1');
  });
}
