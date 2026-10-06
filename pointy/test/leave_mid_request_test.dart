import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy/api.dart';
import 'package:pointy/screens/assistant/assistant.dart';
import 'package:pointy/screens/money/requests.dart';
import 'package:pointy/screens/money/top_up.dart';
import 'package:pointy/screens/trips/settle.dart';
import 'package:pointy/theme.dart';

import 'fakes.dart';

/// Leaving a screen while its request is still on the way must not touch
/// the screen when the answer arrives.
void main() {
  setUp(() => AppText.useGoogleFonts = false);

  // Answers fixtures at once, but holds [slowPath] until [release] completes.
  ApiClient slow(String slowPath, String body, Completer<void> release) {
    final fast = fakeApi();
    final client = MockClient((req) async {
      if (req.url.path == slowPath) {
        await release.future;
        return http.Response.bytes(utf8.encode(body), 200, headers: {'content-type': 'application/json'});
      }
      final hit = {'/api/me': fixture('me'), '/api/trips': fixture('trips'), '/api/money-requests': fixture('money_requests')}[req.url.path] ?? '{}';
      return http.Response.bytes(utf8.encode(hit), 200, headers: {'content-type': 'application/json'});
    });
    return ApiClient(baseUrl: fast.baseUrl, client: client)..token = 't';
  }

  Future<void> openFromRoot(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.7;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen)), child: const Text('Open')),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('trip assistant: leaving while the plan is drafted', (tester) async {
    final release = Completer<void>();
    api = fakeApi();
    final trip = (await api.trips()).first;
    api = slow('/api/trips/${trip.id}/assistant/plan', '{"id":"plan_1","items":[],"status":"draft"}', release);
    await openFromRoot(tester, AssistantScreen(trip: trip));
    await tester.enterText(find.byType(TextField), 'Collect ₹1,000 each');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    release.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('add money: leaving while PayPal checkout is being created', (tester) async {
    final release = Completer<void>();
    api = slow('/api/topups', '{"id":"dep_1","amount_paise":50000,"paypal_order_id":"O1","approve_url":"https://www.sandbox.paypal.com/x","status":"created"}',
        release);
    await openFromRoot(tester, const TopUpScreen(suggestPaise: 50000));
    await tester.tap(find.text('Continue to PayPal'));
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    release.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('settle up: leaving while the refunds are sent', (tester) async {
    final release = Completer<void>();
    api = fakeApi();
    final trip = (await api.trips()).first;
    final me = await api.me();
    const open = '{"status":"open","refund_paise":1000,"lines":[]}';
    final base = slow('/api/trips/${trip.id}/settle', '{"status":"settled","refund_paise":1000,"lines":[]}', release);
    api = ApiClient(
      baseUrl: base.baseUrl,
      client: MockClient((req) async {
        if (req.url.path.endsWith('/settlement')) return http.Response(open, 200, headers: {'content-type': 'application/json'});
        await release.future;
        return http.Response('{"status":"settled","refund_paise":1000,"lines":[]}', 200, headers: {'content-type': 'application/json'});
      }),
    )..token = 't';
    await openFromRoot(tester, SettleScreen(trip: trip, me: me));
    await tester.tap(find.text('Send refunds of ₹10'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send refunds'));
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    release.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('requests: leaving while a request is being cancelled', (tester) async {
    final release = Completer<void>();
    api = slow('/api/money-requests/mr_c13906684ab6/decline', '{"id":"mr_c13906684ab6","status":"cancelled"}', release);
    await openFromRoot(tester, const RequestsScreen());
    await tester.tap(find.text('Sent'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel request'));
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    release.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
