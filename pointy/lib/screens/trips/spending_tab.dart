import 'package:flutter/material.dart';

import '../../api.dart';
import '../../dates.dart';
import '../../money.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/empty_state.dart';
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
        return RefreshIndicator(
          onRefresh: () async => setState(() => _expenses = api.expenses(t.id)),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SurfaceCard(
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Spent by the group', style: AppText.detail()),
                          Text(formatPaise(t.spentPaise), style: AppText.balance()),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('${expenses.length}', style: AppText.title()),
                        Text('payments', style: AppText.detail()),
                      ],
                    ),
                  ],
                ),
              ),
              const SectionTitle('Per person'),
              SurfaceCard(
                child: Column(
                  children: [
                    for (final m in t.memberDetails)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
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
              if (newestFirst.isEmpty)
                const EmptyState(icon: Icons.receipt_long_outlined, title: 'Nothing spent yet', body: 'Add an expense from the Wallet tab.'),
              for (final e in newestFirst)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Card(
                    child: ListTile(
                      leading: TileIcon(categoryIcon(e.category)),
                      title: Text(e.description, style: AppText.body(weight: FontWeight.w600)),
                      subtitle: Text(
                        '${formatDateTime(e.at)}\n${e.mode == 'reimburse' ? 'Paid back to ${t.nameOf(e.payeeUserId)}' : 'Paid to ${e.payee}'}',
                        style: AppText.detail(),
                      ),
                      isThreeLine: true,
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(formatPaise(e.amountPaise), style: AppText.body(weight: FontWeight.w700)),
                          Text(
                            e.isEvenSplit && e.shares.isNotEmpty ? '${formatPaise(e.shares.first.amountPaise)} each' : 'split ${e.shares.length} ways',
                            style: AppText.small(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
