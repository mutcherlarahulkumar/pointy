import 'package:flutter/material.dart';

import '../../api.dart';
import '../../money.dart';
import '../../models.dart';
import '../../prefs.dart';
import '../../theme.dart';
import '../../widgets/ai_card.dart';
import '../../widgets/async_view.dart';
import '../../widgets/empty_state.dart';
import '../money/pay_flow.dart';
import '../money/requests.dart';
import '../money/top_up.dart';
import '../trips/budget_tab.dart';
import '../trips/trip_shell.dart';

/// Everything the AI proposes right now, each with its reasons. None of
/// them does anything until it is tapped.
class SuggestionsScreen extends StatefulWidget {
  const SuggestionsScreen({super.key});

  @override
  State<SuggestionsScreen> createState() => _SuggestionsScreenState();
}

class _Item {
  final String title;
  final String? body;
  final List<String> reasons;
  final String action;
  final Route<void> Function() route;
  _Item(this.title, this.body, this.reasons, this.action, this.route);
}

Route<void> _page(Widget w) => MaterialPageRoute(builder: (_) => w);

class _SuggestionsScreenState extends State<SuggestionsScreen> {
  late Future<List<_Item>> _items = _load();

  Future<List<_Item>> _load() async {
    final me = await api.me();
    final items = <_Item>[];

    final waiting = (await api.moneyRequests()).where((r) => r.isIncoming && r.isOpen).toList();
    if (waiting.isNotEmpty) {
      final total = waiting.fold<int>(0, (a, r) => a + r.amountPaise);
      items.add(_Item('${waiting.length} request${waiting.length == 1 ? '' : 's'} waiting for you', 'Friends asked for ${formatPaise(total)} in all.',
          ['From ${firstName(waiting.first.requester.name)}${waiting.length > 1 ? ' and others' : ''}'], 'Review them', () => _page(const RequestsScreen())));
    }

    if (me.personalBalancePaise < 50000) {
      items.add(_Item('Top up your balance', 'You have ${formatPaise(me.personalBalancePaise)}. Paying friends is instant once money is in.',
          const ['Low balance'], 'Add money', () => _page(const TopUpScreen())));
    }

    if (AiPrefs.time) {
      final s = await api.suggest();
      if (s.wallet != 'trip') {
        items.add(_Item(s.title, null, s.reasons, 'Pay someone', () => _page(const PayPersonScreen())));
      }
    }

    for (final trip in (await api.trips()).where((t) => t.isOpen)) {
      final budgets = await api.budgets(trip.id);
      for (final l in budgets.lines.where((l) => l.aheadOfPace)) {
        items.add(_Item('${categoryLabel(l.category)} is ahead of pace on ${trip.name}',
            '${formatPaise(l.usedPaise)} of ${formatPaise(l.limitPaise)} used on day ${budgets.day} of ${budgets.days}.',
            ['${l.percent}% used', 'Day ${budgets.day} of ${budgets.days}'], 'See the budget', () => tripRoute(trip.id, initialTab: 3)));
      }
      final move = suggestMove(budgets);
      if (move != null) {
        items.add(_Item('Move ${formatPaise(move.amountPaise)} from ${categoryLabel(move.from.category)} to ${categoryLabel(move.to.category)}',
            'Keeps ${categoryLabel(move.to.category)} on budget at the current pace.', [trip.name], 'Review the move', () => tripRoute(trip.id, initialTab: 3)));
      }
      final missing = trip.targetPaise - trip.depositedPaise;
      if (AiPrefs.assistant && missing > 0 && trip.organiserId == me.user.id && trip.members.length > 1) {
        items.add(_Item('${formatPaise(missing)} of deposits still to collect', 'The assistant can ask everyone for you.',
            ['${formatPaise(trip.depositedPaise)} of ${formatPaise(trip.targetPaise)} in'], 'Open Deposits', () => tripRoute(trip.id, initialTab: 1)));
      }
      final mine = trip.member(me.user.id);
      if (mine != null && mine.leftPaise < 100000 && trip.depositedPaise > 0) {
        items.add(_Item('Top up your ${trip.name} share', 'You have ${formatPaise(mine.leftPaise)} left in it.', const ['Low share'], 'Add money',
            () => _page(TopUpScreen(trip: trip))));
      }
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Suggestions')),
      body: AsyncView<List<_Item>>(
        future: _items,
        onRetry: () => setState(() { _items = _load(); }),
        builder: (context, items) {
          if (items.isEmpty) {
            return const EmptyState(icon: Icons.auto_awesome, title: 'Nothing to suggest right now', body: 'As you pay and travel, ideas show up here.');
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final it in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: AiCard(
                    title: it.title,
                    body: it.body,
                    reasons: it.reasons,
                    actionLabel: it.action,
                    onTap: () async {
                      await Navigator.of(context).push(it.route());
                      setState(() { _items = _load(); });
                    },
                  ),
                ),
              Text('Suggestions never move money on their own.', textAlign: TextAlign.center, style: AppText.detail()),
            ],
          );
        },
      ),
    );
  }
}
