import 'package:flutter/material.dart';

import '../../api.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/tag.dart';
import 'budget_tab.dart';
import 'deposits_tab.dart';
import 'spending_tab.dart';
import 'wallet_tab.dart';

/// Inside a trip: one shared header and four tabs, each its own screen.
class TripShell extends StatefulWidget {
  const TripShell({super.key, required this.tripId, this.initialTab = 0});

  final String tripId;

  /// 0 Overview, 1 Money in, 2 Spent, 3 Budget.
  final int initialTab;

  @override
  State<TripShell> createState() => _TripShellState();
}

class _TripShellState extends State<TripShell> {
  late Future<(Trip, Me)> _data = _load();

  Future<(Trip, Me)> _load() async => (await api.trip(widget.tripId), await api.me());

  /// Tabs call this after they change something, so the header updates.
  void _reload() => setState(() => _data = _load());

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      initialIndex: widget.initialTab,
      child: Scaffold(
        appBar: AppBar(title: const Text('Trip')),
        body: AsyncView<(Trip, Me)>(
          future: _data,
          onRetry: _reload,
          builder: (context, data) {
            final (trip, me) = data;
            return Column(
              children: [
                _Header(trip: trip),
                const TabBar(tabs: [Tab(text: 'Overview'), Tab(text: 'Money in'), Tab(text: 'Spent'), Tab(text: 'Budget')]),
                Expanded(
                  child: TabBarView(
                    children: [
                      WalletTab(trip: trip, me: me, onChanged: _reload),
                      DepositsTab(trip: trip, me: me, onChanged: _reload),
                      SpendingTab(trip: trip),
                      BudgetTab(trip: trip, onChanged: _reload),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.trip});

  final Trip trip;

  @override
  Widget build(BuildContext context) {
    final when = trip.when;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(trip.name, style: AppText.title()),
                Text([if (trip.place.isNotEmpty) trip.place, when, '${trip.members.length} people'].join(' · '), style: AppText.detail()),
              ],
            ),
          ),
          if (!trip.isOpen) Tag(categoryLabel(trip.status)),
        ],
      ),
    );
  }
}

/// Opens a trip. The route is named so flows started inside the trip can
/// return to it.
Route<void> tripRoute(String tripId, {int initialTab = 0}) => MaterialPageRoute(
      settings: const RouteSettings(name: 'trip'),
      builder: (_) => TripShell(tripId: tripId, initialTab: initialTab),
    );
