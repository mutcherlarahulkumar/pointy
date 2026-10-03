import 'package:flutter/material.dart';

import '../../api.dart';
import '../../models.dart';
import '../../money.dart';
import '../../prefs.dart';
import '../../theme.dart';
import '../../widgets/ai_card.dart';
import '../../widgets/async_view.dart';
import '../home/home.dart';
import '../pay/pay_draft.dart';
import '../pay/payee.dart';
import '../trips/add_money.dart';
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
  final Widget Function() screen;
  _Item(this.title, this.body, this.reasons, this.action, this.screen);
}

class _SuggestionsScreenState extends State<SuggestionsScreen> {
  late Future<List<_Item>> _items = _load();

  Future<List<_Item>> _load() async {
    final me = await api.me();
    final items = <_Item>[];

    if (AiPrefs.location || AiPrefs.time) {
      final s = await api.suggest(
        placeType: AiPrefs.location ? demoPlaceType : '',
        placeName: AiPrefs.location ? demoPlaceName : '',
      );
      items.add(_Item(s.title, null, s.reasons, 'Start this payment', () {
        final d = PayDraft()
          ..placeType = demoPlaceType
          ..placeName = demoPlaceName
          ..applySuggestion(s);
        return PayeeScreen(draft: d);
      }));
    }

    if (me.activeTripId.isNotEmpty) {
      final trip = await api.trip(me.activeTripId);
      final budgets = await api.budgets(trip.id);
      for (final l in budgets.lines.where((l) => l.aheadOfPace)) {
        items.add(_Item(
          '${categoryLabel(l.category)} is ahead of pace',
          '${formatPaise(l.usedPaise)} of ${formatPaise(l.limitPaise)} used on day ${budgets.day} of ${budgets.days}.',
          ['${l.percent}% used', 'Day ${budgets.day} of ${budgets.days}'],
          'See the budget',
          () => TripShell(tripId: trip.id, initialTab: 3),
        ));
      }
      final move = suggestMove(budgets);
      if (move != null) {
        items.add(_Item(
          'Move ${formatPaise(move.amountPaise)} from ${categoryLabel(move.from.category)} to ${categoryLabel(move.to.category)}',
          'Keeps ${categoryLabel(move.to.category)} on budget at the current pace.',
          const ['Spending pace'],
          'Review the move',
          () => TripShell(tripId: trip.id, initialTab: 3),
        ));
      }
      final missing = trip.targetPaise - trip.depositedPaise;
      if (AiPrefs.assistant && missing > 0 && trip.organiserId == me.user.id) {
        items.add(_Item(
          '${formatPaise(missing)} of deposits still to collect',
          'The assistant can draft the requests for you to approve.',
          ['${formatPaise(trip.depositedPaise)} of ${formatPaise(trip.targetPaise)} in'],
          'Open Deposits',
          () => TripShell(tripId: trip.id, initialTab: 1),
        ));
      }
      final mine = trip.member(me.user.id);
      if (mine != null && mine.leftPaise < 100000) {
        items.add(_Item(
          'Top up your ${trip.name} share',
          'You have ${formatPaise(mine.leftPaise)} left in it.',
          const ['Low share'],
          'Add money',
          () => AddMoneyScreen(trip: trip),
        ));
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
        onRetry: () => setState(() => _items = _load()),
        builder: (context, items) {
          if (items.isEmpty) return const ErrorView(message: 'Nothing to suggest right now.');
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
                      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => it.screen()));
                      setState(() => _items = _load());
                    },
                  ),
                ),
              Text('Suggestions never move money on their own.', style: AppText.detail()),
            ],
          );
        },
      ),
    );
  }
}
