import 'package:flutter/material.dart';

import '../theme.dart';

/// The icon for each step name used in the app's forms.
const stepIcons = <String, IconData>{
  'Who': Icons.person_search_rounded,
  'Payee': Icons.person_search_rounded,
  'Amount': Icons.currency_rupee_rounded,
  'Pay': Icons.fingerprint_rounded,
  'Wallet': Icons.account_balance_wallet_rounded,
  'Split': Icons.call_split_rounded,
  'Review': Icons.fact_check_rounded,
  'Bill': Icons.receipt_long_rounded,
  'People': Icons.group_rounded,
  'Trip': Icons.luggage_rounded,
  'Dates': Icons.event_rounded,
  'Money': Icons.savings_rounded,
  'Who paid': Icons.how_to_reg_rounded,
  'Number': Icons.phone_iphone_rounded,
  'Name': Icons.badge_rounded,
  'PIN': Icons.lock_rounded,
};

/// The progress bar on top of every multi-step form: one icon per step,
/// a tick on the steps already done, the current one filled in, joined by
/// a line that fills as you go.
class PayStepper extends StatelessWidget {
  const PayStepper({super.key, required this.current, required this.steps});

  /// Index into [steps] of the step being shown.
  final int current;
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Step ${current + 1} of ${steps.length}: ${steps[current]}',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < steps.length; i++) ...[
              if (i > 0)
                Expanded(
                  child: Padding(
                    // Lines up with the middle of the 32px circles.
                    padding: const EdgeInsets.only(top: 15),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: i <= current ? 1 : 0),
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOutCubic,
                      builder: (context, v, _) => ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(value: v, minHeight: 3, color: AppColors.pine700, backgroundColor: AppColors.mist),
                      ),
                    ),
                  ),
                ),
              _Dot(label: steps[i], state: i < current ? _State.done : (i == current ? _State.now : _State.next)),
            ],
          ],
        ),
      ),
    );
  }
}

enum _State { done, now, next }

class _Dot extends StatelessWidget {
  const _Dot({required this.label, required this.state});

  final String label;
  final _State state;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, border) = switch (state) {
      _State.done => (AppColors.pine100, AppColors.pine700, AppColors.pine100),
      _State.now => (AppColors.pine700, Colors.white, AppColors.pine700),
      _State.next => (AppColors.surface, AppColors.slate, AppColors.line),
    };
    final icon = state == _State.done ? Icons.check_rounded : (stepIcons[label] ?? Icons.circle_outlined);
    return SizedBox(
      width: 64,
      child: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
              border: Border.all(color: border, width: 1.5),
              boxShadow: state == _State.now ? [BoxShadow(color: AppColors.pine700.withValues(alpha: 0.25), blurRadius: 8, offset: const Offset(0, 2))] : null,
            ),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Icon(icon, key: ValueKey(icon), size: 17, color: fg),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.small(
              color: state == _State.next ? AppColors.slate : AppColors.pine700,
              weight: state == _State.now ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
