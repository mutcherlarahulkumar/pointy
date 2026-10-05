import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// Six dots that fill as the PIN is typed.
class PinDots extends StatelessWidget {
  const PinDots({super.key, required this.length, this.error = false});

  final int length;
  final bool error;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < 6; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            margin: const EdgeInsets.symmetric(horizontal: 8),
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i < length ? (error ? AppColors.error : AppColors.pine700) : Colors.transparent,
              border: Border.all(color: error ? AppColors.error : AppColors.lineStrong, width: 2),
            ),
          ),
      ],
    );
  }
}

/// A phone-style number pad. It reports digits and backspace; the screen
/// keeps the PIN.
class NumberPad extends StatelessWidget {
  const NumberPad({super.key, required this.onDigit, required this.onBackspace, this.enabled = true});

  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    Widget key(String label, {VoidCallback? onTap, Widget? child}) => Expanded(
          child: AspectRatio(
            aspectRatio: 1.6,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: enabled ? onTap : null,
                  child: Center(child: child ?? Text(label, style: AppText.title())),
                ),
              ),
            ),
          ),
        );
    Widget digit(String d) => key(d, onTap: () {
          HapticFeedback.selectionClick();
          onDigit(d);
        });
    return Column(
      children: [
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Row(children: [for (final d in row) digit(d)]),
        Row(
          children: [
            key('', child: const SizedBox()),
            digit('0'),
            key('', onTap: onBackspace, child: const Icon(Icons.backspace_outlined, color: AppColors.slate)),
          ],
        ),
      ],
    );
  }
}
