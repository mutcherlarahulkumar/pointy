import 'package:flutter/material.dart';

import '../../money.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../widgets/avatar.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tile_icon.dart';
import '../../widgets/wallet_card.dart';
import '../money/top_up.dart';
import 'add_people.dart';
import 'expense_flow.dart';
import 'settle.dart';

/// Wallet tab: the balance, your share, what you can do, and who is in.
class WalletTab extends StatelessWidget {
  const WalletTab({super.key, required this.trip, required this.me, required this.onChanged});

  final Trip trip;
  final Me me;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final mine = trip.member(me.user.id);
    final organiser = trip.organiserId == me.user.id;
    Future<void> go(Widget screen) async {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
      onChanged();
    }

    return RefreshIndicator(
      onRefresh: () async => onChanged(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          WalletCard(
            title: '${trip.name} wallet',
            balancePaise: trip.balancePaise,
            subtitle: '${formatPaise(trip.depositedPaise)} in · ${formatPaise(trip.spentPaise)} spent',
            footer: Row(
              children: [
                Expanded(child: Text('Your share ${formatPaise(mine?.leftPaise ?? 0)} left')),
                Text('You put in ${formatPaise(mine?.depositedPaise ?? 0)}'),
              ],
            ),
          ),
          const SectionTitle('What you can do'),
          _action(Icons.add_circle_outline, 'Add money', 'Top up your share from your balance or PayPal.',
              trip.isOpen ? () => go(TopUpScreen(trip: trip)) : null),
          _action(Icons.receipt_long_outlined, 'Add an expense', 'Paid for the group? Get paid back and split it.',
              trip.isOpen ? () => go(ExpenseAmountScreen(trip: trip)) : null),
          _action(Icons.handshake_outlined, 'Settle up', 'Close the trip; what is left goes back to everyone.',
              () => go(SettleScreen(trip: trip, me: me))),
          SectionTitle('People', action: organiser && trip.isOpen ? 'Add people' : null, onAction: () => go(AddPeopleScreen(trip: trip))),
          SurfaceCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                for (final m in trip.memberDetails)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Avatar(m.user.name),
                    title: Text(m.user.id == me.user.id ? '${m.user.name} (you)' : m.user.name, style: AppText.body(weight: FontWeight.w600)),
                    subtitle: Text(
                        '${m.user.id == trip.organiserId ? 'Organiser · ' : ''}put in ${formatPaise(m.depositedPaise)} · used ${formatPaise(m.usedPaise)}',
                        style: AppText.detail()),
                    trailing: Text(formatPaise(m.leftPaise), style: AppText.body(weight: FontWeight.w700)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _action(IconData icon, String title, String line, VoidCallback? onTap) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Card(
          child: ListTile(
            enabled: onTap != null,
            leading: TileIcon(icon),
            title: Text(title, style: AppText.body(weight: FontWeight.w600)),
            subtitle: Text(line, style: AppText.detail()),
            trailing: const Icon(Icons.chevron_right),
            onTap: onTap,
          ),
        ),
      );
}
