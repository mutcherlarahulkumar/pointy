import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy/api.dart';
import 'package:pointy/models.dart';
import 'package:pointy/payment_lock.dart';
import 'package:pointy/screens/assistant/request_view.dart';
import 'package:pointy/screens/money/bill_split.dart';
import 'package:pointy/screens/money/pay_flow.dart';
import 'package:pointy/screens/money/withdraw.dart';
import 'package:pointy/screens/money/request_flow.dart';
import 'package:pointy/screens/money/split_flow.dart';
import 'package:pointy/theme.dart';

import 'fakes.dart';
import 'payment_lock_test.dart' show FakeLock;

const _me = 'u_c190dd4c22ea';
const _dev = 'u_e30a147f6407';
const _splitOk = '{"requests":[{"id":"mr_1","payer":{"id":"$_dev","name":"Dev Mehta"},"payee":{"id":"$_me","name":"Asha Rao"},'
    '"amount_paise":50000,"note":"Dinner","status":"open","created_at":"2026-10-05T12:00:00+05:30"}]}';
const _itemsOk = '{"total_paise":100000,"parts":[{"user":{"id":"$_dev","name":"Dev Mehta"},"items":["Thali"],'
    '"subtotal_paise":100000,"extra_paise":0,"total_paise":100000}],"requests":[]}';
const _conflict = '{"error":{"code":"invalid","message":"try again"}}';

/// An ApiClient whose connection always drops.
ApiClient offlineApi(List<http.Request> log) {
  final c = MockClient((req) async {
    log.add(req);
    throw http.ClientException('connection reset');
  });
  return ApiClient(baseUrl: 'http://test', client: c)
    ..token = 't'
    ..userId = _me;
}

void main() {
  final sent = <http.Request>[];
  List<String> keys(String path) => [for (final r in sent.where((r) => r.url.path == path)) r.headers['Idempotency-Key']!];

  setUp(() {
    AppText.useGoogleFonts = false;
    sent.clear();
  });

  // The error snack bar sits over the button; the person waits for it to go.
  Future<void> dismissSnack(WidgetTester tester) async {
    tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger)).removeCurrentSnackBar();
    await tester.pumpAndSettle();
  }

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.7;
    addTearDown(tester.view.reset);
  }

  group('SubmitKey', () {
    test('the same request keeps its key, a changed one gets a new key', () {
      final k = SubmitKey();
      final a = k.forRequest({'amount': 1});
      expect(k.forRequest({'amount': 1}), a);
      expect(k.forRequest({'amount': 2}), isNot(a));
    });

    test('an error the server kept (4xx) needs a new key; a dropped connection does not', () {
      final k = SubmitKey();
      final a = k.forRequest('x');
      k.failed(ApiException(0, 'offline', ''));
      expect(k.forRequest('x'), a);
      k.failed(ApiException(503, 'error', ''));
      expect(k.forRequest('x'), a);
      k.failed(ApiException(409, 'insufficient_balance', ''));
      expect(k.forRequest('x'), isNot(a));
    });
  });

  Future<void> openSplitReview(WidgetTester tester) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const SplitBillScreen(amountPaise: 100000, what: 'Dinner')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dev Mehta'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue with 2 people'));
    await tester.pumpAndSettle();
  }

  testWidgets('split a bill: changing the split after an error sends a new Idempotency-Key', (tester) async {
    api = fakeApi(log: sent, overrides: {'POST /api/splits': (409, _conflict)})..userId = _me;
    await openSplitReview(tester);
    await tester.tap(find.text('Ask for ₹500'));
    await tester.pumpAndSettle();
    expect(find.text('Try again'), findsOneWidget);
    await dismissSnack(tester);

    // The person changes the split, then sends again.
    api = fakeApi(log: sent, overrides: {'POST /api/splits': (201, _splitOk)})..userId = _me;
    await tester.tap(find.text('By shares'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add_circle_outline).last);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Ask for'));
    await tester.pumpAndSettle();

    final k = keys('/api/splits');
    expect(k, hasLength(2));
    expect(k[1], isNot(k[0]));
    expect(find.text('Sent 1 request'), findsOneWidget);
  });

  testWidgets('split a bill: a retry after a dropped connection reuses the key', (tester) async {
    api = fakeApi(log: sent)..userId = _me;
    await openSplitReview(tester);
    api = offlineApi(sent);
    await tester.tap(find.text('Ask for ₹500'));
    await tester.pumpAndSettle();
    await dismissSnack(tester);
    api = fakeApi(log: sent, overrides: {'POST /api/splits': (201, _splitOk)})..userId = _me;
    await tester.tap(find.text('Ask for ₹500'));
    await tester.pumpAndSettle();
    final k = keys('/api/splits');
    expect(k, hasLength(2));
    expect(k[1], k[0]);
  });

  testWidgets('split by items: changing who had what after an error sends a new Idempotency-Key', (tester) async {
    phone(tester);
    api = fakeApi(log: sent, overrides: {'POST /api/splits/items': (409, _conflict)})..userId = _me;
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const BillSplitScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Item'), 'Thali');
    await tester.enterText(find.widgetWithText(TextField, 'Price'), '1000');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue · ₹1,000'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dev Mehta'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue with 2 people'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Everyone'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send requests'));
    await tester.pumpAndSettle();
    expect(find.text('Try again'), findsOneWidget);
    await dismissSnack(tester);

    // Only Dev had it after all.
    api = fakeApi(log: sent, overrides: {'POST /api/splits/items': (201, _itemsOk)})..userId = _me;
    await tester.tap(find.widgetWithText(FilterChip, 'You'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send requests'));
    await tester.pumpAndSettle();

    final k = keys('/api/splits/items');
    expect(k, hasLength(2));
    expect(k[1], isNot(k[0]));
    expect(find.text('Sent 1 request'), findsOneWidget);
  });

  testWidgets('request money: a changed amount after an error sends a new Idempotency-Key', (tester) async {
    phone(tester);
    api = fakeApi(log: sent, overrides: {'POST /api/money-requests': (400, _conflict)})..userId = _me;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: RequestAmountScreen(person: Person(id: _dev, name: 'Dev Mehta', phone: '9123456780'), amountPaise: 50000),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask for ₹500'));
    await tester.pumpAndSettle();
    await dismissSnack(tester);
    await tester.enterText(find.byType(TextField).first, '400');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask for ₹400'));
    await tester.pumpAndSettle();
    final k = keys('/api/money-requests');
    expect(k, hasLength(2));
    expect(k[1], isNot(k[0]));
  });

  testWidgets('a deposit request refused once (balance too low) can be paid after adding money', (tester) async {
    phone(tester);
    PaymentLock.instance = FakeLock();
    addTearDown(() => PaymentLock.instance = PaymentLock());
    const req = '{"id":"req_1","trip_id":"trip_7a6c1f73654c","user":{"id":"$_me","name":"Asha Rao"},"amount_paise":100000,'
        '"due":"2026-10-10T00:00:00+05:30","status":"open"}';
    api = fakeApi(log: sent, overrides: {
      'GET /api/trips/trip_7a6c1f73654c/requests': (200, '[$req]'),
      'POST /api/auth/verify-pin': (200, '{"ok":true}'),
      'POST /api/requests/req_1/pay': (409, '{"error":{"code":"insufficient_balance","message":"not enough balance"}}'),
    })..userId = _me;
    final trip = (await api.trips()).first;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: RequestViewScreen(trip: trip, request: DepositRequest.fromJson(jsonDecode(req) as Map<String, dynamic>)),
    ));
    await tester.pumpAndSettle();
    Future<void> payWithPin() async {
      await tester.tap(find.textContaining('Pay from balance'));
      await tester.pumpAndSettle();
      for (final d in '246810'.split('')) {
        await tester.tap(find.text(d).last);
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    await payWithPin();
    await dismissSnack(tester);
    await payWithPin();
    final k = keys('/api/requests/req_1/pay');
    expect(k, hasLength(2));
    expect(k[1], isNot(k[0]), reason: 'the same key only replays the stored 409');
  });

  Future<void> typePin(WidgetTester tester) async {
    for (final d in '246810'.split('')) {
      await tester.tap(find.text(d).last);
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  // A server that answers [routes] (and the fixtures) but whose connection
  // drops on [path], after the payment may already have gone through.
  ApiClient dropping(String path, Map<String, (int, String)> routes) {
    final ok = fakeApi(overrides: routes);
    final c = MockClient((req) async {
      sent.add(req);
      if (req.url.path == path) throw http.ClientException('connection reset');
      final hit = routes['${req.method} ${req.url.path}'] ?? (200, fixture('me'));
      return http.Response.bytes(utf8.encode(hit.$2), hit.$1, headers: {'content-type': 'application/json'});
    });
    return ApiClient(baseUrl: ok.baseUrl, client: c)
      ..token = 't'
      ..userId = _me;
  }

  testWidgets('pay: a retry after the connection dropped reuses the key, so it cannot pay twice', (tester) async {
    phone(tester);
    PaymentLock.instance = FakeLock();
    addTearDown(() => PaymentLock.instance = PaymentLock());
    final routes = {'POST /api/auth/verify-pin': (200, '{"ok":true}')};
    api = dropping('/api/payments/personal', routes);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: PayConfirmScreen(person: Person(id: _dev, name: 'Dev Mehta', phone: '9123456780'), amountPaise: 20000, note: 'Chai'),
    ));
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('Pay ₹200'));
      await tester.pumpAndSettle();
      await typePin(tester);
      await dismissSnack(tester);
    }
    final k = keys('/api/payments/personal');
    expect(k, hasLength(2));
    expect(k[1], k[0]);
  });

  testWidgets('withdraw: a retry after the connection dropped reuses the key', (tester) async {
    phone(tester);
    PaymentLock.instance = FakeLock();
    addTearDown(() => PaymentLock.instance = PaymentLock());
    final me = fixture('me').replaceFirst('"name":"Asha Rao"', '"name":"Asha Rao","paypal_email":"asha@example.com"');
    api = dropping('/api/withdrawals', {'GET /api/me': (200, me), 'POST /api/auth/verify-pin': (200, '{"ok":true}')});
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const WithdrawScreen()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '500');
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('Withdraw ₹500'));
      await tester.pumpAndSettle();
      await typePin(tester);
      await dismissSnack(tester);
    }
    final k = keys('/api/withdrawals');
    expect(k, hasLength(2));
    expect(k[1], k[0]);
  });
}
