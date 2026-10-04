import 'package:flutter/material.dart';

import '../../money.dart';
import '../../theme.dart';
import '../../widgets/ai_card.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tag.dart';
import 'pay_draft.dart';
import 'review.dart';
import 'split.dart';
import 'step_scaffold.dart';

/// Step 3: which wallet pays, and how the payee gets the money.
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key, required this.draft, this.tripOnly = false});

  final PayDraft draft;
  final bool tripOnly;

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.tripOnly && widget.draft.trip != null) widget.draft.wallet = 'trip';
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    final trip = d.trip;
    final s = d.suggestion;
    final tripUsable = trip != null && trip.isOpen;
    return StepScaffold(
      step: 2,
      title: 'Which wallet pays?',
      buttonLabel: 'Next',
      onNext: () => Navigator.of(context).push(MaterialPageRoute(
        // A personal payment is not split, so it skips straight to Review.
        builder: (_) => d.isTrip ? SplitScreen(draft: d) : ReviewScreen(draft: d),
      )),
      children: [
        if (s != null)
          AiCard(
            title: s.wallet == 'trip' && tripUsable ? 'Pay from the ${trip.name} wallet' : 'Pay from your personal balance',
            body: s.title,
            reasons: s.reasons,
          ),
        const SizedBox(height: 12),
        if (tripUsable)
          _option(
            selected: d.wallet == 'trip',
            title: '${trip.name} wallet',
            subtitle: '${formatPaise(trip.balancePaise)} in the wallet · split with the group',
            tag: Tag.wallet(true),
            onTap: () => setState(() => d.wallet = 'trip'),
          ),
        if (!widget.tripOnly)
          _option(
            selected: d.wallet == 'personal',
            title: 'Personal balance',
            subtitle: '${formatPaise(d.me?.personalBalancePaise ?? 0)} available · just you',
            tag: Tag.wallet(false),
            onTap: () => setState(() => d.wallet = 'personal'),
          ),
        if (d.isTrip) ...[
          const SectionTitle('How the payee gets the money'),
          _option(
            selected: d.mode == 'paypal_payee',
            title: 'PayPal to the payee',
            subtitle: 'The trip wallet pays ${d.payeeName} directly',
            onTap: () => setState(() => d.mode = 'paypal_payee'),
          ),
          _option(
            selected: d.mode == 'reimburse',
            title: 'I paid, pay me back',
            subtitle: 'You already paid; the wallet sends the money to you',
            onTap: () => setState(() => d.mode = 'reimburse'),
          ),
        ],
      ],
    );
  }

  Widget _option({
    required bool selected,
    required String title,
    required String subtitle,
    Widget? tag,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? AppColors.pine100 : AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: selected ? AppColors.pine700 : AppColors.line, width: selected ? 2 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
                    color: selected ? AppColors.pine700 : AppColors.slate),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: AppText.body(weight: FontWeight.w600)),
                      Text(subtitle, style: AppText.detail()),
                    ],
                  ),
                ),
                if (tag != null) tag,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
