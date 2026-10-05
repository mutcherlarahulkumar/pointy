import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pointy/api.dart';
import 'package:pointy/main.dart';
import 'package:pointy/screens/money/request_flow.dart';
import 'package:pointy/session.dart';
import 'package:pointy/theme.dart';
import 'package:pointy/tour.dart';

import 'fakes.dart';

void main() {
  setUp(() {
    AppText.useGoogleFonts = false;
    SharedPreferences.setMockInitialValues({});
    api = fakeApi();
  });

  // The tour's ring pulses for ever, so wait a fixed time instead of
  // pumpAndSettle.
  Future<void> step(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.7;
    addTearDown(tester.view.reset);
  }

  testWidgets('the tour walks through Home and the tabs, and can be skipped', (tester) async {
    phone(tester);
    Session.signedIn.value = true;
    await tester.pumpWidget(const PointyApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Take the tour'));
    await tester.pump(const Duration(milliseconds: 300)); // the tour waits for Home to settle
    await step(tester);
    expect(find.text('Your Pointy balance'), findsOneWidget);

    // "Behind the scenes" opens the detail.
    await tester.tap(find.text('Behind the scenes'));
    await step(tester);
    expect(find.textContaining('double-entry ledger'), findsOneWidget);

    await tester.tap(find.text('Next'));
    await step(tester);
    expect(find.text('Add money'), findsWidgets);
    await tester.tap(find.byTooltip('Back'));
    await step(tester);
    expect(find.text('Your Pointy balance'), findsOneWidget);

    // Every stop is on screen, through to the end card.
    for (var i = 0; i < homeTour.length; i++) {
      await tester.tap(find.text(i == homeTour.length - 1 ? 'Finish' : 'Next'));
      await step(tester);
    }
    expect(find.text('You are all set'), findsOneWidget);
    await tester.tap(find.text('Start using Pointy'));
    await step(tester);
    expect(find.text('You are all set'), findsNothing);

    await tester.tap(find.byTooltip('Take the tour'));
    await tester.pump(const Duration(milliseconds: 300)); // the tour waits for Home to settle
    await step(tester);
    await tester.tap(find.text('Skip'));
    await step(tester);
    expect(find.text('Your Pointy balance'), findsNothing);
    await tester.pumpWidget(const SizedBox()); // stops Home's refresh timer
  });

  testWidgets('each form step shows its number, icon and what to do', (tester) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const RequestPersonScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Step 1 of 2'), findsOneWidget);
    expect(find.text('Pick a friend, or type their mobile number.'), findsOneWidget);
    expect(find.byIcon(Icons.person_search_rounded), findsWidgets);
    expect(find.byIcon(Icons.currency_rupee_rounded), findsOneWidget); // the next step, not reached yet
  });
}
