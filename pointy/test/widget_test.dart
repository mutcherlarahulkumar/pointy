import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pointy/api.dart';
import 'package:pointy/main.dart';
import 'package:pointy/screens/auth/phone.dart';
import 'package:pointy/screens/history/history.dart';
import 'package:pointy/screens/money/requests.dart';
import 'package:pointy/session.dart';
import 'package:pointy/theme.dart';

import 'fakes.dart';

Widget app(Widget home) => MaterialApp(theme: buildTheme(), home: home);

void main() {
  setUp(() {
    AppText.useGoogleFonts = false;
    api = fakeApi();
  });

  // A phone-sized screen, so lists build the rows a phone would show.
  void phoneScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.7;
    addTearDown(tester.view.reset);
  }

  testWidgets('signed out, the app opens on the welcome screen', (tester) async {
    Session.signedIn.value = false;
    await tester.pumpWidget(const PointyApp());
    expect(find.text('Get started'), findsOneWidget);
  });

  testWidgets('signed in, home shows the balance, actions and people', (tester) async {
    phoneScreen(tester);
    Session.signedIn.value = true;
    await tester.pumpWidget(const PointyApp());
    await tester.pumpAndSettle();
    expect(find.text('₹3,630'), findsOneWidget);
    for (final label in ['Add money', 'My QR', 'Pay', 'Request', 'Split bill']) {
      expect(find.text(label), findsWidgets);
    }
    expect(find.text('7'), findsOneWidget); // unread alerts badge
    await tester.scrollUntilVisible(find.text('Dev'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Dev'), findsOneWidget); // recent people
    // Home stops its refresh timer when it goes away.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the phone step only continues with a valid Indian mobile number', (tester) async {
    final sent = <http.Request>[];
    api = fakeApi(log: sent, overrides: {'POST /api/auth/check-phone': (201, '{"phone":"9876543210","exists":false}')});
    await tester.pumpWidget(app(const PhoneScreen()));
    await tester.enterText(find.byType(TextField), '5876543210');
    await tester.pump();
    expect(find.text('Indian mobile numbers start with 6, 7, 8 or 9'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '9876543210');
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(sent.single.url.path, '/api/auth/check-phone');
    expect(find.text('What should friends call you?'), findsOneWidget);
  });

  testWidgets('history tags every movement Trip or Personal', (tester) async {
    await tester.pumpWidget(app(const HistoryScreen(standalone: true)));
    await tester.pumpAndSettle();
    expect(find.text('Refund from Goa trip'), findsOneWidget);
    expect(find.text('Trip'), findsWidgets);
    expect(find.text('Personal'), findsWidgets);
    await tester.tap(find.text('Trips'));
    await tester.pumpAndSettle();
    expect(find.text('Refund from Goa trip'), findsNothing); // a refund lands in your personal balance
  });

  testWidgets('requests are split into to pay and sent', (tester) async {
    phoneScreen(tester);
    await tester.pumpWidget(app(const RequestsScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Dev Mehta asked you'), findsOneWidget);
    await tester.tap(find.text('Sent'));
    await tester.pumpAndSettle();
    expect(find.text('You asked Dev Mehta'), findsOneWidget);
  });

  testWidgets('a signed_out answer from the server signs the phone out', (tester) async {
    api = fakeApi(overrides: {'GET /api/me': (401, '{"error":{"code":"signed_out","message":"please sign in again"}}')});
    var called = false;
    api.onSignedOut = () => called = true;
    await expectLater(api.me(), throwsA(isA<ApiException>()));
    expect(called, isTrue);
  });
}
