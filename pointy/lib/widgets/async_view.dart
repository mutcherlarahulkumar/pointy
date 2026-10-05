import 'package:flutter/material.dart';

import '../theme.dart';
import 'skeleton.dart';

/// Shows a pulsing outline of the page while [future] loads, a retry message
/// if it fails, and [builder] with the data once it arrives, faded in. When
/// [future] is replaced (a refresh), the old data stays on screen until the
/// new data arrives. A thin wrapper on FutureBuilder.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({super.key, required this.future, required this.builder, this.onRetry});

  final Future<T> future;
  final Widget Function(BuildContext context, T data) builder;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: future,
      builder: (context, snap) {
        final Widget child;
        if (snap.hasData && !(snap.hasError && snap.connectionState == ConnectionState.done)) {
          child = KeyedSubtree(key: const ValueKey('data'), child: builder(context, snap.data as T));
        } else if (snap.hasError) {
          child = ErrorView(key: const ValueKey('error'), message: '${snap.error}', onRetry: onRetry);
        } else {
          child = const Skeleton(key: ValueKey('loading'));
        }
        return AnimatedSwitcher(duration: const Duration(milliseconds: 300), child: child);
      },
    );
  }
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, color: AppColors.slate, size: 40),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: AppText.body(color: AppColors.slate)),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              TextButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shows an error from an action (a payment, a request) as a snackbar.
void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('$error'), backgroundColor: AppColors.error),
  );
}

void showMessage(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}
