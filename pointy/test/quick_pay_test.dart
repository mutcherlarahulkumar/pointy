import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pointy/api.dart';
import 'package:pointy/screens/money/quick_pay.dart';
import 'package:pointy/theme.dart';

import 'fakes.dart';

const _dev = {'id': 'u_dev', 'name': 'Dev Mehta', 'phone': '9123456780'};
const _devK = {'id': 'u_devk', 'name': 'Dev Kumar', 'phone': '9123456781'};

void main() {
  final sent = <http.Request>[];

  setUp(() {
    AppText.useGoogleFonts = false;
    sent.clear();
  });

  Future<void> open(WidgetTester tester, Map<String, dynamic> answer) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.7;
    addTearDown(tester.view.reset);
    api = fakeApi(log: sent, overrides: {'POST /api/quick-pay': (200, jsonEncode(answer))});
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const QuickPayScreen()));
    await tester.enterText(find.byType(TextField), 'pay dev 200 for chai');
    await tester.tap(find.text('Read it'));
    await tester.pumpAndSettle();
  }

  testWidgets('a clear sentence goes straight to the confirm screen', (tester) async {
    await open(tester, {
      'action': 'pay',
      'person': _dev,
      'amount_paise': 20000,
      'note': 'chai',
      'reply': 'Pay Dev ₹200 for chai? Check it and confirm.',
      'source': 'ai',
    });
    expect(jsonDecode(sent.single.body), {'text': 'pay dev 200 for chai'});
    expect(find.text('Pay Dev ₹200 for chai? Check it and confirm.'), findsOneWidget);
    expect(find.text('Read by AI'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Check and pay'), findsOneWidget);
    expect(find.text('Pay ₹200'), findsOneWidget);
  });

  testWidgets('when a name fits two people, nothing continues until one is picked', (tester) async {
    await open(tester, {
      'action': 'pay',
      'choices': [_dev, _devK],
      'amount_paise': 20000,
      'note': 'chai',
      'reply': 'Which one did you mean?',
      'source': 'rules',
    });
    expect(find.text('Dev Kumar'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    await tester.tap(find.text('Dev Kumar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Dev Kumar'), findsOneWidget);
    expect(find.text('Pay ₹200'), findsOneWidget);
  });

  testWidgets('a request opens the request screen filled in', (tester) async {
    await open(tester, {
      'action': 'request',
      'person': _dev,
      'amount_paise': 150000,
      'note': 'the cab',
      'reply': 'Ask Dev for ₹1,500 for the cab? Check it and send.',
      'source': 'rules',
    });
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Ask for ₹1,500'), findsOneWidget);
    expect(find.text('the cab'), findsOneWidget);
  });
}
