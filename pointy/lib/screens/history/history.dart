import 'package:flutter/material.dart';

import '../../api.dart';
import '../../dates.dart';
import '../../models.dart';
import '../../money.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/tag.dart';
import '../../widgets/tile_icon.dart';

/// Every payment, newest first, tagged Trip or Personal.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late Future<List<HistoryItem>> _history = api.history();

  void _reload() => setState(() => _history = api.history());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('History', style: AppText.title())),
      body: AsyncView<List<HistoryItem>>(
        future: _history,
        onRetry: _reload,
        builder: (context, items) {
          if (items.isEmpty) return const ErrorView(message: 'No payments yet.');
          final sorted = [...items]..sort((a, b) => b.at.compareTo(a.at));
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
              itemCount: sorted.length,
              separatorBuilder: (context, i) => const SizedBox(height: 8),
              itemBuilder: (context, i) => _row(sorted[i]),
            ),
          );
        },
      ),
    );
  }

  Widget _row(HistoryItem h) {
    final incoming = h.kind == 'deposit' || h.kind == 'refund';
    final where = [
      if (h.isTrip && h.tripName.isNotEmpty) h.tripName,
      if (h.placeName.isNotEmpty) h.placeName,
      formatDateTime(h.at),
    ].join(' · ');
    return Card(
      child: ListTile(
        leading: TileIcon(switch (h.kind) {
          'deposit' => Icons.savings_outlined,
          'refund' => Icons.undo,
          _ => categoryIcon(h.category),
        }),
        title: Text(h.title, style: AppText.body(weight: FontWeight.w600)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(where, style: AppText.detail()),
              const SizedBox(height: 4),
              Tag.wallet(h.isTrip),
            ],
          ),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('${incoming ? '+' : ''}${formatPaise(h.amountPaise)}',
                style: AppText.body(weight: FontWeight.w600, color: incoming ? AppColors.pine700 : AppColors.ink)),
            if (h.isTrip && h.kind == 'payment')
              Text('your part ${formatPaise(h.yourPartPaise)}', style: AppText.small()),
          ],
        ),
      ),
    );
  }
}
