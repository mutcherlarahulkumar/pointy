import 'package:flutter/material.dart';

import '../theme.dart';

enum TagKind { trip, personal, pending, error, ai, plain }

/// A small rounded label. Every payment carries a Trip or Personal tag.
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.kind = TagKind.plain});

  /// The Trip or Personal tag for a payment from that wallet.
  factory Tag.wallet(bool isTrip, {Key? key}) =>
      Tag(isTrip ? 'Trip' : 'Personal', key: key, kind: isTrip ? TagKind.trip : TagKind.personal);

  final String text;
  final TagKind kind;

  @override
  Widget build(BuildContext context) {
    final (fg, bg) = switch (kind) {
      TagKind.trip => (AppColors.pine900, AppColors.pine100),
      TagKind.personal => (AppColors.personal, AppColors.personalBg),
      TagKind.pending => (AppColors.pending, AppColors.pendingBg),
      TagKind.error => (AppColors.error, AppColors.errorBg),
      TagKind.ai => (AppColors.amber900, AppColors.surface),
      TagKind.plain => (AppColors.slate, AppColors.mist),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(text, style: AppText.small(color: fg)),
    );
  }
}
