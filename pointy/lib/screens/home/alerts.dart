import 'package:flutter/material.dart';

import '../../api.dart';
import '../../dates.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tile_icon.dart';
import '../trips/trip_shell.dart';

/// Alerts from the bell, grouped by day. Each row opens the screen that
/// deals with it.
class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  late Future<List<AlertItem>> _alerts = api.alerts();

  void _open(AlertItem a) {
    if (a.tripId.isEmpty) return;
    // Budget alerts open the Budget tab, deposit and assistant alerts the
    // Deposits tab, low-share alerts the Wallet tab (to add money), and
    // payments the Spending tab.
    final tab = switch (a.kind) {
      'budget' => 3,
      'deposit' || 'assistant' => 1,
      'share' => 0,
      _ => 2,
    };
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => TripShell(tripId: a.tripId, initialTab: tab)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Alerts')),
      body: AsyncView<List<AlertItem>>(
        future: _alerts,
        onRetry: () => setState(() => _alerts = api.alerts()),
        builder: (context, alerts) {
          if (alerts.isEmpty) return const ErrorView(message: 'No alerts yet.');
          final sorted = [...alerts]..sort((a, b) => b.at.compareTo(a.at));
          final rows = <Widget>[];
          DateTime? day;
          for (final a in sorted) {
            if (day == null || !sameDay(day, a.at)) {
              day = a.at;
              rows.add(SectionTitle(formatWeekday(a.at)));
            }
            rows.add(Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Card(
                child: ListTile(
                  leading: TileIcon(_icon(a.kind), background: _bg(a.kind), color: _fg(a.kind)),
                  title: Text(a.title, style: AppText.body(weight: FontWeight.w600)),
                  subtitle: Text('${a.body} · ${formatTime(a.at)}', style: AppText.detail()),
                  trailing: a.tripId.isEmpty ? null : const Icon(Icons.chevron_right),
                  onTap: () => _open(a),
                ),
              ),
            ));
          }
          return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: rows);
        },
      ),
    );
  }

  IconData _icon(String kind) => switch (kind) {
        'budget' => Icons.pie_chart_outline,
        'deposit' => Icons.savings_outlined,
        'share' => Icons.account_balance_wallet_outlined,
        'assistant' => Icons.auto_awesome,
        _ => Icons.payments_outlined,
      };

  Color _bg(String kind) => switch (kind) {
        'budget' || 'share' => AppColors.pendingBg,
        'assistant' => AppColors.amber100,
        _ => AppColors.pine100,
      };

  Color _fg(String kind) => switch (kind) {
        'budget' || 'share' => AppColors.pending,
        'assistant' => AppColors.amber900,
        _ => AppColors.pine700,
      };
}
