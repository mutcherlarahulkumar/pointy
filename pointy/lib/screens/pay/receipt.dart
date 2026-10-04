import 'package:flutter/material.dart';

import '../../api.dart';
import '../../models.dart';
import '../../money.dart';
import '../../dates.dart';
import '../../theme.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tag.dart';
import 'pay_draft.dart';

/// What was paid, from which wallet, and how much is left there now.
class ReceiptScreen extends StatefulWidget {
  const ReceiptScreen({super.key, required this.draft, required this.expense});

  final PayDraft draft;
  final Expense expense;

  @override
  State<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends State<ReceiptScreen> {
  late final Future<int> _balance = _loadBalance();

  // The wallet balance after the payment, read fresh from the server.
  Future<int> _loadBalance() async {
    if (widget.expense.tripId.isNotEmpty) return (await api.trip(widget.expense.tripId)).balancePaise;
    return (await api.me()).personalBalancePaise;
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.expense;
    final d = widget.draft;
    final isTrip = e.tripId.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Receipt'), automaticallyImplyLeading: false),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Center(child: Icon(Icons.check_circle, color: AppColors.pine500, size: 56)),
          const SizedBox(height: 8),
          Center(child: Text('Paid', style: AppText.heading(color: AppColors.pine700))),
          Center(child: Text(formatPaise(e.amountPaise), style: AppText.balance())),
          Center(child: Text('to ${e.payee.isEmpty ? d.payeeName : e.payee}', style: AppText.body(color: AppColors.slate))),
          const SizedBox(height: 20),
          SurfaceCard(
            child: Column(
              children: [
                _row('Wallet', isTrip ? '${d.trip?.name ?? 'Trip'} wallet' : 'Personal balance', trailing: Tag.wallet(isTrip)),
                if (isTrip)
                  _row('Split', '${e.shares.length} people'
                      '${e.isEvenSplit && e.shares.isNotEmpty ? ', ${formatPaise(e.shares.first.amountPaise)} each' : ''}'),
                _row('Category', categoryLabel(e.category)),
                if (e.placeName.isNotEmpty) _row('Place', e.placeName),
                _row('When', formatDateTime(e.at)),
                _row('PayPal reference', e.paypalPayoutId.isEmpty ? '—' : e.paypalPayoutId),
                FutureBuilder<int>(
                  future: _balance,
                  builder: (context, snap) => _row(
                    'Wallet balance now',
                    snap.hasData ? formatPaise(snap.data!) : '…',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Text(label, style: AppText.detail()),
            const SizedBox(width: 12),
            Expanded(
              child: Text(value, textAlign: TextAlign.right, style: AppText.body(weight: FontWeight.w600)),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing],
          ],
        ),
      );
}

