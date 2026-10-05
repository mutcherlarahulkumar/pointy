import 'package:flutter/material.dart';

import '../../api.dart';
import '../../money.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tag.dart';
import '../../widgets/tile_icon.dart';
import '../../widgets/wallet_card.dart';
import 'new_trip.dart';
import 'trip_shell.dart';

/// Your trips: open ones as green wallet cards, then finished ones.
class TripsScreen extends StatefulWidget {
  const TripsScreen({super.key});

  @override
  State<TripsScreen> createState() => _TripsScreenState();
}

class _TripsScreenState extends State<TripsScreen> {
  late Future<List<Trip>> _trips = api.trips();

  void _reload() => setState(() => _trips = api.trips());

  Future<void> _go(Widget screen) async {
    await Navigator.of(context).push(screen is TripShell ? tripRoute(screen.tripId) : MaterialPageRoute(builder: (_) => screen));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Trips', style: AppText.title()),
        actions: [
          IconButton(tooltip: 'Plan a trip', icon: const Icon(Icons.add_circle_outline), onPressed: () => _go(const NewTripScreen())),
        ],
      ),
      body: AsyncView<List<Trip>>(
        future: _trips,
        onRetry: _reload,
        builder: (context, trips) {
          if (trips.isEmpty) {
            return EmptyState(
              icon: Icons.luggage_rounded,
              title: 'No trips yet',
              body: 'Plan one, add friends by mobile number, and everyone chips into one wallet.',
              actionLabel: 'Plan a trip',
              onAction: () => _go(const NewTripScreen()),
            );
          }
          final open = trips.where((t) => t.isOpen).toList();
          final done = trips.where((t) => !t.isOpen).toList();
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
              children: [
                for (final t in open) ...[
                  WalletCard(
                    title: t.name,
                    subtitle: t.when,
                    balancePaise: t.balancePaise,
                    onTap: () => _go(TripShell(tripId: t.id)),
                    footer: Row(
                      children: [
                        Expanded(child: Text('Your share ${formatPaise(t.member(api.userId)?.leftPaise ?? 0)}')),
                        Text('${t.members.length} people'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                OutlinedButton.icon(icon: const Icon(Icons.add), label: const Text('Plan a new trip'), onPressed: () => _go(const NewTripScreen())),
                if (done.isNotEmpty) ...[
                  const SectionTitle('Finished'),
                  for (final t in done)
                    Card(
                      child: ListTile(
                        leading: const TileIcon(Icons.luggage_outlined),
                        title: Text(t.name, style: AppText.body(weight: FontWeight.w600)),
                        subtitle: Text('${t.when} · ${formatPaise(t.spentPaise)} spent', style: AppText.detail()),
                        trailing: const Tag('Settled'),
                        onTap: () => _go(TripShell(tripId: t.id)),
                      ),
                    ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
