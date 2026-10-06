import 'package:flutter/material.dart';

import '../theme.dart';

/// One chat bubble: green on the right for you, white on the left for the
/// assistant, with the corner nearest the speaker squared off.
class ChatBubble extends StatelessWidget {
  const ChatBubble({super.key, required this.mine, required this.child});

  final bool mine;
  final Widget child;

  /// The text style for plain text inside a bubble.
  static TextStyle textStyle(bool mine) => AppText.body(color: mine ? Colors.white : AppColors.ink);

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: mine ? AppColors.pine700 : AppColors.surface,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(mine ? 18 : 4),
          bottomRight: Radius.circular(mine ? 4 : 18),
        ),
      ),
      child: child,
    );
  }
}
