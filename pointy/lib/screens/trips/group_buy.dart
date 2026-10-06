import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api.dart';
import '../../dates.dart';
import '../../models.dart';
import '../../money.dart';
import '../../payment_lock.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/avatar.dart';
import '../../widgets/product_image.dart';
import '../../widgets/section_title.dart';
import '../../widgets/success.dart';
import '../../widgets/tag.dart';

/// One group purchase: what it is, who is in, and your yes or no. It is
/// paid only when everyone is in; one no calls it off and nobody pays.
class GroupBuyScreen extends StatefulWidget {
  const GroupBuyScreen({super.key, required this.trip, required this.id, this.initial});

  final Trip trip;
  final String id;
  final GroupBuy? initial;

  @override
  State<GroupBuyScreen> createState() => _GroupBuyScreenState();
}

class _GroupBuyScreenState extends State<GroupBuyScreen> with WidgetsBindingObserver {
  late Future<GroupBuy> _buy = widget.initial != null ? Future.value(widget.initial!) : api.groupBuy(widget.id);
  Timer? _poll;
  bool _busy = false;
  bool _celebrated = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Others say yes on their phones: check every few seconds while open.
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _refresh(quiet: true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  // Back from the PayPal page: look again at once.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh(quiet: true);
  }

  Future<void> _refresh({bool quiet = false}) async {
    try {
      final g = await api.groupBuy(widget.id);
      if (!mounted) return;
      if (!g.isOpen) _poll?.cancel();
      if (g.status == 'paid') return _celebrate(g);
      setState(() { _buy = Future.value(g); });
    } catch (e) {
      if (!quiet && mounted) showError(context, e);
    }
  }

  void _show(GroupBuy g) {
    if (g.status == 'paid') return _celebrate(g);
    setState(() { _buy = Future.value(g); });
  }

  void _celebrate(GroupBuy g) {
    if (_celebrated || !mounted) return;
    _celebrated = true;
    _poll?.cancel();
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => SuccessScreen(
        title: 'Bought together',
        amount: formatPaise(g.amountPaise),
        subtitle: g.item.title,
        category: g.category,
        rows: [
          ('Shop', g.item.merchant),
          ('Split', '${g.shares.length} ways, ${formatPaise(g.shares.first.amountPaise)} each'),
          ('Paid from', '${widget.trip.name} wallet'),
        ],
      ),
    ));
  }

  Future<void> _act(Future<GroupBuy> Function() call) async {
    setState(() => _busy = true);
    try {
      _show(await call());
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fromWallet(GroupBuyShare mine) async {
    if (!await confirmPayment(context, 'Put ${formatPaise(mine.amountPaise)} towards this from your trip share')) return;
    await _act(() => api.joinGroupBuy(widget.id, 'wallet', key: newIdempotencyKey()));
  }

  Future<void> _withPayPal() async {
    await _act(() async {
      final g = await api.joinGroupBuy(widget.id, 'paypal', key: newIdempotencyKey());
      final mine = g.shareOf(api.userId);
      if (mine == null || mine.approveUrl.isEmpty) return g;
      final url = Uri.parse(mine.approveUrl);
      if (url.host.endsWith('.invalid')) {
        // Demo mode: PayPal is simulated and approves at once.
        return api.authorizeGroupBuy(mine.orderId);
      }
      await launchUrl(url, mode: LaunchMode.externalApplication);
      return g;
    });
  }

  Future<void> _decline(bool proposer) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(proposer ? 'Call it off?' : 'Say no?'),
        content: const Text('The purchase is called off for everyone. Nobody is charged, and any money held is let go.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep it')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(proposer ? 'Call it off' : 'Say no')),
        ],
      ),
    );
    if (ok == true) await _act(() => api.declineGroupBuy(widget.id));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Buy together')),
      body: AsyncView<GroupBuy>(
        future: _buy,
        onRetry: () => _refresh(),
        builder: (context, g) {
          final me = api.userId;
          final mine = g.shareOf(me);
          return RefreshIndicator(
            onRefresh: () => _refresh(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                _Item(g: g),
                const SizedBox(height: 16),
                _Status(g: g, trip: widget.trip),
                const SectionTitle('Everyone'),
                SurfaceCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(
                    children: [
                      for (final s in g.shares)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Avatar(widget.trip.nameOf(s.userId)),
                          title: Text(s.userId == me ? 'You' : widget.trip.nameOf(s.userId), style: AppText.body(weight: FontWeight.w600)),
                          subtitle: Text(formatPaise(s.amountPaise), style: AppText.detail()),
                          trailing: _ShareTag(s),
                        ),
                    ],
                  ),
                ),
                if (g.status == 'open' && mine != null && !mine.isIn) ...[
                  const SizedBox(height: 20),
                  if (mine.approveUrl.isNotEmpty) ...[
                    Text('Approve your part on PayPal. It is only held, not charged, until everyone is in.', style: AppText.detail()),
                    const SizedBox(height: 10),
                    FilledButton(
                      onPressed: _busy ? null : () => _act(() => api.authorizeGroupBuy(mine.orderId)),
                      child: const Text("I've approved it"),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () => launchUrl(Uri.parse(mine.approveUrl), mode: LaunchMode.externalApplication),
                      child: const Text('Open PayPal again'),
                    ),
                  ] else ...[
                    FilledButton(
                      onPressed: _busy ? null : () => _fromWallet(mine),
                      child: Text('Yes, ${formatPaise(mine.amountPaise)} from my trip share'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _withPayPal,
                      icon: const Icon(Icons.lock_clock_outlined, size: 18),
                      label: const Text('Yes, hold it on my PayPal'),
                    ),
                  ],
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed: _busy ? null : () => _decline(g.proposedBy == me),
                    style: TextButton.styleFrom(foregroundColor: AppColors.error),
                    child: Text(g.proposedBy == me ? 'Call it off' : 'No thanks'),
                  ),
                ] else if (g.status == 'open' && g.proposedBy == me) ...[
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _busy ? null : () => _decline(true),
                    style: TextButton.styleFrom(foregroundColor: AppColors.error),
                    child: const Text('Call it off'),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({required this.g});

  final GroupBuy g;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ProductImage(g.item.imageUrl, size: 72),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(g.item.title, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.heading()),
                  const SizedBox(height: 4),
                  Text('${formatPaise(g.amountPaise)} · ${g.item.merchant}', style: AppText.detail()),
                ],
              ),
            ),
          ],
        ),
        if (g.why.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.amber100, borderRadius: BorderRadius.circular(12)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.auto_awesome, size: 16, color: AppColors.amber900),
                const SizedBox(width: 8),
                Expanded(child: Text(g.why, style: AppText.detail(color: AppColors.amber900))),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Where it stands, in one line and a bar.
class _Status extends StatelessWidget {
  const _Status({required this.g, required this.trip});

  final GroupBuy g;
  final Trip trip;

  @override
  Widget build(BuildContext context) {
    final (String title, String line, Color color) = switch (g.status) {
      'open' || 'paying' => (
          '${g.inCount} of ${g.shares.length} are in',
          'Paid only when everyone says yes. Open until ${formatWeekday(g.deadline)}, ${formatTime(g.deadline)}.',
          AppColors.pine700
        ),
      'paid' => ('Bought', 'Everyone said yes. It was paid from the trip wallet.', AppColors.pine700),
      'expired' => ('Ran out of time', 'Not everyone said yes in time. Nobody was charged.', AppColors.slate),
      'failed' => ('Not bought', '${g.note}. Nobody lost any money.', AppColors.error),
      _ => ('Called off', '${g.note.isEmpty ? 'Someone said no' : g.note}. Nobody was charged.', AppColors.slate),
    };
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppText.heading(color: color)),
          const SizedBox(height: 8),
          TweenAnimationBuilder<double>(
            tween: Tween(end: g.shares.isEmpty ? 0 : g.inCount / g.shares.length),
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOutCubic,
            builder: (context, v, _) => Bar(fraction: v),
          ),
          const SizedBox(height: 8),
          Text(line, style: AppText.detail()),
        ],
      ),
    );
  }
}

class _ShareTag extends StatelessWidget {
  const _ShareTag(this.s);

  final GroupBuyShare s;

  @override
  Widget build(BuildContext context) {
    if (s.status == 'declined') return const Tag('Said no', kind: TagKind.error);
    if (!s.isIn) return Tag(s.approveUrl.isNotEmpty ? 'On PayPal' : 'Waiting', kind: TagKind.pending);
    return Tag(s.via == 'paypal' ? 'In · PayPal' : 'In · wallet', kind: TagKind.trip);
  }
}
