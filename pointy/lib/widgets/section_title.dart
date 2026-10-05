import 'package:flutter/material.dart';

import '../theme.dart';

/// A small heading above a group of rows, with an optional action on the right.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.action, this.onAction});

  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(text, style: AppText.heading())),
          if (action != null)
            TextButton(onPressed: onAction, child: Text(action!, style: AppText.detail(color: AppColors.pine700))),
        ],
      ),
    );
  }
}

/// A plain white card with padding, used for most grouped content.
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({super.key, required this.child, this.padding = const EdgeInsets.all(16)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Card(child: Padding(padding: padding, child: child));
}

/// A thin progress bar on a mist track.
class Bar extends StatelessWidget {
  const Bar({super.key, required this.fraction, Color? color, this.extra = 0, this.extraColor}) : _color = color;

  /// 0..1 of the bar filled with [color].
  final double fraction;
  final Color? _color;
  Color get color => _color ?? AppColors.pine500;

  /// A second part drawn after the first, for "this payment" on the budget check.
  final double extra;
  final Color? extraColor;

  @override
  Widget build(BuildContext context) {
    final a = fraction.clamp(0.0, 1.0);
    final b = extra.clamp(0.0, 1.0 - a);
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 8,
        child: Row(
          children: [
            if (a > 0) Expanded(flex: (a * 1000).round(), child: Container(color: color)),
            if (b > 0) Expanded(flex: (b * 1000).round(), child: Container(color: extraColor ?? AppColors.amber500)),
            if (a + b < 1) Expanded(flex: ((1 - a - b) * 1000).round(), child: Container(color: AppColors.mist)),
          ],
        ),
      ),
    );
  }
}
