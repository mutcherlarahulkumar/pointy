import 'package:flutter/material.dart';

import '../../tabs.dart';
import '../../api.dart';
import '../../models.dart';
import '../../money.dart';
import '../../theme.dart';
import '../../widgets/ai_mark.dart';
import '../../widgets/ai_card.dart';
import '../../widgets/async_view.dart';
import '../../widgets/section_title.dart';
import 'ai_settings.dart';
import 'suggestions.dart';

/// Insights, with a Trip tab and a Personal tab.
class InsightsScreen extends StatelessWidget {
  const InsightsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text('Insights', style: AppText.title()),
          actions: [
            IconButton(
              tooltip: 'Suggestions',
              icon: const AiMark(size: 28),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SuggestionsScreen())),
            ),
            IconButton(
              tooltip: 'What the AI may use',
              icon: const Icon(Icons.tune),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AiSettingsScreen())),
            ),
          ],
          bottom: const TabBar(tabs: [Tab(text: 'Trip'), Tab(text: 'Personal')]),
        ),
        body: const TabBarView(children: [_TripInsights(), _PersonalInsights()]),
      ),
    );
  }
}

class _TripInsights extends StatefulWidget {
  const _TripInsights();

  @override
  State<_TripInsights> createState() => _TripInsightsState();
}

class _TripInsightsState extends State<_TripInsights> with ReloadWhenShown {
  @override
  void reloadQuietly() => setState(() { _data = _load(); });

  late Future<(Trip, Insights)?> _data = _load();

  // The active trip, or the most recent one if none is on right now.
  Future<(Trip, Insights)?> _load() async {
    final me = await api.me();
    var tripId = me.activeTripId;
    if (tripId.isEmpty) {
      final trips = await api.trips();
      if (trips.isEmpty) return null;
      tripId = trips.first.id; // newest first
    }
    return (await api.trip(tripId), await api.insights(tripId));
  }

  @override
  Widget build(BuildContext context) {
    return AsyncView<(Trip, Insights)?>(
      future: _data,
      onRetry: () => setState(() { _data = _load(); }),
      builder: (context, data) {
        if (data == null) return const ErrorView(message: 'No trips yet.');
        final (trip, i) = data;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('${trip.name} · day ${i.day} of ${i.days}', style: AppText.detail()),
            const SizedBox(height: 8),
            AiCard(
              title: 'Summary',
              body: i.summary,
              reasons: [i.summarySource == 'ai' ? 'Written by AI' : 'From your numbers'],
            ),
            if (i.tip.isNotEmpty) ...[
              const SizedBox(height: 10),
              AiCard(title: 'Tip', body: i.tip),
            ],
            const SizedBox(height: 16),
            Totals(spentPaise: i.spentPaise, eachPaise: i.perPersonPaise, leftPaise: i.leftPaise),
            BreakdownSection('By category', i.byCategory, labels: categoryLabel),
            BreakdownSection('By time of day', i.byTimeOfDay, labels: categoryLabel),
            BreakdownSection('By place', [
              for (final b in i.byPlace)
                if (b.key.isNotEmpty && b.key != 'Unknown place') b
            ]),
            BreakdownSection('By person', i.byPerson),
          ],
        );
      },
    );
  }
}

class _PersonalInsights extends StatefulWidget {
  const _PersonalInsights();

  @override
  State<_PersonalInsights> createState() => _PersonalInsightsState();
}

class _PersonalInsightsState extends State<_PersonalInsights> with ReloadWhenShown {
  @override
  void reloadQuietly() => setState(() { _history = api.history(); });

  late Future<List<HistoryItem>> _history = api.history();

  @override
  Widget build(BuildContext context) {
    return AsyncView<List<HistoryItem>>(
      future: _history,
      onRetry: () => setState(() { _history = api.history(); }),
      builder: (context, history) {
        // Your own money: personal payments plus your part of trip payments.
        final payments = history.where((h) => h.kind == 'payment').toList();
        final personal = payments.where((h) => !h.isTrip).toList();
        final spent = payments.fold<int>(0, (a, h) => a + h.yourPartPaise);
        final personalSpent = personal.fold<int>(0, (a, h) => a + h.yourPartPaise);
        final byCategory = breakdown(payments, (h) => h.category.isEmpty ? 'other' : h.category);
        final byTime = breakdown(payments, (h) => timeOfDay(h.at.hour));
        final byPlace = breakdown(payments.where((h) => h.placeName.isNotEmpty).toList(), (h) => h.placeName);
        final top = byCategory.isEmpty ? null : byCategory.first;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            AiCard(
              title: 'Summary',
              body: payments.isEmpty
                  ? 'No payments yet.'
                  : 'Your part of everything you paid is ${formatPaise(spent)}. '
                      '${formatPaise(personalSpent)} of it came from your personal balance. '
                      '${top == null ? '' : '${categoryLabel(top.key)} is your biggest cost (${top.percent}%).'}',
            ),
            const SizedBox(height: 16),
            Totals(
                spentPaise: spent,
                eachPaise: personalSpent,
                leftPaise: spent - personalSpent,
                labels: const ['Your part', 'Personal', 'From trips']),
            BreakdownSection('By category', byCategory, labels: categoryLabel),
            BreakdownSection('By time of day', byTime, labels: categoryLabel),
            BreakdownSection('By place', byPlace),
          ],
        );
      },
    );
  }
}

/// Groups history items by [keyOf] and sums your part, biggest first.
List<Breakdown> breakdown(List<HistoryItem> items, String Function(HistoryItem) keyOf) {
  final sums = <String, int>{};
  for (final h in items) {
    sums[keyOf(h)] = (sums[keyOf(h)] ?? 0) + h.yourPartPaise;
  }
  final total = sums.values.fold<int>(0, (a, b) => a + b);
  final out = [
    for (final e in sums.entries)
      Breakdown(key: e.key, amountPaise: e.value, percent: total == 0 ? 0 : (e.value * 100 + total ~/ 2) ~/ total),
  ]..sort((a, b) => b.amountPaise.compareTo(a.amountPaise));
  return out;
}

/// The same buckets the backend uses for trip insights.
String timeOfDay(int hour) => switch (hour) {
      >= 5 && < 12 => 'morning',
      >= 12 && < 18 => 'afternoon',
      >= 18 && < 22 => 'evening',
      _ => 'night',
    };

/// Spent / each / left in a row.
class Totals extends StatelessWidget {
  const Totals({
    super.key,
    required this.spentPaise,
    required this.eachPaise,
    required this.leftPaise,
    this.labels = const ['Spent', 'Each', 'Left'],
  });

  final int spentPaise;
  final int eachPaise;
  final int leftPaise;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final values = [spentPaise, eachPaise, leftPaise];
    return SurfaceCard(
      child: Row(
        children: [
          for (var i = 0; i < 3; i++)
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(labels[i], style: AppText.detail()),
                  Text(formatPaise(values[i]), style: AppText.heading()),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A titled list of bars, one per row of a breakdown.
class BreakdownSection extends StatelessWidget {
  const BreakdownSection(this.title, this.rows, {super.key, this.labels});

  final String title;
  final List<Breakdown> rows;
  final String Function(String)? labels;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(title),
        SurfaceCard(
          child: Column(
            children: [
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(labels?.call(r.key) ?? r.key, style: AppText.body())),
                          Text('${formatPaise(r.amountPaise)} · ${r.percent}%', style: AppText.detail()),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Bar(fraction: r.percent / 100),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
