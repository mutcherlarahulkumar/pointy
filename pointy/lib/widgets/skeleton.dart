import 'package:flutter/material.dart';

import '../theme.dart';

/// Grey blocks that gently pulse where content is about to appear. Smoother
/// than a spinner: the page keeps its shape while it loads.
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.children});

  /// The shapes to pulse. Defaults to a balance card and a few rows.
  final List<Widget>? children;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final children = widget.children ??
        [
          const SkeletonBox(height: 150, radius: 24),
          const SizedBox(height: 20),
          for (var i = 0; i < 5; i++) ...[
            const Row(children: [
              SkeletonBox(width: 44, height: 44, radius: 22),
              SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SkeletonBox(height: 14, width: 160),
                  SizedBox(height: 8),
                  SkeletonBox(height: 12, width: 100),
                ]),
              ),
              SkeletonBox(height: 16, width: 60),
            ]),
            const SizedBox(height: 18),
          ],
        ];
    return FadeTransition(
      opacity: Tween(begin: 0.45, end: 1.0).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: children,
      ),
    );
  }
}

/// One rounded grey block of a [Skeleton].
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({super.key, this.width, required this.height, this.radius = 8});

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(color: AppColors.mist, borderRadius: BorderRadius.circular(radius)),
      );
}
