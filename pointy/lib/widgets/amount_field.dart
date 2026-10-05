import 'package:flutter/material.dart';

import '../money.dart';
import '../theme.dart';

/// The big "₹ 0" amount input with optional quick-pick chips below.
class AmountField extends StatelessWidget {
  const AmountField({super.key, required this.controller, required this.onChanged, this.chipsRupees = const [], this.autofocus = true, this.hint});

  final TextEditingController controller;
  final VoidCallback onChanged;
  final List<int> chipsRupees;
  final bool autofocus;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final bad = controller.text.isNotEmpty && parseToPaise(controller.text) == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // "₹" and the number sit together in the middle and grow as you type.
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text('₹', style: AppText.hero(color: AppColors.slate)),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 48, maxWidth: 260),
              child: IntrinsicWidth(
                child: TextField(
                  controller: controller,
                  autofocus: autofocus,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: AppText.hero(),
                  decoration: InputDecoration(
                    hintText: '0',
                    hintStyle: AppText.hero(color: AppColors.lineStrong),
                    filled: false,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                  onChanged: (_) => onChanged(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Center(
          child: Text(
            bad ? 'Enter rupees, with up to two decimal places' : (hint ?? ''),
            style: AppText.detail(color: bad ? AppColors.error : AppColors.slate),
          ),
        ),
        if (chipsRupees.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final r in chipsRupees)
                ActionChip(
                  label: Text(formatPaise(r * 100)),
                  onPressed: () {
                    controller.text = '$r';
                    onChanged();
                  },
                ),
            ],
          ),
        ],
      ],
    );
  }
}
