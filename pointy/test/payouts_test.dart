import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pointy/api.dart';
import 'package:pointy/payment_lock.dart';
import 'package:pointy/screens/money/where_money.dart';
import 'package:pointy/screens/money/withdraw.dart';
import 'package:pointy/theme.dart';

import 'fakes.dart';
import 'payment_lock_test.dart' show FakeLock;

String meWith(String email) {
  final me = jsonDecode(fixture('me')) as Map<String, dynamic>;
  (me['user'] as Map<String, dynamic>)['paypal_email'] = email;
  return jsonEncode(me);
}

const _payout = '{"id":"po_1","user_id":"u_you","kind":"withdraw","email":"asha@example.com","description":"Withdrawal to PayPal",'
    '"amount_paise":50000,"status":"paid","paypal_batch_id":"BATCH-123","created_at":"2026-10-05T12:00:00+05:30"}';

void main() {
  final sent = <http.Request>[];

  setUp(() {
    AppText.useGoogleFonts = false;
    sent.clear();
    PaymentLock.instance = FakeLock();
  });
  tearDown(() => PaymentLock.instance = PaymentLock());

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.7;
    addTearDown(tester.view.reset);
  }

  testWidgets('without a PayPal email, withdraw asks for one first', (tester) async {
    phone(tester);
    api = fakeApi(log: sent, overrides: {'GET /api/me': (200, meWith(''))});
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const WithdrawScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Add your PayPal email'), findsOneWidget);
    expect(find.text('Not added yet'), findsOneWidget);
    await tester.tap(find.text('Add your PayPal email'));
    await tester.pumpAndSettle();
    expect(find.text('Where should Pointy pay you?'), findsOneWidget);
  });

  testWidgets('withdraw asks for the PIN, then shows the PayPal payout', (tester) async {
    phone(tester);
    api = fakeApi(log: sent, overrides: {
      'GET /api/me': (200, meWith('asha@example.com')),
      'POST /api/auth/verify-pin': (200, '{"ok":true}'),
      'POST /api/withdrawals': (201, _payout),
    });
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const WithdrawScreen()));
    await tester.pumpAndSettle();
    expect(find.text('asha@example.com'), findsOneWidget);
    await tester.tap(find.text('₹500'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Withdraw ₹500'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your PIN'), findsOneWidget);
    for (final d in '246810'.split('')) {
      await tester.tap(find.text(d).last);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(jsonDecode(sent.last.body), {'amount_paise': 50000});
    expect(find.text('Sent to your PayPal'), findsOneWidget);
    expect(find.text('BATCH-123'), findsOneWidget);
  });

  testWidgets('where is my money shows the business account and payouts', (tester) async {
    phone(tester);
    api = fakeApi(overrides: {
      'GET /api/money': (
        200,
        '{"paypal_mode":"sandbox","paypal_email":"asha@example.com","business_account_paise":1500000,"owed_to_everyone_paise":1500000,'
            '"balanced":true,"your_balance_paise":150000,"your_trip_shares_paise":240000,"you_paid_in_paise":500000,"you_paid_out_paise":50000,'
            '"payouts":[$_payout]}'
      ),
    });
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const WhereMoneyScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Pointy\'s PayPal business account'), findsOneWidget);
    expect(find.textContaining('₹15,000 for everyone'), findsOneWidget);
    expect(find.text('Books match'), findsOneWidget);
    expect(find.text('₹1,500'), findsOneWidget); // your balance
    await tester.scrollUntilVisible(find.text('Withdrawal to PayPal'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Paid'), findsOneWidget);
  });
}
