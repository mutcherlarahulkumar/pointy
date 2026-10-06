import 'package:flutter/material.dart';

import '../theme.dart';

/// One "label ... value" line on a review or receipt card. A long value
/// (a person's full name) wraps on the right instead of running off the
/// screen.
class DetailRow extends StatelessWidget {
  const DetailRow(this.label, this.value, {super.key, this.color, this.bold = false});

  final String label;
  final String value;
  final Color? color;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppText.detail()),
          const SizedBox(width: 12),
          Expanded(
            child: Text(value,
                textAlign: TextAlign.end,
                style: AppText.body(weight: bold ? FontWeight.w700 : FontWeight.w600, color: color ?? AppColors.ink)),
          ),
        ],
      ),
    );
  }
}
