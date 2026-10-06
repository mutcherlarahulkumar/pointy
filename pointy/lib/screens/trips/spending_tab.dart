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

/// Spent tab: what the group spent and each payment, newest first.
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
      onRetry: () => setState(() { _expenses = api.expenses(t.id); }),
      builder: (context, expenses) {
        final newestFirst = [...expenses]..sort((a, b) => b.at.compareTo(a.at));
        return RefreshIndicator(
          onRefresh: () async => setState(() { _expenses = api.expenses(t.id); }),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (newestFirst.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 48),
                  child: EmptyState(
                      icon: Icons.receipt_long_outlined, title: 'Nothing spent yet', body: 'Pay from the trip on the Overview tab and it shows up here.'),
                )
              else ...[
                SurfaceCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Spent by the group', style: AppText.detail()),
                      Text(formatPaise(t.spentPaise), style: AppText.balance()),
                      Text('${newestFirst.length} ${newestFirst.length == 1 ? 'payment' : 'payments'}', style: AppText.detail()),
                    ],
                  ),
                ),
                const SectionTitle('Payments'),
                SurfaceCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (var i = 0; i < newestFirst.length; i++) ...[
                        if (i > 0) const Divider(indent: 72),
                        _row(t, newestFirst[i]),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _row(Trip t, Expense e) {
    final to = e.mode == 'reimburse' ? 'Paid back to ${t.nameOf(e.payeeUserId)}' : 'To ${e.payee}';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: TileIcon(categoryIcon(e.category)),
      title: Text(e.description, style: AppText.body(weight: FontWeight.w600)),
      subtitle: Text('$to · ${formatDay(e.at)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.detail()),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(formatPaise(e.amountPaise), style: AppText.body(weight: FontWeight.w700)),
          if (e.isEvenSplit && e.shares.length > 1) Text('${formatPaise(e.shares.first.amountPaise)} each', style: AppText.small()),
        ],
      ),
    );
  }
}
