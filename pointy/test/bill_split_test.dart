import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pointy/api.dart';
import 'package:pointy/screens/money/bill_split.dart';
import 'package:pointy/theme.dart';

import 'fakes.dart';

const _me = 'u_c190dd4c22ea';
const _dev = 'u_e30a147f6407';

void main() {
  final sent = <http.Request>[];

  setUp(() {
    AppText.useGoogleFonts = false;
    sent.clear();
    api = fakeApi(log: sent, overrides: {
      'POST /api/splits/items': (
        201,
        '{"total_paise":115000,"parts":[{"user":{"id":"$_me","name":"Rahul"},"items":["Prawn curry"],"subtotal_paise":60000,"extra_paise":9000,"total_paise":69000},'
            '{"user":{"id":"$_dev","name":"Dev Mehta"},"items":["Paneer tikka"],"subtotal_paise":40000,"extra_paise":6000,"total_paise":46000}],"requests":[]}'
      ),
    });
    api.userId = _me;
  });

  Future<void> addItem(WidgetTester tester, String name, String price) async {
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Item'), name);
    await tester.enterText(find.widgetWithText(TextField, 'Price'), price);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
  }

  testWidgets('items, people, who had what, then requests by item', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.7;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const BillSplitScreen()));
    await tester.pumpAndSettle();
    await addItem(tester, 'Prawn curry', '600');
    await addItem(tester, 'Paneer tikka', '400');
    await tester.enterText(find.widgetWithText(TextField, 'Tax, service and tip'), '150');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue · ₹1,150'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dev Mehta'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue with 2 people'));
    await tester.pumpAndSettle();

    expect(find.text('2 items left to share'), findsOneWidget);
    // Prawn curry: you. Paneer tikka: Dev.
    await tester.tap(find.widgetWithText(FilterChip, 'You').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'Dev').last);
    await tester.pumpAndSettle();
    // The preview shares the ₹150 by what each had: 60% and 40%.
    expect(find.text('₹690'), findsOneWidget);
    expect(find.text('₹460'), findsOneWidget);

    await tester.tap(find.text('Send requests'));
    await tester.pumpAndSettle();
    final body = jsonDecode(sent.firstWhere((r) => r.url.path == '/api/splits/items').body) as Map<String, dynamic>;
    expect(body['extra_paise'], 15000);
    expect(body['items'], [
      {'name': 'Prawn curry', 'amount_paise': 60000, 'people': [_me]},
      {'name': 'Paneer tikka', 'amount_paise': 40000, 'people': [_dev]},
    ]);
    expect(find.text('Sent 1 request'), findsOneWidget);
  });

  testWidgets('removing someone after giving them an item un-assigns it', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.7;
    addTearDown(tester.view.reset);
    api = fakeApi(log: sent, overrides: {
      'GET /api/contacts': (200, '[{"id":"$_dev","name":"Dev Mehta","phone":"9123456780"},{"id":"u_meera","name":"Meera Iyer","phone":"9123456781"}]'),
    });
    api.userId = _me;
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const BillSplitScreen()));
    await tester.pumpAndSettle();
    await addItem(tester, 'Thali', '300');
    await tester.tap(find.text('Continue · ₹300'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dev Mehta'));
    await tester.tap(find.text('Meera Iyer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue with 3 people'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'Meera'));
    await tester.pumpAndSettle();
    expect(find.text('Send requests'), findsOneWidget);

    // Back: Meera was not there after all.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Meera Iyer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue with 2 people'));
    await tester.pumpAndSettle();
    expect(find.text('1 item left to share'), findsOneWidget);
  });

  test('a minus sign is a discount', () {
    expect(parseSignedPaise('-50'), -5000);
    expect(parseSignedPaise('120.5'), 12050);
    expect(parseSignedPaise('abc'), isNull);
  });
}
