import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pointy/api.dart';
import 'package:pointy/main.dart';
import 'package:pointy/models.dart';
import 'package:pointy/prefs.dart';
import 'package:pointy/screens/pay/pay_draft.dart';
import 'package:pointy/screens/pay/review.dart';
import 'package:pointy/theme.dart';

import 'fakes.dart';

void main() {
  setUp(() {
    AppText.useGoogleFonts = false;
    AiPrefs.location = false;
    api = fakeApi();
  });

  testWidgets('shows the five bottom bar items', (tester) async {
    await tester.pumpWidget(const PointyApp());
    for (final label in ['Home', 'Trips', 'Scan', 'Insights', 'History']) {
      expect(find.text(label), findsWidgets);
    }
  });

  testWidgets('home shows the personal balance and one AI suggestion', (tester) async {
    await tester.pumpWidget(const PointyApp());
    await tester.pumpAndSettle();
    expect(find.text('₹8,430'), findsOneWidget);
    expect(find.textContaining('Dinner with your Goa trip group'), findsOneWidget);
    expect(find.text('Restaurant nearby'), findsOneWidget);
    // Home is for your own money: no trip wallet card here.
    expect(find.text('in the trip wallet'), findsNothing);
  });

  testWidgets('trips tab shows the active trip as a wallet card', (tester) async {
    await tester.pumpWidget(const PointyApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Trips'));
    await tester.pumpAndSettle();
    expect(find.text('Goa trip'), findsOneWidget);
    expect(find.text('₹12,192'), findsOneWidget);
    expect(find.text('Day 2 of 5'), findsOneWidget);
  });

  testWidgets('history tags every payment', (tester) async {
    await tester.pumpWidget(const PointyApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.text('Dinner, beach shack'), findsOneWidget);
    expect(find.text('Trip'), findsWidgets);
  });

  testWidgets('a budget warning opens the budget check, and Pay anyway resends with a new key', (tester) async {
    final sent = <http.Request>[];
    var calls = 0;
    api = fakeApi(log: sent, overrides: {'POST /api/trips/t_goa/expenses': (409, fixture('budget_warning'))});
    final trip = Trip.fromJson(jsonDecode(fixture('trips_t_goa')) as Map<String, dynamic>);
    final me = Me.fromJson(jsonDecode(fixture('me')) as Map<String, dynamic>);
    final draft = PayDraft()
      ..me = me
      ..trip = trip
      ..wallet = 'trip'
      ..payeeName = 'Beach shack, Baga'
      ..payeeEmail = 'shack@example.com'
      ..amountPaise = 184000
      ..description = 'Dinner'
      ..category = 'food';
    draft.participants.addAll(trip.members);

    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: ReviewScreen(draft: draft)));
    expect(find.text('₹460'), findsWidgets); // each person's part
    await tester.tap(find.text('Pay ₹1,840'));
    await tester.pumpAndSettle();

    expect(find.text('This takes Food to 85%'), findsOneWidget);
    expect(find.text('₹752'), findsOneWidget); // left after
    calls = sent.where((r) => r.url.path.endsWith('/expenses')).length;
    expect(calls, 1);

    await tester.tap(find.text('Pay anyway'));
    await tester.pumpAndSettle();
    final posts = sent.where((r) => r.url.path.endsWith('/expenses')).toList();
    expect(posts.length, 2);
    expect(jsonDecode(posts[1].body)['confirm_over_budget'], true);
    expect(posts[1].headers['Idempotency-Key'], isNot(posts[0].headers['Idempotency-Key']));
  });
}
