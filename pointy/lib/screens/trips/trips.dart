import 'package:flutter/material.dart';

import '../../api.dart';
import '../../dates.dart';
import '../../models.dart';
import '../../money.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tag.dart';
import '../../widgets/tile_icon.dart';
import '../../widgets/wallet_card.dart';
import 'new_trip.dart';
import 'trip_shell.dart';

/// Your trips: the active one as a green wallet card, then finished ones.
class TripsScreen extends StatefulWidget {
  const TripsScreen({super.key});

  @override
  State<TripsScreen> createState() => _TripsScreenState();
}

class _TripsScreenState extends State<TripsScreen> {
  late Future<List<Trip>> _trips = api.trips();

  void _reload() => setState(() => _trips = api.trips());

  Future<void> _open(Trip t) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TripShell(tripId: t.id)));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Trips', style: AppText.title())),
      body: AsyncView<List<Trip>>(
        future: _trips,
        onRetry: _reload,
        builder: (context, trips) {
          final open = trips.where((t) => t.isOpen).toList();
          final done = trips.where((t) => !t.isOpen).toList();
          final me = api.userId;
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
              children: [
                for (final t in open) ...[
                  WalletCard(
                    title: t.name,
                    subtitle: t.day > 0 && t.day <= t.days ? 'Day ${t.day} of ${t.days}' : formatDay(t.start),
                    balancePaise: t.balancePaise,
                    onTap: () => _open(t),
                    footer: Row(
                      children: [
                        Expanded(child: Text('Your share ${formatPaise(t.member(me)?.leftPaise ?? 0)} left')),
                        Text('${t.members.length} people'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (open.isEmpty)
                  SurfaceCard(child: Text('No trip on right now.', style: AppText.body(color: AppColors.slate))),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Plan a new trip'),
                  onPressed: () async {
                    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NewTripScreen()));
                    _reload();
                  },
                ),
                if (done.isNotEmpty) ...[
                  const SectionTitle('Finished trips'),
                  for (final t in done)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const TileIcon(Icons.luggage_outlined),
                      title: Text(t.name, style: AppText.body(weight: FontWeight.w600)),
                      subtitle: Text('${formatDay(t.start)} – ${formatDay(t.end)} · ${formatPaise(t.spentPaise)} spent',
                          style: AppText.detail()),
                      trailing: const Tag('Settled', kind: TagKind.plain),
                      onTap: () => _open(t),
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
