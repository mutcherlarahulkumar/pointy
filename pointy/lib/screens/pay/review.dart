import 'package:flutter/material.dart';

import '../../api.dart';
import '../../location.dart';
import '../../models.dart';
import '../../money.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tag.dart';
import '../../widgets/stepper.dart';
import 'budget_check.dart';
import 'pay_draft.dart';
import 'receipt.dart';

/// Step 5: every choice on one screen, then Pay.
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key, required this.draft});

  final PayDraft draft;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  // One key per attempt. A double tap or a network retry reuses it, so the
  // backend replays the first answer instead of paying twice.
  String _key = newIdempotencyKey();
  bool _paying = false;

  Future<void> _pay({bool confirmOverBudget = false}) async {
    final d = widget.draft;
    setState(() => _paying = true);
    try {
      final loc = await coarseLocation();
      final body = d.toJson(confirmOverBudget: confirmOverBudget, lat: loc?.lat, lng: loc?.lng);
      final expense = d.isTrip
          ? await api.addExpense(d.trip!.id, body, key: _key)
          : await api.payPersonal(body, key: _key);
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => ReceiptScreen(draft: d, expense: expense)),
        (route) => route.isFirst,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _paying = false);
      if (e.code == 'budget_warning' && e.details != null) {
        // The backend stored this 409 under the current key, so sending
        // again (with confirm_over_budget) needs a new key.
        _key = newIdempotencyKey();
        final choice = await Navigator.of(context).push<BudgetChoice>(MaterialPageRoute(
          builder: (_) => BudgetCheckScreen(trip: d.trip!, check: BudgetCheck.fromJson(e.details!)),
        ));
        if (choice == BudgetChoice.payAnyway) await _pay(confirmOverBudget: true);
        if (choice == BudgetChoice.raised) await _pay();
        return;
      }
      showError(context, _explain(e));
    }
  }

  // Turns the error codes a payment can hit into plain words.
  String _explain(ApiException e) => switch (e.code) {
        'insufficient_share' => '${e.message}. Ask them to add money, or leave them out of the split.',
        'insufficient_balance' => 'Your personal balance does not cover this payment.',
        'trip_closed' => 'This trip is settled, so its wallet cannot pay any more.',
        'paypal_error' => 'PayPal did not accept the payment: ${e.message}. Nothing was taken.',
        _ => e.message,
      };

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    final shares = d.isTrip ? d.shares() ?? const <String, int>{} : const <String, int>{};
    final myId = d.me?.user.id ?? 'u_you';
    final balanceNow = d.isTrip ? d.trip!.balancePaise : (d.me?.personalBalancePaise ?? 0);
    return Scaffold(
      appBar: AppBar(title: const Text('Pay someone')),
      body: Column(
        children: [
          const PayStepper(current: 4),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Text('Check and pay', style: AppText.title()),
                const SizedBox(height: 16),
                Center(child: Text(formatPaise(d.amountPaise), style: AppText.balance())),
                Center(child: Text('to ${d.payeeName}', style: AppText.body(color: AppColors.slate))),
                const SizedBox(height: 16),
                SurfaceCard(
                  child: Column(
                    children: [
                      _row('For', d.description),
                      _row('Category', categoryLabel(d.category)),
                      _row('Wallet', d.isTrip ? '${d.trip!.name} wallet' : 'Personal balance',
                          trailing: Tag.wallet(d.isTrip)),
                      if (d.isTrip)
                        _row('Payee gets it by', d.mode == 'reimburse' ? 'Paying you back' : 'PayPal to the payee'),
                      if (d.isTrip) _row('Split', _splitText(d, shares.length)),
                      if (d.isTrip) _row('Your part', formatPaise(shares[myId] ?? 0)),
                      _row('Wallet balance after', formatPaise(balanceNow - d.amountPaise)),
                    ],
                  ),
                ),
                if (d.isTrip) ...[
                  const SectionTitle('Each person'),
                  SurfaceCard(
                    child: Column(
                      children: [for (final e in shares.entries) _row(d.trip!.nameOf(e.key), formatPaise(e.value))],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Icon(Icons.fingerprint, color: AppColors.slate, size: 18),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('On a phone you confirm with your fingerprint or face before it pays.',
                          style: AppText.detail()),
                    ),
                  ],
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: FilledButton(
                onPressed: _paying ? null : _pay,
                child: _paying
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text('Pay ${formatPaise(d.amountPaise)}'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _splitText(PayDraft d, int people) => switch (d.splitMethod) {
        'shares' => 'By shares, $people people',
        'exact' => 'Exact amounts, $people people',
        _ => 'Equally, $people ways',
      };

  Widget _row(String label, String value, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label, style: AppText.detail())),
          Text(value, style: AppText.body(weight: FontWeight.w600)),
          if (trailing != null) ...[const SizedBox(width: 8), trailing],
        ],
      ),
    );
  }
}
