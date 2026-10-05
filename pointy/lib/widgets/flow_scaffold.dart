import 'package:flutter/material.dart';

import '../theme.dart';
import 'stepper.dart';

/// The frame every multi-step form shares: a labelled progress bar, one
/// question as the title, the content, and one button at the bottom.
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
    this.busy = false,
    this.footer,
  });

  final String appBarTitle;

  /// Step labels for the progress bar; null hides it.
  final List<String>? steps;
  final int step;
  final String title;
  final String? subtitle;
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
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                Text(title, style: AppText.title()),
                if (subtitle != null) ...[
                  const SizedBox(height: 6),
                  Text(subtitle!, style: AppText.body(color: AppColors.slate)),
                ],
                const SizedBox(height: 20),
                ...children,
              ],
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
                        : Text(buttonLabel),
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
