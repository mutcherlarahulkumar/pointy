import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy/api.dart';
import 'package:pointy/main.dart';
import 'package:pointy/models.dart';
import 'package:pointy/screens/ai/insights.dart';
import 'package:pointy/screens/family/child_home.dart';
import 'package:pointy/screens/family/family.dart';
import 'package:pointy/screens/history/history.dart';
import 'package:pointy/screens/home/alerts.dart';
import 'package:pointy/screens/money/pay_flow.dart';
import 'package:pointy/screens/money/requests.dart';
import 'package:pointy/screens/money/split_flow.dart';
import 'package:pointy/screens/money/top_up.dart';
import 'package:pointy/screens/money/withdraw.dart';
import 'package:pointy/screens/profile/profile.dart';
import 'package:pointy/screens/trips/settle.dart';
import 'package:pointy/screens/trips/trip_shell.dart';
import 'package:pointy/screens/trips/trips.dart';
import 'package:pointy/session.dart';
import 'package:pointy/theme.dart';

import 'fakes.dart';

const _long = 'Venkata Satya Narayana Murthy Chakravarthula';
const _kid = '{"link_id":"fl_1","status":"active","child":{"id":"u_kid","name":"$_long","phone":"9000000001"},'
    '"parent":{"id":"u_c190dd4c22ea","name":"$_long"},"age":12,"balance_paise":5000,"daily_limit_paise":20000,"monthly_limit_paise":300000,'
    '"daily_left_paise":20000,"monthly_left_paise":300000,"pending_approvals":3}';
const _approval = '{"id":"ap_1","child":{"id":"u_kid","name":"$_long"},"payee":{"id":"u_x","name":"$_long"},"amount_paise":12345678,'
    '"note":"A very long note about what this payment is for","reason":"monthly","status":"pending","ends":"2026-10-06T12:00:00+05:30"}';

/// Every fixture with long names and big amounts, as a phone with a long
/// contact list would see it.
Map<String, (int, String)> longNames() {
  String f(String name) => fixture(name)
      .replaceAll('Dev Mehta', _long)
      .replaceAll('Asha Rao', _long)
      .replaceAll('Goa trip', 'Goa trip with the whole college gang 2026')
      .replaceAll('"personal_balance_paise":363000', '"personal_balance_paise":1234567899');
  final trips = jsonDecode(f('trips')) as List;
  return {
    'GET /api/me': (200, f('me')),
    'GET /api/trips': (200, f('trips')),
    'GET /api/history': (200, f('history')),
    'GET /api/alerts': (200, f('alerts')),
    'GET /api/contacts': (200, f('contacts')),
    'GET /api/money-requests': (200, f('money_requests')),
    for (final t in trips) 'GET /api/trips/${(t as Map)['id']}': (200, jsonEncode(t)),
    'GET /api/family': (200, '{"role":"parent","children":[$_kid],"approvals":[$_approval],"rules":{}}'),
  };
}

void main() {
  setUp(() {
    AppText.useGoogleFonts = false;
    api = fakeApi(overrides: longNames())..userId = 'u_c190dd4c22ea';
  });

  Future<void> show(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: screen, builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(1.3)), child: w!)));
    await tester.pumpAndSettle();
  }

  final person = Person(id: 'u_e30a147f6407', name: _long, phone: '9123456780');

  testWidgets('home at 360x640 with long names', (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    Session.signedIn.value = true;
    await tester.pumpWidget(const PointyApp());
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('pay confirm', (tester) => show(tester, PayConfirmScreen(person: person, amountPaise: 1234567800, note: 'A long note for the payment here')));
  testWidgets('pay amount', (tester) => show(tester, PayAmountScreen(person: person)));
  testWidgets('requests', (tester) => show(tester, const RequestsScreen()));
  testWidgets('history', (tester) => show(tester, const HistoryScreen(standalone: true)));
  testWidgets('alerts', (tester) => show(tester, const AlertsScreen()));
  testWidgets('trips', (tester) => show(tester, const TripsScreen()));
  testWidgets('trip shell', (tester) => show(tester, const TripShell(tripId: 'trip_7a6c1f73654c')));
  testWidgets('settle', (tester) async {
    final trip = (await api.trips()).first;
    final me = await api.me();
    await show(tester, SettleScreen(trip: trip, me: me));
  });
  testWidgets('top up trip', (tester) async {
    final trip = (await api.trips()).first;
    await show(tester, TopUpScreen(trip: trip));
  });
  testWidgets('withdraw', (tester) => show(tester, const WithdrawScreen()));
  testWidgets('split', (tester) => show(tester, const SplitBillScreen()));
  testWidgets('family', (tester) => show(tester, const FamilyScreen()));
  testWidgets('child home', (tester) => show(tester, const ChildHome()));
  testWidgets('profile', (tester) => show(tester, const ProfileScreen()));
  testWidgets('insights', (tester) => show(tester, const InsightsScreen()));
}
