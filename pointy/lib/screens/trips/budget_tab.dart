import 'package:flutter/material.dart';

import '../../api.dart';
import '../../models.dart';
import '../../money.dart';
import '../../theme.dart';
import '../../widgets/ai_card.dart';
import '../../widgets/async_view.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tag.dart';
import '../../widgets/tile_icon.dart';

/// Budget tab: the whole trip, one row per category (tap to set its limit),
/// and a suggestion to move budget between categories.
class BudgetTab extends StatefulWidget {
  const BudgetTab({super.key, required this.trip, required this.onChanged});

  final Trip trip;
  final VoidCallback onChanged;

  @override
  State<BudgetTab> createState() => _BudgetTabState();
}

class _BudgetTabState extends State<BudgetTab> {
  late Future<Budgets> _budgets = api.budgets(widget.trip.id);

  void _reload() {
    setState(() { _budgets = api.budgets(widget.trip.id); });
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

  // Sets one category's limit. Only the limit changes; no money moves.
  Future<void> _edit(BudgetLine l) async {
    final field = TextEditingController(text: l.limitPaise == 0 ? '' : paiseToInput(l.limitPaise));
    final paise = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${categoryLabel(l.category)} budget'),
        content: TextField(
          controller: field,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(prefixText: '₹ ', hintText: 'For the whole trip', helperText: 'Leave empty for no budget'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, parseToPaise(field.text) ?? 0), child: const Text('Save')),
        ],
      ),
    );
    field.dispose();
    if (paise == null) return;
    try {
      await api.setBudgets(widget.trip.id, {l.category: paise});
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
        final open = widget.trip.isOpen;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (b.limitPaise > 0)
              SurfaceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Whole trip', style: AppText.detail()),
                    Text('${formatPaise(b.usedPaise)} of ${formatPaise(b.limitPaise)}', style: AppText.heading()),
                    const SizedBox(height: 10),
                    Bar(fraction: b.usedPaise / b.limitPaise),
                  ],
                ),
              )
            else
              Text('Set a limit for any category and Pointy warns you at 80% and when it goes over.', style: AppText.detail()),
            SectionTitle(open ? 'Tap a category to set its budget' : 'By category'),
            SurfaceCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < b.lines.length; i++) ...[
                    if (i > 0) const Divider(indent: 16),
                    _line(b.lines[i], open),
                  ],
                ],
              ),
            ),
            if (move != null && open) ...[
              const SizedBox(height: 16),
              AiCard(
                title: 'Move ${formatPaise(move.amountPaise)} from ${categoryLabel(move.from.category)} '
                    'to ${categoryLabel(move.to.category)}',
                body: '${categoryLabel(move.to.category)} is ahead of pace; '
                    '${categoryLabel(move.from.category)} is likely to have money left.',
                actionLabel: 'Review the move',
                onTap: () => _applyMove(move),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _line(BudgetLine l, bool open) {
    final color = l.percent >= 100 ? AppColors.error : (l.percent >= 80 ? AppColors.amber500 : AppColors.pine500);
    final set = l.limitPaise > 0;
    return InkWell(
      onTap: open ? () => _edit(l) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(categoryIcon(l.category), size: 20, color: AppColors.pine700),
                const SizedBox(width: 10),
                Expanded(child: Text(categoryLabel(l.category), style: AppText.body(weight: FontWeight.w600))),
                if (l.aheadOfPace) ...[const Tag('Ahead of pace', kind: TagKind.pending), const SizedBox(width: 8)],
                Text(
                  set ? '${formatPaise(l.usedPaise)} of ${formatPaise(l.limitPaise)}' : (l.usedPaise > 0 ? '${formatPaise(l.usedPaise)} spent' : 'No budget'),
                  style: AppText.detail(),
                ),
              ],
            ),
            if (set) ...[
              const SizedBox(height: 8),
              Bar(fraction: l.usedPaise / l.limitPaise, color: color),
            ],
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
