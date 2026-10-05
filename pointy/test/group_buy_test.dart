import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pointy/api.dart';
import 'package:pointy/models.dart';
import 'package:pointy/payment_lock.dart';
import 'package:pointy/screens/trips/buy_together.dart';
import 'package:pointy/screens/trips/group_buy.dart';
import 'package:pointy/theme.dart';

import 'fakes.dart';
import 'payment_lock_test.dart' show FakeLock;

const _me = 'u_c190dd4c22ea';
const _dev = 'u_e30a147f6407';
const _item = '{"id":"d-spk","title":"Waterproof Bluetooth speaker, 12 h battery","brand":"boAt","merchant":"amazon.in",'
    '"buy_url":"https://www.amazon.in/s","price_paise":179900,"was_price_paise":299000,"list_price":"₹1799"}';

String _buy({String mine = 'waiting', String status = 'open'}) => '{"id":"gb_1","trip_id":"trip_7a6c1f73654c","proposed_by":"$_me",'
    '"request":"a beach speaker","why":"₹899.50 each for the 2 of you.","item":$_item,"category":"other","amount_paise":179900,'
    '"shares":[{"user_id":"$_me","amount_paise":89950,"status":"$mine"${mine == 'in' ? ',"via":"wallet"' : ''}},'
    '{"user_id":"$_dev","amount_paise":89950,"status":"waiting"}],"status":"$status","deadline":"2026-10-07T21:00:00+05:30"}';

void main() {
  final sent = <http.Request>[];
  late Trip trip;

  setUp(() async {
    AppText.useGoogleFonts = false;
    sent.clear();
    api = fakeApi(log: sent, overrides: {
      'POST /api/trips/trip_7a6c1f73654c/shop-agent': (
        200,
        '{"search_id":"srch_1","query":"beach speaker","budget_paise":0,"people":2,"reply":"Here is the best pick for 2 people.",'
            '"picks":[{"index":0,"item":$_item,"why":"₹899.50 each for the 2 of you, ₹1,191 off right now.","each_paise":89950,"fits_budget":true}],"source":"rules"}'
      ),
      'POST /api/trips/trip_7a6c1f73654c/group-buys': (201, _buy()),
      'GET /api/group-buys/gb_1': (200, _buy()),
      'POST /api/group-buys/gb_1/join': (200, _buy(mine: 'in')),
      'POST /api/auth/verify-pin': (200, '{"ok":true}'),
    });
    api.userId = _me;
    trip = (await api.trips()).first;
  });
  tearDown(() => PaymentLock.instance = PaymentLock());

  Future<void> phone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.7;
    addTearDown(tester.view.reset);
  }

  testWidgets('the agent shows its pick and why, and proposing opens the purchase', (tester) async {
    await phone(tester);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: BuyTogetherScreen(trip: trip)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A beach speaker'));
    await tester.pumpAndSettle();
    expect(find.text('Here is the best pick for 2 people.'), findsOneWidget);
    expect(find.textContaining('₹1,191 off'), findsOneWidget);
    await tester.tap(find.text('Propose to the group'));
    await tester.pumpAndSettle();
    final propose = sent.firstWhere((r) => r.url.path.endsWith('/group-buys'));
    expect(jsonDecode(propose.body), containsPair('search_id', 'srch_1'));
    expect(find.text('0 of 2 are in'), findsOneWidget);
    expect(find.text('Yes, ₹899.50 from my trip share'), findsOneWidget);
  });

  testWidgets('saying yes from the trip share asks for the PIN, then shows you are in', (tester) async {
    await phone(tester);
    PaymentLock.instance = FakeLock();
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: GroupBuyScreen(trip: trip, id: 'gb_1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes, ₹899.50 from my trip share'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your PIN'), findsOneWidget);
    for (final d in '246810'.split('')) {
      await tester.tap(find.text(d).last);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    final join = sent.firstWhere((r) => r.url.path.endsWith('/join'));
    expect(jsonDecode(join.body), {'via': 'wallet'});
    expect(find.text('1 of 2 are in'), findsOneWidget);
    expect(find.text('In · wallet'), findsOneWidget);
  });
}
