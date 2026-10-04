import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../widgets/stepper.dart';

/// The frame every step of "Pay someone" shares: the labelled progress bar,
/// a question as the title, the content, and one button at the bottom.
class StepScaffold extends StatelessWidget {
  const StepScaffold({
    super.key,
    required this.step,
    required this.title,
    required this.children,
    required this.buttonLabel,
    required this.onNext,
  });

  final int step;
  final String title;
  final List<Widget> children;
  final String buttonLabel;

  /// Null disables the button (for example while nothing is chosen yet).
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pay someone')),
      body: Column(
        children: [
          PayStepper(current: step),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Text(title, style: AppText.title()),
                const SizedBox(height: 16),
                ...children,
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: FilledButton(onPressed: onNext, child: Text(buttonLabel)),
            ),
          ),
        ],
      ),
    );
  }
}
