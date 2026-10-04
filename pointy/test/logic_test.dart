import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy/dates.dart';
import 'package:pointy/models.dart';
import 'package:pointy/screens/pay/pay_draft.dart';
import 'package:pointy/screens/pay/scan.dart';
import 'package:pointy/screens/trips/budget_tab.dart';

import 'fakes.dart';

void main() {
  Trip goa() => Trip.fromJson(jsonDecode(fixture('trips_t_goa')) as Map<String, dynamic>);

  test('reads API times as IST wall-clock time', () {
    final t = parseIst('2026-10-13T20:42:00+05:30');
    expect(formatDateTime(t), 'Tue 13 Oct, 8:42 pm');
    expect(toIsoIst(DateTime(2026, 10, 20)), '2026-10-20T00:00:00+05:30');
  });

  test('a trip payment body carries the split and the participants in trip order', () {
    final d = PayDraft()
      ..trip = goa()
      ..wallet = 'trip'
      ..amountPaise = 1000
      ..description = 'Chai'
      ..splitMethod = 'shares';
    d.participants.addAll(['u_meera', 'u_you']);
    d.weights['u_you'] = 2;
    expect(d.shares(), {'u_you': 667, 'u_meera': 333});
    final body = d.toJson();
    expect(body['participants'], [
      {'user_id': 'u_you', 'weight': 2},
      {'user_id': 'u_meera', 'weight': 1},
    ]);
    expect(body.containsKey('confirm_over_budget'), isFalse);
  });

  test('exact amounts must add up before the split is accepted', () {
    final d = PayDraft()
      ..trip = goa()
      ..wallet = 'trip'
      ..amountPaise = 1000
      ..splitMethod = 'exact';
    d.participants.addAll(['u_you', 'u_asha']);
    d.exactPaise['u_you'] = 600;
    d.exactPaise['u_asha'] = 300;
    expect(d.shares(), isNull);
    d.exactPaise['u_asha'] = 400;
    expect(d.shares(), {'u_you': 600, 'u_asha': 400});
  });

  test('a personal payment is not split', () {
    final d = PayDraft()
      ..wallet = 'personal'
      ..amountPaise = 25050
      ..description = 'Medicine';
    final body = d.toJson(confirmOverBudget: true);
    expect(body.containsKey('participants'), isFalse);
    expect(body.containsKey('confirm_over_budget'), isFalse);
  });

  test('reads payees from scanned codes', () {
    final a = PayDraft();
    applyScannedCode(a, 'upi://pay?pa=shack@upi&pn=Beach%20shack&am=1840.50');
    expect(a.payeeName, 'Beach shack');
    expect(a.payeeEmail, 'shack@upi');
    expect(a.amountPaise, 184050);

    final b = PayDraft();
    applyScannedCode(b, 'shack@example.com');
    expect(b.payeeEmail, 'shack@example.com');
  });

  test('suggests moving budget from a category with room to one ahead of pace', () {
    final b = Budgets.fromJson(jsonDecode(fixture('budgets')) as Map<String, dynamic>);
    final move = suggestMove(b);
    expect(move, isNotNull);
    expect(move!.from.aheadOfPace, isFalse);
    expect(move.to.aheadOfPace, isTrue);
    expect(move.amountPaise % 50000, 0);
  });
}
