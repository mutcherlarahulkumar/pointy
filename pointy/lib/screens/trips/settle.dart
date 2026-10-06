import 'package:flutter/material.dart';

import '../../api.dart';
import '../../models.dart';
import '../../money.dart';
import '../../theme.dart';
import '../../widgets/ai_card.dart';
import '../../widgets/async_view.dart';
import '../../widgets/section_title.dart';
import '../../widgets/success.dart';
import '../../widgets/tag.dart';

/// Settle up: a recap, the totals, and the refund each person gets back.
/// Only the organiser can send the refunds, and doing so closes the trip.
class SettleScreen extends StatefulWidget {
  const SettleScreen({super.key, required this.trip, required this.me});

  final Trip trip;
  final Me me;

  @override
  State<SettleScreen> createState() => _SettleScreenState();
}

class _SettleScreenState extends State<SettleScreen> {
  late Future<Settlement> _settlement = api.settlement(widget.trip.id);
  // One key per attempt; a new one after an error the server stored (4xx).
  String _key = newIdempotencyKey();
  bool _busy = false;

  Future<void> _send(Settlement s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send refunds and close the trip?'),
        content: Text('${formatPaise(s.refundPaise)} goes back to ${s.lines.where((l) => l.refundPaise > 0).length} '
            'people\'s Pointy balances. Nobody can pay from this wallet afterwards.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Send refunds')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final done = await api.settle(widget.trip.id, key: _key);
      if (!mounted) return;
      setState(() { _settlement = Future.value(done); });
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SuccessScreen(
          title: '${widget.trip.name} is closed',
          amount: formatPaise(done.refundPaise),
          subtitle: 'went back to ${done.lines.where((l) => l.refundPaise > 0).length} people\'s Pointy balances',
          rows: [for (final l in done.lines) if (l.refundPaise > 0) (l.user.name, formatPaise(l.refundPaise))],
        ),
      ));
    } catch (e) {
      if (e is ApiException && e.status >= 400 && e.status < 500) _key = newIdempotencyKey();
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final organiser = widget.trip.organiserId == widget.me.user.id;
    return Scaffold(
      appBar: AppBar(title: const Text('Settle up')),
      body: AsyncView<Settlement>(
        future: _settlement,
        onRetry: () => setState(() { _settlement = api.settlement(widget.trip.id); }),
        builder: (context, s) {
          final settled = s.status != 'open';
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(settled ? 'Trip settled' : 'Settle ${widget.trip.name}', style: AppText.title()),
              const SizedBox(height: 16),
              AiCard(title: 'Recap', body: recap(widget.trip, s)),
              const SectionTitle('Totals'),
              SurfaceCard(
                child: Column(
                  children: [
                    _row('Put in', s.depositedPaise),
                    _row('Spent', s.spentPaise),
                    _row('To refund', s.refundPaise, bold: true),
                  ],
                ),
              ),
              const SectionTitle('Back to each person'),
              SurfaceCard(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Column(
                  children: [
                    for (final l in s.lines)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(l.user.name, style: AppText.body(weight: FontWeight.w600)),
                        subtitle: Text('Put in ${formatPaise(l.depositedPaise)} · used ${formatPaise(l.usedPaise)}',
                            style: AppText.detail()),
                        trailing: Text(formatPaise(l.refundPaise), style: AppText.heading()),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              if (settled) ...[
                Row(children: [
                  const Tag('Refunds sent', kind: TagKind.trip),
                  const SizedBox(width: 8),
                  Text('Into everyone\'s Pointy balance', style: AppText.small()),
                ]),
              ] else if (organiser)
                FilledButton(
                  onPressed: _busy ? null : () => _send(s),
                  child: Text('Send refunds of ${formatPaise(s.refundPaise)}'),
                )
              else
                Text('The organiser sends the refunds when the trip ends.', style: AppText.detail()),
            ],
          );
        },
      ),
    );
  }

  Widget _row(String label, int paise, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(child: Text(label, style: AppText.detail())),
            Text(formatPaise(paise), style: AppText.body(weight: bold ? FontWeight.w700 : FontWeight.w500)),
          ],
        ),
      );
}

/// A short plain-language recap of the trip's money.
String recap(Trip t, Settlement s) {
  final people = s.lines.length;
  final each = people == 0 ? 0 : s.spentPaise ~/ people;
  final top = [...s.lines]..sort((a, b) => b.refundPaise.compareTo(a.refundPaise));
  var text = '$people people put in ${formatPaise(s.depositedPaise)} and spent ${formatPaise(s.spentPaise)}, '
      'about ${formatPaise(each)} each. ${formatPaise(s.refundPaise)} '
      '${s.status == 'open' ? 'is left to send back' : 'went back to balances'}.';
  // Name who gets the most back only when one person clearly does.
  if (top.length > 1 && top.first.refundPaise > top[1].refundPaise) {
    final who = top.first.user.name;
    text += ' ${who == 'You' ? 'You get' : '$who gets'} the most back (${formatPaise(top.first.refundPaise)}).';
  }
  return text;
}
