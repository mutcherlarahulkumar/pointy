import 'package:flutter/material.dart';

import '../../api.dart';
import '../../models.dart';
import '../../money.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/section_title.dart';

enum BudgetChoice { payAnyway, raised }

/// Shown only when the backend answers a payment with budget_warning. It
/// pops with what the person chose, or null for "Go back".
class BudgetCheckScreen extends StatefulWidget {
  const BudgetCheckScreen({super.key, required this.trip, required this.check});

  final Trip trip;
  final BudgetCheck check;

  @override
  State<BudgetCheckScreen> createState() => _BudgetCheckScreenState();
}

class _BudgetCheckScreenState extends State<BudgetCheckScreen> {
  bool _busy = false;

  // Raises the limit to cover this payment, rounded up to the next ₹1,000.
  int get _raisedLimit {
    const step = 100000;
    return ((widget.check.afterPaise + step - 1) ~/ step) * step;
  }

  Future<void> _raise() async {
    setState(() => _busy = true);
    try {
      await api.setBudgets(widget.trip.id, {widget.check.category: _raisedLimit});
      if (mounted) Navigator.of(context).pop(BudgetChoice.raised);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.check;
    final name = categoryLabel(c.category);
    final limit = c.limitPaise == 0 ? 1 : c.limitPaise;
    return Scaffold(
      appBar: AppBar(title: const Text('Budget check')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            c.over100 ? 'This goes over the $name budget' : 'This takes $name to ${c.percentAfter}%',
            style: AppText.title(),
          ),
          const SizedBox(height: 8),
          Text('${widget.trip.name} · $name budget ${formatPaise(c.limitPaise)}', style: AppText.detail()),
          const SizedBox(height: 20),
          Bar(
            fraction: c.usedPaise / limit,
            extra: c.thisPaymentPaise / limit,
            color: AppColors.pine500,
            extraColor: c.over100 ? AppColors.error : AppColors.amber500,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text('${c.percentBefore}% used', style: AppText.small()),
              const Spacer(),
              Text('${c.percentAfter}% after', style: AppText.small(color: AppColors.pending)),
            ],
          ),
          const SizedBox(height: 20),
          SurfaceCard(
            child: Column(
              children: [
                _row('Used so far', formatPaise(c.usedPaise)),
                _row('This payment', formatPaise(c.thisPaymentPaise)),
                _row(c.leftAfterPaise < 0 ? 'Over the budget' : 'Left after',
                    formatPaise(c.leftAfterPaise.abs()), color: c.leftAfterPaise < 0 ? AppColors.error : null),
              ],
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(BudgetChoice.payAnyway),
            child: const Text('Pay anyway'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy ? null : _raise,
            child: Text('Raise the budget to ${formatPaise(_raisedLimit)}'),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Go back')),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(child: Text(label, style: AppText.detail())),
            Text(value, style: AppText.body(weight: FontWeight.w600, color: color ?? AppColors.ink)),
          ],
        ),
      );
}
