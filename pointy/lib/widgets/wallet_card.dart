import 'package:flutter/material.dart';

import '../money.dart';
import '../theme.dart';

/// The green card with a dashed tear line. Only a trip wallet looks like
/// this, so people can tell trip money from their own at a glance.
class WalletCard extends StatelessWidget {
  const WalletCard({
    super.key,
    required this.title,
    required this.balancePaise,
    this.subtitle,
    this.footer,
    this.onTap,
  });

  final String title;
  final int balancePaise;
  final String? subtitle;

  /// Shown below the tear line, for example "Your share ₹798 left".
  final Widget? footer;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.pine700,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.account_balance_wallet_outlined, color: AppColors.pine100, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(title, style: AppText.detail(color: AppColors.pine100, weight: FontWeight.w600))),
                  // Shares the row with the title, so large text cannot push it off the card.
                  if (subtitle != null)
                    Flexible(
                      child: Text(subtitle!,
                          maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.end, style: AppText.small(color: AppColors.pine100)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(formatPaise(balancePaise), style: AppText.balance(color: Colors.white)),
              Text('in the trip wallet', style: AppText.detail(color: AppColors.pine100)),
              if (footer != null) ...[
                const SizedBox(height: 16),
                DashedLine(color: AppColors.pine500),
                const SizedBox(height: 12),
                DefaultTextStyle(style: AppText.detail(color: Colors.white), child: footer!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A horizontal dashed line, used as the "tear line" on a trip wallet.
class DashedLine extends StatelessWidget {
  const DashedLine({super.key, required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      const dash = 6.0, gap = 4.0;
      final count = (box.maxWidth / (dash + gap)).floor();
      return Row(
        children: List.generate(
          count,
          (_) => Container(width: dash, height: 1.5, margin: const EdgeInsets.only(right: gap), color: color),
        ),
      );
    });
  }
}
