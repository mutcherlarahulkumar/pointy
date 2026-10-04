import 'package:flutter/material.dart';

import '../../api.dart';
import '../../dates.dart';
import '../../models.dart';
import '../../money.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tile_icon.dart';

/// Spending tab: what the group spent, per person, and every expense.
class SpendingTab extends StatefulWidget {
  const SpendingTab({super.key, required this.trip});

  final Trip trip;

  @override
  State<SpendingTab> createState() => _SpendingTabState();
}

class _SpendingTabState extends State<SpendingTab> {
  late Future<List<Expense>> _expenses = api.expenses(widget.trip.id);

  @override
  Widget build(BuildContext context) {
    final t = widget.trip;
    return AsyncView<List<Expense>>(
      future: _expenses,
      onRetry: () => setState(() => _expenses = api.expenses(t.id)),
      builder: (context, expenses) {
        final newestFirst = [...expenses]..sort((a, b) => b.at.compareTo(a.at));
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Spent by the group', style: AppText.detail()),
                  Text(formatPaise(t.spentPaise), style: AppText.balance()),
                  Text('${expenses.length} payments', style: AppText.detail()),
                ],
              ),
            ),
            const SectionTitle('Per person'),
            SurfaceCard(
              child: Column(
                children: [
                  for (final m in t.memberDetails)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(child: Text(m.user.name, style: AppText.body())),
                          Text(formatPaise(m.usedPaise), style: AppText.body(weight: FontWeight.w600)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SectionTitle('Every expense'),
            for (final e in newestFirst)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Card(
                  child: ListTile(
                    leading: TileIcon(categoryIcon(e.category)),
                    title: Text(e.description, style: AppText.body(weight: FontWeight.w600)),
                    subtitle: Text(
                      '${formatDateTime(e.at)}${e.placeName.isEmpty ? '' : ' · ${e.placeName}'}\n'
                      'Paid by ${t.nameOf(e.paidBy)}',
                      style: AppText.detail(),
                    ),
                    isThreeLine: true,
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(formatPaise(e.amountPaise), style: AppText.body(weight: FontWeight.w600)),
                        Text(
                          e.isEvenSplit && e.shares.isNotEmpty
                              ? '${formatPaise(e.shares.first.amountPaise)} each'
                              : 'split ${e.shares.length} ways',
                          style: AppText.small(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
