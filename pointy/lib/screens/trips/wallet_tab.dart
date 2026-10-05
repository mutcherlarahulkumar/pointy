import 'package:flutter/material.dart';

import '../../money.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../widgets/avatar.dart';
import '../../widgets/section_title.dart';
import '../../widgets/wallet_card.dart';
import '../money/top_up.dart';
import 'add_people.dart';
import 'expense_flow.dart';
import 'settle.dart';

/// Overview tab: the trip wallet, then the four steps of a trip in order,
/// each with where it stands and what to do, then who is in.
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

    final collectedAll = trip.targetPaise > 0 && trip.depositedPaise >= trip.targetPaise;
    final collected = trip.targetPaise == 0
        ? '${formatPaise(trip.depositedPaise)} put in so far'
        : '${formatPaise(trip.depositedPaise)} of ${formatPaise(trip.targetPaise)} collected';

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
          const SizedBox(height: 8),
          Text(
            'The wallet\'s money sits in Pointy\'s PayPal business account. Your share is what you put in, minus your part of what was spent.',
            style: AppText.small(),
          ),
          const SectionTitle('How this trip works'),
          _Step(
            n: 1,
            icon: Icons.savings_outlined,
            title: 'Put money in',
            status: collected,
            body: 'Everyone adds their part, from their Pointy balance or with PayPal.',
            done: collectedAll,
            action: trip.isOpen ? 'Put money in' : null,
            onAction: () => go(TopUpScreen(trip: trip)),
          ),
          _Step(
            n: 2,
            icon: Icons.storefront_outlined,
            title: 'Pay from the trip',
            status: trip.spentPaise == 0 ? 'Nothing paid yet' : '${formatPaise(trip.spentPaise)} paid so far',
            body: 'Pay a shop or person by PayPal straight from the wallet, or get paid back if you paid. Everyone\'s share is split.',
            done: trip.spentPaise > 0 && !trip.isOpen,
            action: trip.isOpen ? 'Pay from the trip' : null,
            onAction: () => go(ExpenseAmountScreen(trip: trip)),
          ),
          _Step(
            n: 3,
            icon: Icons.receipt_long_outlined,
            title: 'See where it went',
            status: '${formatPaise(trip.spentPaise)} spent · ${formatPaise(trip.balancePaise)} left',
            body: 'Every payment, who it went to, and each person\'s part.',
            done: false,
            action: 'Open Spent',
            onAction: () => DefaultTabController.of(context).animateTo(2),
          ),
          _Step(
            n: 4,
            icon: Icons.handshake_outlined,
            title: 'Close and pay out',
            status: trip.isOpen ? (organiser ? 'When the trip is over' : 'The organiser closes the trip') : 'Closed',
            body: 'What is left goes back to everyone: straight to PayPal for those who added a PayPal email, otherwise to their Pointy balance.',
            done: !trip.isOpen,
            last: true,
            action: organiser || !trip.isOpen ? (trip.isOpen ? 'Close the trip' : 'See the settlement') : null,
            onAction: () => go(SettleScreen(trip: trip, me: me)),
          ),
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
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(formatPaise(m.leftPaise), style: AppText.body(weight: FontWeight.w700)),
                        Text('left', style: AppText.small()),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One numbered step of a trip, joined to the next by a line.
class _Step extends StatelessWidget {
  const _Step({
    required this.n,
    required this.icon,
    required this.title,
    required this.status,
    required this.body,
    required this.done,
    this.action,
    this.onAction,
    this.last = false,
  });

  final int n;
  final IconData icon;
  final String title;
  final String status;
  final String body;
  final bool done;
  final String? action;
  final VoidCallback? onAction;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 36,
            child: Column(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(color: done ? AppColors.pine100 : AppColors.pine700, shape: BoxShape.circle),
                  alignment: Alignment.center,
                  child: done
                      ? const Icon(Icons.check_rounded, size: 18, color: AppColors.pine700)
                      : Text('$n', style: AppText.body(color: Colors.white, weight: FontWeight.w700)),
                ),
                if (!last) Expanded(child: Container(width: 2, color: AppColors.line)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 12),
              child: SurfaceCard(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(icon, size: 20, color: AppColors.pine700),
                        const SizedBox(width: 8),
                        Expanded(child: Text(title, style: AppText.body(weight: FontWeight.w700))),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(status, style: AppText.detail(color: AppColors.pine700, weight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(body, style: AppText.detail()),
                    if (action != null) ...[
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 40,
                        child: n == 1 || n == 2
                            ? FilledButton(onPressed: onAction, style: FilledButton.styleFrom(minimumSize: const Size(0, 40)), child: Text(action!))
                            : OutlinedButton(onPressed: onAction, style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)), child: Text(action!)),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
