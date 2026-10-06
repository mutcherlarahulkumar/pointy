import 'package:flutter/material.dart';

import '../../api.dart';
import '../../dates.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tile_icon.dart';
import '../history/history.dart';
import '../money/requests.dart';
import '../trips/trip_shell.dart';

/// Alerts from the bell, grouped by day. Each row opens the screen that
/// deals with it. Opening this screen clears the unread badge.
class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  late Future<List<AlertItem>> _alerts = api.alerts();

  @override
  void initState() {
    super.initState();
    api.markAlertsSeen().catchError((_) {});
  }

  void _open(AlertItem a) {
    final Widget? screen = switch (a.kind) {
      'request' => const RequestsScreen(),
      'money' => const HistoryScreen(standalone: true),
      'budget' when a.tripId.isNotEmpty => TripShell(tripId: a.tripId, initialTab: 3),
      'deposit' || 'assistant' when a.tripId.isNotEmpty => TripShell(tripId: a.tripId, initialTab: 1),
      'payment' when a.tripId.isNotEmpty => TripShell(tripId: a.tripId, initialTab: 2),
      _ when a.tripId.isNotEmpty => TripShell(tripId: a.tripId),
      _ => null,
    };
    if (screen is TripShell) {
      Navigator.of(context).push(tripRoute(screen.tripId, initialTab: screen.initialTab));
    } else if (screen != null) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Alerts')),
      body: AsyncView<List<AlertItem>>(
        future: _alerts,
        onRetry: () => setState(() { _alerts = api.alerts(); }),
        builder: (context, alerts) {
          if (alerts.isEmpty) {
            return const EmptyState(icon: Icons.notifications_none_rounded, title: 'All quiet', body: 'Payments, requests and budget warnings show up here.');
          }
          final rows = <Widget>[];
          DateTime? day;
          for (final a in alerts) {
            if (day == null || !sameDay(day, a.at)) {
              day = a.at;
              rows.add(SectionTitle(formatWeekday(a.at)));
            }
            final (icon, bg, fg) = _style(a.kind);
            rows.add(Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Card(
                child: ListTile(
                  leading: TileIcon(icon, background: bg, color: fg),
                  title: Text(a.title, style: AppText.body(weight: FontWeight.w600)),
                  subtitle: Text('${a.body} · ${formatTime(a.at)}', style: AppText.detail()),
                  onTap: () => _open(a),
                ),
              ),
            ));
          }
          return RefreshIndicator(
            onRefresh: () async => setState(() { _alerts = api.alerts(); }),
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: rows),
          );
        },
      ),
    );
  }

  (IconData, Color, Color) _style(String kind) => switch (kind) {
        'budget' => (Icons.pie_chart_outline, AppColors.pendingBg, AppColors.pending),
        'share' => (Icons.account_balance_wallet_outlined, AppColors.pendingBg, AppColors.pending),
        'request' => (Icons.call_received_rounded, AppColors.pendingBg, AppColors.pending),
        'assistant' => (Icons.auto_awesome, AppColors.amber100, AppColors.amber900),
        'group_buy' => (Icons.shopping_bag_outlined, AppColors.amber100, AppColors.amber900),
        'deposit' => (Icons.savings_outlined, AppColors.pine100, AppColors.pine700),
        'trip' => (Icons.luggage_outlined, AppColors.pine100, AppColors.pine700),
        'money' => (Icons.payments_outlined, AppColors.personalBg, AppColors.personal),
        _ => (Icons.receipt_outlined, AppColors.pine100, AppColors.pine700),
      };
}
