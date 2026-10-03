import 'package:flutter/material.dart';

import '../../api.dart';
import '../../dates.dart';
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

  /// 0 Wallet, 1 Deposits, 2 Spending, 3 Budget.
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
                const TabBar(tabs: [Tab(text: 'Wallet'), Tab(text: 'Deposits'), Tab(text: 'Spending'), Tab(text: 'Budget')]),
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
    final when = trip.day > 0 && trip.day <= trip.days
        ? 'Day ${trip.day} of ${trip.days}'
        : '${formatDay(trip.start)} – ${formatDay(trip.end)}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(trip.name, style: AppText.title()),
                Text('${trip.place} · $when · ${trip.members.length} people', style: AppText.detail()),
              ],
            ),
          ),
          trip.isOpen ? const Tag('Open', kind: TagKind.trip) : Tag(categoryLabel(trip.status)),
        ],
      ),
    );
  }
}
