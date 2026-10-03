import 'package:flutter/material.dart';

import '../../api.dart';
import '../../models.dart';
import '../../money.dart';
import 'payee.dart';

/// Everything chosen so far in "Pay someone". Each step screen reads and
/// fills in this one object, then passes it to the next step.
class PayDraft {
  // Payee
  String payeeName = '';
  String payeeEmail = '';
  String payeeUserId = ''; // set when the payee is someone on Pointy

  // Amount
  int amountPaise = 0;
  String description = '';
  String category = 'other';

  // Wallet: "trip" or "personal". mode is how the payee gets the money:
  // "paypal_payee" (PayPal to the payee) or "reimburse" (I paid, pay me back).
  String wallet = 'trip';
  String mode = 'paypal_payee';

  // Split (trip wallet only): "equal", "shares" or "exact".
  String splitMethod = 'equal';
  final Set<String> participants = {};
  final Map<String, int> weights = {};
  final Map<String, int> exactPaise = {};

  // Context the AI used, sent with the payment.
  String placeName = '';
  String placeType = '';
  Suggestion? suggestion;

  // Loaded once by the payee step.
  Me? me;
  Trip? trip;

  bool get isTrip => wallet == 'trip' && trip != null;

  /// Fills defaults from an AI suggestion. Nothing is paid until the person
  /// goes through every step and taps Pay.
  void applySuggestion(Suggestion s) {
    suggestion = s;
    if (s.category.isNotEmpty) category = s.category;
    if (s.wallet.isNotEmpty) wallet = s.wallet;
    if (s.splitMethod.isNotEmpty) splitMethod = s.splitMethod;
    if (s.participants.isNotEmpty) {
      participants
        ..clear()
        ..addAll(s.participants);
    }
  }

  /// The people sharing the payment, in trip order so the split matches the
  /// backend's (leftover paise go to the first people in the list).
  List<String> get orderedParticipants =>
      (trip?.members ?? const <String>[]).where(participants.contains).toList();

  /// Each person's part as the backend will compute it, or null when the
  /// exact amounts do not add up yet.
  Map<String, int>? shares() {
    final ids = orderedParticipants;
    if (ids.isEmpty || amountPaise <= 0) return null;
    if (splitMethod == 'exact') {
      final parts = {for (final id in ids) id: exactPaise[id] ?? 0};
      final sum = parts.values.fold<int>(0, (a, b) => a + b);
      return sum == amountPaise ? parts : null;
    }
    final w = [for (final id in ids) splitMethod == 'shares' ? (weights[id] ?? 1) : 1];
    final parts = splitPaise(amountPaise, w);
    return {for (var i = 0; i < ids.length; i++) ids[i]: parts[i]};
  }

  /// The JSON body for POST /api/trips/{id}/expenses or /api/payments/personal.
  Map<String, dynamic> toJson({bool confirmOverBudget = false, double? lat, double? lng}) {
    final body = <String, dynamic>{
      'description': description,
      'category': category,
      'amount_paise': amountPaise,
      'payee': payeeName,
      'payee_email': payeeEmail,
      'place_name': placeName,
      'place_type': placeType,
      if (lat != null) 'lat': lat,
      if (lng != null) 'lng': lng,
    };
    if (isTrip) {
      body['mode'] = mode;
      body['split_method'] = splitMethod;
      body['participants'] = [
        for (final id in orderedParticipants)
          {
            'user_id': id,
            if (splitMethod == 'shares') 'weight': weights[id] ?? 1,
            if (splitMethod == 'exact') 'exact_paise': exactPaise[id] ?? 0,
          }
      ];
      if (confirmOverBudget) body['confirm_over_budget'] = true;
    }
    return body;
  }
}

/// Opens step 1 of "Pay someone". [draft] can come pre-filled, for example
/// from an AI suggestion, a scanned code or a "Pay again" contact.
Future<void> startPay(BuildContext context, {PayDraft? draft, bool tripOnly = false}) {
  return Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => PayeeScreen(draft: draft ?? PayDraft(), tripOnly: tripOnly)),
  );
}

/// Loads who you are and your active trip into the draft.
Future<void> loadPayContext(PayDraft d) async {
  d.me ??= await api.me();
  if (d.trip == null && d.me!.activeTripId.isNotEmpty) {
    d.trip = await api.trip(d.me!.activeTripId);
    if (d.participants.isEmpty) d.participants.addAll(d.trip!.members);
  }
  if (d.trip == null || !d.trip!.isOpen) d.wallet = 'personal';
}
