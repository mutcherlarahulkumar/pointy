import 'package:flutter/material.dart';

import '../../api.dart';
import '../../models.dart';
import '../../money.dart';
import '../../theme.dart';
import '../../widgets/ai_card.dart';
import '../../widgets/async_view.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tag.dart';

/// Budget tab: the whole trip, a bar per category, a suggestion to move
/// money between categories, and alert switches.
class BudgetTab extends StatefulWidget {
  const BudgetTab({super.key, required this.trip, required this.onChanged});

  final Trip trip;
  final VoidCallback onChanged;

  @override
  State<BudgetTab> createState() => _BudgetTabState();
}

class _BudgetTabState extends State<BudgetTab> {
  late Future<Budgets> _budgets = api.budgets(widget.trip.id);

  // Alert switches. Kept on this screen for the demo; the backend always
  // sends the 80% and over-budget alerts.
  bool _warn80 = true;
  bool _warnOver = true;
  bool _daily = false;

  void _reload() {
    setState(() => _budgets = api.budgets(widget.trip.id));
    widget.onChanged();
  }

  Future<void> _applyMove(BudgetMove m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Move budget?'),
        content: Text('Move ${formatPaise(m.amountPaise)} from ${categoryLabel(m.from.category)} '
            'to ${categoryLabel(m.to.category)}. No money moves; only the limits change.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Move it')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.setBudgets(widget.trip.id, {
        m.from.category: m.from.limitPaise - m.amountPaise,
        m.to.category: m.to.limitPaise + m.amountPaise,
      });
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AsyncView<Budgets>(
      future: _budgets,
      onRetry: _reload,
      builder: (context, b) {
        final move = suggestMove(b);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Whole trip', style: AppText.detail()),
                  Text('${formatPaise(b.usedPaise)} of ${formatPaise(b.limitPaise)}', style: AppText.heading()),
                  const SizedBox(height: 10),
                  Bar(fraction: b.limitPaise == 0 ? 0 : b.usedPaise / b.limitPaise),
                  const SizedBox(height: 6),
                  Text('${b.percent}% used · day ${b.day} of ${b.days}', style: AppText.small()),
                ],
              ),
            ),
            const SectionTitle('By category'),
            for (final l in b.lines) _line(l),
            if (move != null && widget.trip.isOpen) ...[
              const SizedBox(height: 8),
              AiCard(
                title: 'Move ${formatPaise(move.amountPaise)} from ${categoryLabel(move.from.category)} '
                    'to ${categoryLabel(move.to.category)}',
                body: '${categoryLabel(move.to.category)} is ahead of pace; '
                    '${categoryLabel(move.from.category)} is likely to have money left.',
                reasons: ['Day ${b.day} of ${b.days}', '${categoryLabel(move.to.category)} at ${move.to.percent}%'],
                actionLabel: 'Review the move',
                onTap: () => _applyMove(move),
              ),
            ],
            const SectionTitle('Alerts'),
            SurfaceCard(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('When a category reaches 80%'),
                    value: _warn80,
                    onChanged: (v) => setState(() => _warn80 = v),
                  ),
                  SwitchListTile(
                    title: const Text('When a category goes over'),
                    value: _warnOver,
                    onChanged: (v) => setState(() => _warnOver = v),
                  ),
                  SwitchListTile(
                    title: const Text('A summary each evening'),
                    value: _daily,
                    onChanged: (v) => setState(() => _daily = v),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _line(BudgetLine l) {
    final color = l.percent >= 100 ? AppColors.error : (l.percent >= 80 ? AppColors.amber500 : AppColors.pine500);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(categoryLabel(l.category), style: AppText.body(weight: FontWeight.w600))),
                if (l.aheadOfPace) const Tag('Ahead of pace', kind: TagKind.pending),
              ],
            ),
            const SizedBox(height: 8),
            Bar(fraction: l.limitPaise == 0 ? 0 : l.usedPaise / l.limitPaise, color: color),
            const SizedBox(height: 6),
            Text(
              l.limitPaise == 0
                  ? '${formatPaise(l.usedPaise)} spent · no budget set'
                  : '${formatPaise(l.usedPaise)} of ${formatPaise(l.limitPaise)} · ${l.percent}%',
              style: AppText.small(),
            ),
          ],
        ),
      ),
    );
  }
}

class BudgetMove {
  final BudgetLine from;
  final BudgetLine to;
  final int amountPaise;
  BudgetMove(this.from, this.to, this.amountPaise);
}

/// Suggests moving budget from the category most likely to have money left
/// to the one furthest ahead of pace. At the current pace a category ends
/// the trip at used × days / day; the move covers the shortfall, capped by
/// what the other category should have spare, rounded down to ₹500.
BudgetMove? suggestMove(Budgets b) {
  if (b.day <= 0 || b.days <= 0) return null;
  int projected(BudgetLine l) => l.usedPaise * b.days ~/ b.day;
  BudgetLine? to;
  for (final l in b.lines) {
    if (l.aheadOfPace && l.limitPaise > 0 && projected(l) > l.limitPaise) {
      if (to == null || projected(l) - l.limitPaise > projected(to) - to.limitPaise) to = l;
    }
  }
  if (to == null) return null;
  BudgetLine? from;
  for (final l in b.lines) {
    if (l == to || l.aheadOfPace || l.limitPaise <= 0) continue;
    final spare = l.limitPaise - projected(l);
    if (spare > 0 && (from == null || spare > from.limitPaise - projected(from))) from = l;
  }
  if (from == null) return null;
  final need = projected(to) - to.limitPaise;
  final spare = from.limitPaise - projected(from);
  const step = 50000; // ₹500
  final amount = ((need < spare ? need : spare) ~/ step) * step;
  return amount > 0 ? BudgetMove(from, to, amount) : null;
}
