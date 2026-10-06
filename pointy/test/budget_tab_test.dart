import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pointy/api.dart';
import 'package:pointy/screens/trips/budget_tab.dart';
import 'package:pointy/theme.dart';

import 'fakes.dart';

const _budgets = '{"limit_paise":500000,"used_paise":100000,"percent":20,"day":2,"days":5,'
    '"lines":[{"category":"food","limit_paise":500000,"used_paise":100000,"percent":20}]}';

void main() {
  final sent = <http.Request>[];

  setUp(() {
    AppText.useGoogleFonts = false;
    sent.clear();
    api = fakeApi(log: sent, overrides: {
      'GET /api/trips/trip_7a6c1f73654c/budgets': (200, _budgets),
      'PUT /api/trips/trip_7a6c1f73654c/budgets': (200, _budgets),
    });
  });

  Future<void> openFoodBudget(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.7;
    addTearDown(tester.view.reset);
    final trip = (await api.trips()).first;
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: BudgetTab(trip: trip, onChanged: () {}))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Food'));
    await tester.pumpAndSettle();
  }

  testWidgets('saving a category budget closes the dialog cleanly', (tester) async {
    await openFoodBudget(tester);
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), '6000');
    await tester.pump();
    expect(find.text('6000'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(sent.where((r) => r.method == 'PUT').single.body, '{"food":600000}');
  });

  testWidgets('a mistyped budget is not saved as "no budget"', (tester) async {
    await openFoodBudget(tester);
    await tester.enterText(find.byType(TextField), '6.000.0');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(sent.where((r) => r.method == 'PUT'), isEmpty);
  });
}
