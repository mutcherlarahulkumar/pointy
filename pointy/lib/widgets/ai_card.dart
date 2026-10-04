import 'package:flutter/material.dart';

import '../theme.dart';
import 'tag.dart';

/// The yellow card with a spark icon. Every AI suggestion uses it, and it
/// never does anything until the person taps it.
class AiCard extends StatelessWidget {
  const AiCard({
    super.key,
    required this.title,
    this.body,
    this.reasons = const [],
    this.actionLabel,
    this.onTap,
  });

  final String title;
  final String? body;

  /// Why the AI suggests this, shown as small tags.
  final List<String> reasons;
  final String? actionLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.amber100,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(color: AppColors.amber500, borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.auto_awesome, size: 18, color: AppColors.amber900),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppText.body(color: AppColors.amber900, weight: FontWeight.w600)),
                    if (body != null) ...[
                      const SizedBox(height: 4),
                      Text(body!, style: AppText.detail(color: AppColors.amber900)),
                    ],
                    if (reasons.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [for (final r in reasons) Tag(r, kind: TagKind.ai)],
                      ),
                    ],
                    if (actionLabel != null) ...[
                      const SizedBox(height: 10),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(actionLabel!, style: AppText.detail(color: AppColors.amber900, weight: FontWeight.w700)),
                          const SizedBox(width: 4),
                          const Icon(Icons.arrow_forward, size: 14, color: AppColors.amber900),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
