import 'package:flutter/material.dart';

import '../../api.dart';
import '../../payment_lock.dart';
import '../../dates.dart';
import '../../money.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/avatar.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/tag.dart';
import 'request_flow.dart';
import 'top_up.dart';

/// Money people asked you for (to pay or decline), and what you asked for.
class RequestsScreen extends StatefulWidget {
  const RequestsScreen({super.key});

  @override
  State<RequestsScreen> createState() => _RequestsScreenState();
}

class _RequestsScreenState extends State<RequestsScreen> {
  late Future<List<MoneyRequest>> _list = api.moneyRequests();
  final Set<String> _busy = {};

  void _reload() => setState(() => _list = api.moneyRequests());

  Future<void> _act(MoneyRequest r, Future<void> Function() action, String done) async {
    setState(() => _busy.add(r.id));
    try {
      await action();
      if (mounted) showMessage(context, done);
      _reload();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'insufficient_balance') {
        final go = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Not enough balance'),
            content: Text('${e.toString()}. Add money with PayPal now?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Add money')),
            ],
          ),
        );
        if (go == true && mounted) {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TopUpScreen(suggestPaise: r.amountPaise)));
        }
      } else {
        showError(context, e);
      }
    } finally {
      if (mounted) setState(() => _busy.remove(r.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Requests'),
          bottom: const TabBar(tabs: [Tab(text: 'To pay'), Tab(text: 'Sent')]),
        ),
        floatingActionButton: FloatingActionButton.extended(
          backgroundColor: AppColors.pine700,
          foregroundColor: Colors.white,
          icon: const Icon(Icons.call_received_rounded),
          label: const Text('Request'),
          onPressed: () async {
            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RequestPersonScreen()));
            _reload();
          },
        ),
        body: AsyncView<List<MoneyRequest>>(
          future: _list,
          onRetry: _reload,
          builder: (context, list) => TabBarView(
            children: [
              _tab(list.where((r) => r.isIncoming).toList(),
                  const EmptyState(icon: Icons.inbox_outlined, title: 'Nothing to pay', body: 'When friends ask you for money, it shows up here.')),
              _tab(list.where((r) => !r.isIncoming).toList(),
                  const EmptyState(icon: Icons.outbox_outlined, title: 'No requests yet', body: 'Ask a friend for money, or split a bill.')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tab(List<MoneyRequest> items, Widget empty) {
    if (items.isEmpty) return ListView(children: [empty]);
    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, i) => _card(items[i]),
      ),
    );
  }

  Widget _card(MoneyRequest r) {
    final busy = _busy.contains(r.id);
    final (label, kind) = switch (r.status) {
      'paid' => ('Paid', TagKind.trip),
      'declined' => ('Declined', TagKind.error),
      'cancelled' => ('Cancelled', TagKind.plain),
      _ => ('Waiting', TagKind.pending),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Avatar(r.other.name),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.isIncoming ? '${r.other.name} asked you' : 'You asked ${r.other.name}',
                          style: AppText.body(weight: FontWeight.w600)),
                      Text('${r.note.isEmpty ? 'No note' : r.note} · ${formatDay(r.createdAt)}', style: AppText.detail()),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(formatPaise(r.amountPaise), style: AppText.heading()),
                    const SizedBox(height: 4),
                    Tag(label, kind: kind),
                  ],
                ),
              ],
            ),
            if (r.isOpen) ...[
              const SizedBox(height: 12),
              if (r.isIncoming)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                        onPressed: busy ? null : () => _act(r, () => api.declineMoneyRequest(r.id), 'Declined'),
                        child: const Text('Decline'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                        onPressed: busy
                            ? null
                            : () async {
                                if (!await confirmPayment(context, 'Pay ${formatPaise(r.amountPaise)} to ${r.other.name}')) return;
                                await _act(r, () => api.payMoneyRequest(r.id, key: newIdempotencyKey()),
                                    'Paid ${formatPaise(r.amountPaise)} to ${firstName(r.other.name)}');
                              },
                        child: Text('Pay ${formatPaise(r.amountPaise)}'),
                      ),
                    ),
                  ],
                )
              else
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: busy ? null : () => _act(r, () => api.declineMoneyRequest(r.id), 'Request cancelled'),
                    child: const Text('Cancel request'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
