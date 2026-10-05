import 'package:flutter/material.dart';

import '../money.dart';
import '../theme.dart';

/// Your own balance: an indigo card, so it is never confused with the green
/// trip wallet.
class PersonalCard extends StatelessWidget {
  const PersonalCard({super.key, required this.balancePaise, this.actions = const [], this.caption, this.onWhere});

  final int balancePaise;
  final List<Widget> actions;
  final String? caption;

  /// Opens "Where is my money?" from a link in the corner.
  final VoidCallback? onWhere;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          colors: [AppColors.personal, AppColors.personalDark],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_balance_wallet_outlined, color: AppColors.personalBg, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text('Your balance', style: AppText.detail(color: AppColors.personalBg, weight: FontWeight.w600))),
              if (onWhere != null)
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: onWhere,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.help_outline_rounded, size: 16, color: AppColors.personalBg),
                        const SizedBox(width: 4),
                        Text('Where is it?', overflow: TextOverflow.ellipsis, style: AppText.small(color: AppColors.personalBg, weight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            // The balance counts up or down to its new value (whole paise, no
            // floating point).
            child: TweenAnimationBuilder<int>(
              tween: IntTween(end: balancePaise),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => Text(formatPaise(v), style: AppText.balance(color: Colors.white)),
            ),
          ),
          if (caption != null) Text(caption!, style: AppText.small(color: AppColors.personalBg)),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 16),
            Row(children: [for (var i = 0; i < actions.length; i++) ...[if (i > 0) const SizedBox(width: 8), Expanded(child: actions[i])]]),
          ],
        ],
      ),
    );
  }
}

/// A pill button for use on the dark cards.
class CardButton extends StatelessWidget {
  const CardButton({super.key, required this.icon, required this.label, required this.onTap, this.primary = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// The amber "Add" button; the others are translucent.
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: primary ? AppColors.amber500 : Colors.white.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: primary ? AppColors.amber900 : Colors.white),
              const SizedBox(width: 6),
              Flexible(
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.detail(color: primary ? AppColors.amber900 : Colors.white, weight: FontWeight.w700)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
