import 'package:flutter/material.dart';

import '../../tabs.dart';
import '../../api.dart';
import '../../dates.dart';
import '../../models.dart';
import '../../money.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tag.dart';
import '../../widgets/tile_icon.dart';

/// Every movement of your money, newest first, tagged Trip or Personal.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, this.standalone = false});

  /// Opened on its own (from an alert) rather than as a bottom-bar tab.
  final bool standalone;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> with ReloadWhenShown {
  @override
  void reloadQuietly() => _reload();

  late Future<List<HistoryItem>> _history = api.history();
  String _filter = 'all'; // all, personal, trip

  void _reload() => setState(() { _history = api.history(); });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: widget.standalone ? const Text('History') : Text('History', style: AppText.title())),
      body: AsyncView<List<HistoryItem>>(
        future: _history,
        onRetry: _reload,
        builder: (context, items) {
          if (items.isEmpty) {
            return const EmptyState(
                icon: Icons.receipt_long_rounded, title: 'No activity yet', body: 'Payments, top-ups and refunds show up here.');
          }
          final shown = items.where((h) => _filter == 'all' || (_filter == 'trip') == h.isTrip).toList();
          final rows = <Widget>[];
          DateTime? day;
          for (final h in shown) {
            if (day == null || !sameDay(day, h.at)) {
              day = h.at;
              rows.add(SectionTitle(formatWeekday(h.at)));
            }
            rows.add(Padding(padding: const EdgeInsets.only(bottom: 8), child: _row(h)));
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    for (final (v, label) in const [('all', 'All'), ('personal', 'Personal'), ('trip', 'Trips')])
                      ChoiceChip(label: Text(label), selected: _filter == v, onSelected: (_) => setState(() => _filter = v)),
                  ],
                ),
                ...rows,
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _row(HistoryItem h) {
    final icon = switch (h.kind) {
      'deposit' => Icons.savings_outlined,
      'topup' => Icons.add_card_rounded,
      'refund' => Icons.undo_rounded,
      'received' => Icons.call_received_rounded,
      _ when !h.isTrip => Icons.north_east_rounded,
      _ => categoryIcon(h.category),
    };
    final sub = [if (h.subtitle.isNotEmpty) h.subtitle, formatTime(h.at)].join(' · ');
    return Card(
      child: ListTile(
        leading: TileIcon(icon,
            background: h.isIncoming ? AppColors.pine100 : (h.isTrip ? AppColors.pine100 : AppColors.personalBg),
            color: h.isIncoming ? AppColors.pine700 : (h.isTrip ? AppColors.pine700 : AppColors.personal)),
        title: Text(h.title, style: AppText.body(weight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(sub, style: AppText.detail(), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              Tag.wallet(h.isTrip),
            ],
          ),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('${h.isIncoming ? '+' : (h.kind == 'payment' ? '−' : '')}${formatPaise(h.amountPaise)}',
                style: AppText.body(weight: FontWeight.w700, color: h.isIncoming ? AppColors.pine700 : AppColors.ink)),
            if (h.isTrip && h.kind == 'payment') Text('your part ${formatPaise(h.yourPartPaise)}', style: AppText.small()),
          ],
        ),
      ),
    );
  }
}
