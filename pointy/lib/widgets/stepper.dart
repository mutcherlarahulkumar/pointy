import 'package:flutter/material.dart';

import '../theme.dart';

/// The labelled progress bar on top of each step of "Pay someone".
class PayStepper extends StatelessWidget {
  const PayStepper({super.key, required this.current, this.steps = payStepNames});

  static const payStepNames = ['Payee', 'Amount', 'Wallet', 'Split', 'Review'];

  /// Index into [steps] of the step being shown.
  final int current;
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        children: [
          for (var i = 0; i < steps.length; i++)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: i == steps.length - 1 ? 0 : 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: i <= current ? AppColors.pine700 : AppColors.mist,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      steps[i],
                      style: AppText.small(
                        color: i == current ? AppColors.pine700 : AppColors.slate,
                        weight: i == current ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
