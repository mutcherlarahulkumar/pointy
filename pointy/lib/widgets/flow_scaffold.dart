import 'package:flutter/material.dart';

import '../theme.dart';
import 'stepper.dart';

/// The frame every multi-step form shares: a progress bar with an icon per
/// step, "Step 2 of 3", one question as the title, one line of help (the
/// subtitle, or else a tip saying what to do), the content, and one button at
/// the bottom.
class FlowScaffold extends StatelessWidget {
  const FlowScaffold({
    super.key,
    required this.title,
    required this.children,
    required this.buttonLabel,
    required this.onNext,
    this.appBarTitle = '',
    this.steps,
    this.step = 0,
    this.subtitle,
    this.hint,
    this.busy = false,
    this.footer,
  });

  final String appBarTitle;

  /// Step labels for the progress bar; null hides it.
  final List<String>? steps;
  final int step;
  final String title;
  final String? subtitle;

  /// What to do on this step, in one short sentence, shown with the step's icon.
  final String? hint;
  final List<Widget> children;
  final String buttonLabel;

  /// Null disables the button (for example while nothing is chosen yet).
  final VoidCallback? onNext;
  final bool busy;

  /// Shown under the button, for a small note.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(appBarTitle)),
      body: Column(
        children: [
          if (steps != null) PayStepper(current: step, steps: steps!),
          Expanded(
            child: _Entrance(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                children: [
                  if (steps != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('Step ${step + 1} of ${steps!.length}',
                          style: AppText.small(color: AppColors.pine700, weight: FontWeight.w700)),
                    ),
                  Text(title, style: AppText.title()),
                  if (subtitle != null) ...[
                    const SizedBox(height: 6),
                    Text(subtitle!, style: AppText.body(color: AppColors.slate)),
                  ],
                  // One line of help is enough: the tip only shows when there is
                  // no subtitle.
                  if (hint != null && subtitle == null) ...[
                    const SizedBox(height: 14),
                    StepHint(icon: steps == null ? Icons.lightbulb_outline_rounded : (stepIcons[steps![step]] ?? Icons.lightbulb_outline_rounded), text: hint!),
                  ],
                  const SizedBox(height: 20),
                  ...children,
                ],
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton(
                    onPressed: busy ? null : onNext,
                    child: busy
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(child: Text(buttonLabel, overflow: TextOverflow.ellipsis)),
                              if (onNext != null && buttonLabel == 'Continue') ...[
                                const SizedBox(width: 8),
                                const Icon(Icons.arrow_forward_rounded, size: 20),
                              ],
                            ],
                          ),
                  ),
                  if (footer != null) ...[const SizedBox(height: 8), footer!],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "What to do now": the step's icon and one sentence on a soft green card.
class StepHint extends StatelessWidget {
  const StepHint({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: AppColors.pine100, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppColors.pine700),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: AppText.detail(color: AppColors.pine900, weight: FontWeight.w500))),
        ],
      ),
    );
  }
}

/// Fades and lifts the step's content in when the step opens.
class _Entrance extends StatelessWidget {
  const _Entrance({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, 12 * (1 - v)), child: child),
      ),
      child: child,
    );
  }
}
