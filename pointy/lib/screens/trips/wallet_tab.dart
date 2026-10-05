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

/// Overview tab: the trip wallet, the three things you can do with it (one
/// line each), and who is in.
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
            subtitle: 'shared by ${trip.members.length} ${trip.members.length == 1 ? 'person' : 'people'}',
            footer: Text('Your share: ${formatPaise(mine?.leftPaise ?? 0)}'),
          ),
          if (trip.isOpen) ...[
            const SectionTitle('What do you want to do?'),
            SurfaceCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _Action(
                    icon: Icons.savings_outlined,
                    title: 'Put money in',
                    line: 'From your Pointy balance into your share',
                    onTap: () => go(TopUpScreen(trip: trip)),
                  ),
                  const Divider(indent: 72),
                  _Action(
                    icon: Icons.send_to_mobile_rounded,
                    title: 'Pay from the trip',
                    line: 'Pay anyone on Pointy; the cost is split',
                    onTap: () => go(ExpenseAmountScreen(trip: trip)),
                  ),
                  if (organiser) ...[
                    const Divider(indent: 72),
                    _Action(
                      icon: Icons.handshake_outlined,
                      title: 'Close the trip',
                      line: 'What is left goes back to everyone',
                      onTap: () => go(SettleScreen(trip: trip, me: me)),
                    ),
                  ],
                ],
              ),
            ),
          ] else ...[
            const SizedBox(height: 16),
            OutlinedButton(onPressed: () => go(SettleScreen(trip: trip, me: me)), child: const Text('See how it was settled')),
          ],
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
                    subtitle: m.user.id == trip.organiserId ? Text('Organiser', style: AppText.detail()) : null,
                    trailing: Text(formatPaise(m.leftPaise), style: AppText.body(weight: FontWeight.w700)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One thing to do with the wallet: an icon, a title and one short line.
class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.title, required this.line, required this.onTap});

  final IconData icon;
  final String title;
  final String line;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: TileIcon(icon),
      title: Text(title, style: AppText.body(weight: FontWeight.w700)),
      subtitle: Text(line, style: AppText.detail()),
      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.slate),
      onTap: onTap,
    );
  }
}
