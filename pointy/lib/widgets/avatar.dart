import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';

/// A round avatar with someone's initials. The colour comes from their name,
/// so the same person always looks the same.
class Avatar extends StatelessWidget {
  const Avatar(this.name, {super.key, this.size = 44});

  final String name;
  final double size;

  static List<(Color, Color)> get _palette => [
    (AppColors.pine100, AppColors.pine700),
    (AppColors.personalBg, AppColors.personal),
    (AppColors.amber100, AppColors.amber900),
    (AppColors.pendingBg, AppColors.pending),
    (Color(0xFFF1E4F6), Color(0xFF6A2D82)),
  ];

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = _palette[name.codeUnits.fold<int>(0, (a, b) => a + b) % _palette.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Text(initials(name), style: AppText.body(color: fg, weight: FontWeight.w700).copyWith(fontSize: size * 0.36)),
    );
  }
}
