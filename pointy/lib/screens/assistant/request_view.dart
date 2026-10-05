import 'package:flutter/material.dart';

import '../../api.dart';
import '../../dates.dart';
import '../../money.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/avatar.dart';
import '../../widgets/section_title.dart';
import '../../widgets/success.dart';
import '../../widgets/tag.dart';
import '../money/top_up.dart';

/// A member's view of the deposit the organiser asked them for: how much,
/// by when, and two ways to pay it.
class RequestViewScreen extends StatefulWidget {
  const RequestViewScreen({super.key, required this.trip, required this.request});

  final Trip trip;
  final DepositRequest request;

  @override
  State<RequestViewScreen> createState() => _RequestViewScreenState();
}

class _RequestViewScreenState extends State<RequestViewScreen> {
  late Future<(Me, DepositRequest)> _data = _load();

  // The latest balance and request status, so the screen updates after
  // paying with PayPal.
  Future<(Me, DepositRequest)> _load() async {
    final me = await api.me();
    final all = await api.requests(widget.trip.id);
    return (me, all.firstWhere((r) => r.id == widget.request.id, orElse: () => widget.request));
  }
  final _key = newIdempotencyKey();
  bool _busy = false;

  Future<void> _payFromBalance() async {
    setState(() => _busy = true);
    try {
      final r = await api.payDepositRequest(widget.request.id, key: _key);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => SuccessScreen(
          title: 'Deposit paid',
          amount: formatPaise(r.amountPaise),
          subtitle: 'to your share of ${widget.trip.name}',
          rows: const [('Paid from', 'Your Pointy balance')],
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final organiser = widget.trip.nameOf(widget.trip.organiserId);
    return Scaffold(
      appBar: AppBar(title: const Text('Deposit request')),
      body: AsyncView<(Me, DepositRequest)>(
        future: _data,
        builder: (context, data) {
          final (me, r) = data;
          final enough = me.personalBalancePaise >= r.amountPaise;
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              SurfaceCard(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Avatar(organiser, size: 56),
                    const SizedBox(height: 10),
                    Text('$organiser asked you for', style: AppText.body(color: AppColors.slate)),
                    Text(formatPaise(r.amountPaise), style: AppText.balance()),
                    Text('for ${widget.trip.name} · due ${formatWeekday(r.due)}', style: AppText.detail()),
                    const SizedBox(height: 10),
                    r.isOpen ? const Tag('Waiting for you', kind: TagKind.pending) : Tag(r.status == 'paid' ? 'Paid' : 'Cancelled', kind: TagKind.trip),
                  ],
                ),
              ),
              if (r.isOpen) ...[
                const SectionTitle('Pay it'),
                FilledButton(
                  onPressed: _busy || !enough ? null : _payFromBalance,
                  child: Text(enough ? 'Pay from balance (${formatPaise(me.personalBalancePaise)})' : 'Balance too low (${formatPaise(me.personalBalancePaise)})'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: const Text('Pay with PayPal'),
                  onPressed: _busy
                      ? null
                      : () async {
                          await Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => TopUpScreen(trip: widget.trip, suggestPaise: r.amountPaise),
                          ));
                          if (mounted) setState(() => _data = _load());
                        },
                ),
                const SizedBox(height: 12),
                Text('Either way the request is marked paid as soon as the money reaches the trip wallet.',
                    textAlign: TextAlign.center, style: AppText.small()),
              ],
            ],
          );
        },
      ),
    );
  }
}
