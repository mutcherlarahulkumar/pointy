import 'package:flutter/material.dart';

import '../theme.dart';

/// The AI sparkle (✦), the mark AI features use across apps (Gmail, Docs,
/// Notion). Pointy shows it on an amber tile wherever the AI is at work.
const aiIcon = Icons.auto_awesome;

class AiMark extends StatelessWidget {
  const AiMark({super.key, this.size = 30});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFD27A), AppColors.amber500],
        ),
        borderRadius: BorderRadius.circular(size * 0.32),
      ),
      child: Icon(aiIcon, size: size * 0.58, color: AppColors.amber900),
    );
  }
}

/// A small "✦ AI" label for anything the AI wrote or filled in.
class AiLabel extends StatelessWidget {
  const AiLabel({super.key, this.text = 'AI'});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: AppColors.amber100, borderRadius: BorderRadius.circular(20), border: Border.all(color: AppColors.amber500)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(aiIcon, size: 12, color: AppColors.amber900),
          const SizedBox(width: 3),
          Text(text, style: AppText.small(color: AppColors.amber900, weight: FontWeight.w700)),
        ],
      ),
    );
  }
}

/// A button for an action the AI performs ("Scan a receipt", "Read it"):
/// amber, with the sparkle, so it never looks like a payment button.
class AiButton extends StatelessWidget {
  const AiButton({super.key, required this.label, required this.onPressed, this.busy = false});

  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.amber100,
        foregroundColor: AppColors.amber900,
        disabledBackgroundColor: AppColors.amber100,
        disabledForegroundColor: AppColors.amber900.withValues(alpha: 0.6),
        side: const BorderSide(color: AppColors.amber500),
        minimumSize: const Size.fromHeight(48),
      ),
      onPressed: busy ? null : onPressed,
      icon: busy
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.amber900))
          : const Icon(aiIcon, size: 18),
      label: Text(label),
    );
  }
}
