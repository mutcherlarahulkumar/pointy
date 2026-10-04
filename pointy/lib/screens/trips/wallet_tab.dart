import 'package:flutter/material.dart';

import '../../models.dart';
import '../../money.dart';
import '../../theme.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tile_icon.dart';
import '../../widgets/wallet_card.dart';
import '../pay/pay_draft.dart';
import 'add_money.dart';
import 'settle.dart';

/// Wallet tab: the balance, your share, and what you can do with the wallet.
class WalletTab extends StatelessWidget {
  const WalletTab({super.key, required this.trip, required this.me, required this.onChanged});

  final Trip trip;
  final Me me;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final mine = trip.member(me.user.id);
    Future<void> go(Widget screen) async {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
      onChanged();
    }

    return ListView(
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
        const SectionTitle('Your share'),
        SurfaceCard(
          child: Row(
            children: [
              _stat('Put in', mine?.depositedPaise ?? 0),
              _stat('Used', mine?.usedPaise ?? 0),
              _stat('Left', mine?.leftPaise ?? 0),
            ],
          ),
        ),
        const SectionTitle('What you can do'),
        _action(
          Icons.add_circle_outline,
          'Add money',
          'Top up your share of the wallet with PayPal.',
          trip.isOpen ? () => go(AddMoneyScreen(trip: trip)) : null,
        ),
        _action(
          Icons.payments_outlined,
          'Pay from this wallet',
          'Pay someone and split it with the group.',
          trip.isOpen
              ? () async {
                  final d = PayDraft()
                    ..trip = trip
                    ..wallet = 'trip';
                  d.participants.addAll(trip.members);
                  await startPay(context, draft: d, tripOnly: true);
                  onChanged();
                }
              : null,
        ),
        _action(
          Icons.handshake_outlined,
          'Settle up',
          'End the trip and send back what is left to each person.',
          () => go(SettleScreen(trip: trip, me: me)),
        ),
      ],
    );
  }

  Widget _stat(String label, int paise) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: AppText.detail()),
            Text(formatPaise(paise), style: AppText.heading()),
          ],
        ),
      );

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
