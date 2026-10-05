import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pointy/api.dart';
import 'package:pointy/screens/ai/pointy_ai.dart';
import 'package:pointy/theme.dart';

import 'fakes.dart';

const _dev = {'id': 'u_dev', 'name': 'Dev Mehta', 'phone': '9123456780'};

void main() {
  final sent = <http.Request>[];

  setUp(() {
    AppText.useGoogleFonts = false;
    sent.clear();
  });

  Future<void> open(WidgetTester tester, {List<Map<String, dynamic>> history = const [], required List<Map<String, dynamic>> turn}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.7;
    addTearDown(tester.view.reset);
    api = fakeApi(log: sent, overrides: {
      'GET /api/assistant/messages': (200, jsonEncode(history)),
      'POST /api/assistant/messages': (201, jsonEncode(turn)),
      'DELETE /api/assistant/messages': (200, '{"ok":true}'),
    });
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const PointyAiScreen()));
    await tester.pumpAndSettle();
  }

  testWidgets('a starter question gets an answer from the account', (tester) async {
    await open(tester, turn: [
      {'id': 'm1', 'role': 'user', 'text': "What's my balance?"},
      {'id': 'm2', 'role': 'assistant', 'text': 'Your Pointy balance is ₹3,630.', 'source': 'ai'},
    ]);
    expect(find.text('Ask me about your money'), findsOneWidget);
    await tester.tap(find.text("What's my balance?"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(jsonDecode(sent.last.body), {'text': "What's my balance?"});
    expect(find.text('Your Pointy balance is ₹3,630.'), findsOneWidget);
    expect(find.text('AI'), findsOneWidget); // answered by the model
  });

  testWidgets('a payment reply only opens the confirm screen, filled in', (tester) async {
    await open(tester, turn: [
      {'id': 'm1', 'role': 'user', 'text': 'pay dev 200 for chai'},
      {
        'id': 'm2', 'role': 'assistant', 'text': 'Pay Dev ₹200 for chai? Check it and confirm.', 'source': 'rules',
        'action': {'type': 'pay', 'label': 'Review: pay Dev ₹200', 'person': _dev, 'amount_paise': 20000, 'note': 'chai'},
      },
    ]);
    await tester.enterText(find.byType(TextField), 'pay dev 200 for chai');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(sent.where((r) => r.url.path == '/api/payments/personal'), isEmpty);
    await tester.tap(find.text('Review: pay Dev ₹200'));
    await tester.pumpAndSettle();
    expect(find.text('Check and pay'), findsOneWidget);
    expect(find.text('Pay ₹200'), findsOneWidget);
  });

  testWidgets('the saved conversation loads and can be cleared', (tester) async {
    await open(tester, history: [
      {'id': 'h1', 'role': 'user', 'text': 'who owes me?'},
      {'id': 'h2', 'role': 'assistant', 'text': 'Nothing is pending.', 'source': 'rules'},
    ], turn: const []);
    expect(find.text('who owes me?'), findsOneWidget);
    expect(find.text('Nothing is pending.'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear the chat'));
    await tester.pumpAndSettle();
    expect(sent.last.method, 'DELETE');
    expect(find.text('Ask me about your money'), findsOneWidget);
  });
}
