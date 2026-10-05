import 'package:flutter/material.dart';

import '../theme.dart';
import 'section_title.dart';

/// The end of a money flow: an animated tick, the amount and the details.
class SuccessScreen extends StatelessWidget {
  const SuccessScreen({
    super.key,
    required this.title,
    required this.amount,
    this.subtitle,
    this.rows = const [],
    this.doneLabel = 'Done',
    this.pending = false,
  });

  final String title;
  final String amount;
  final String? subtitle;

  /// Label and value pairs shown in a card.
  final List<(String, String)> rows;
  final String doneLabel;

  /// A request sent rather than money moved: an amber clock, not a tick.
  final bool pending;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              const Spacer(),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.4, end: 1),
                duration: const Duration(milliseconds: 450),
                curve: Curves.elasticOut,
                builder: (context, v, child) => Transform.scale(scale: v, child: child),
                child: Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(color: pending ? AppColors.amber500 : AppColors.pine500, shape: BoxShape.circle),
                  child: Icon(pending ? Icons.schedule_send_rounded : Icons.check_rounded, color: Colors.white, size: 52),
                ),
              ),
              const SizedBox(height: 20),
              Text(title, textAlign: TextAlign.center, style: AppText.heading(color: pending ? AppColors.pending : AppColors.pine700)),
              const SizedBox(height: 4),
              FittedBox(child: Text(amount, style: AppText.balance())),
              if (subtitle != null) Text(subtitle!, textAlign: TextAlign.center, style: AppText.body(color: AppColors.slate)),
              const SizedBox(height: 24),
              if (rows.isNotEmpty)
                SurfaceCard(
                  child: Column(
                    children: [
                      for (final (label, value) in rows)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(label, style: AppText.detail()),
                              const SizedBox(width: 16),
                              Expanded(child: Text(value, textAlign: TextAlign.right, style: AppText.body(weight: FontWeight.w600))),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              const Spacer(flex: 2),
              FilledButton(onPressed: () => Navigator.of(context).pop(), child: Text(doneLabel)),
            ],
          ),
        ),
      ),
    );
  }
}
