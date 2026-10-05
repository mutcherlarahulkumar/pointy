import 'package:flutter/material.dart';

import '../../api.dart';
import '../../dates.dart';
import '../../models.dart';
import '../../money.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tag.dart';
import 'top_up.dart';
import 'withdraw.dart';

/// "Where is my money?" Every rupee you add is a real PayPal payment into
/// Pointy's PayPal business account. Pointy's books say how much of it is
/// yours. When money leaves (a withdrawal, a shop paid from a trip, a
/// settle-up refund), PayPal Payouts sends it to a real PayPal account.
class WhereMoneyScreen extends StatefulWidget {
  const WhereMoneyScreen({super.key});

  @override
  State<WhereMoneyScreen> createState() => _WhereMoneyScreenState();
}

class _WhereMoneyScreenState extends State<WhereMoneyScreen> {
  late Future<MoneyView> _money = api.money();

  Future<void> _go(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) setState(() => _money = api.money());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Where is my money?')),
      body: AsyncView<MoneyView>(
        future: _money,
        onRetry: () => setState(() => _money = api.money()),
        builder: (context, m) => RefreshIndicator(
          onRefresh: () async => setState(() => _money = api.money()),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _Node(
                icon: Icons.account_circle_outlined,
                color: AppColors.personal,
                title: 'Your PayPal',
                body: m.paypalEmail.isEmpty ? 'You pay in with PayPal checkout' : m.paypalEmail,
              ),
              _Arrow(label: 'PayPal checkout · you added ${formatPaise(m.youPaidInPaise)}'),
              _Node(
                icon: Icons.account_balance_rounded,
                color: AppColors.pine700,
                title: 'Pointy\'s PayPal business account',
                body: 'Holds ${formatPaise(m.businessAccountPaise)} for everyone on Pointy${m.paypalMode == 'mock' ? ' (demo mode: PayPal is simulated)' : ''}',
                trailing: m.balanced ? const Tag('Books match', kind: TagKind.trip) : const Tag('Check books', kind: TagKind.pending),
                child: Column(
                  children: [
                    const Divider(height: 20),
                    _line('Your balance', m.yourBalancePaise),
                    _line('Your trip shares', m.yourTripSharesPaise),
                    const SizedBox(height: 4),
                    Text('Paying a friend moves money between balances here, instantly. It only leaves through PayPal.',
                        style: AppText.small()),
                  ],
                ),
              ),
              _Arrow(label: 'PayPal Payouts · ${formatPaise(m.youPaidOutPaise)} sent to you'),
              _Node(
                icon: Icons.output_rounded,
                color: AppColors.personal,
                title: 'Out to real PayPal accounts',
                body: 'Withdrawals to you, shops paid from a trip, and refunds when a trip settles.',
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add money'),
                      onPressed: () => _go(const TopUpScreen()),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.output_rounded),
                      label: const Text('Withdraw'),
                      onPressed: () => _go(const WithdrawScreen()),
                    ),
                  ),
                ],
              ),
              const SectionTitle('Payouts'),
              if (m.payouts.isEmpty) Text('Nothing has been paid out yet.', style: AppText.detail()),
              for (final p in m.payouts) _PayoutRow(p),
            ],
          ),
        ),
      ),
    );
  }

  Widget _line(String label, int paise) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(child: Text(label, style: AppText.detail())),
            Text(formatPaise(paise), style: AppText.body(weight: FontWeight.w700)),
          ],
        ),
      );
}

class _Node extends StatelessWidget {
  const _Node({required this.icon, required this.color, required this.title, required this.body, this.trailing, this.child});

  final IconData icon;
  final Color color;
  final String title;
  final String body;
  final Widget? trailing;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppText.body(weight: FontWeight.w700)),
                    Text(body, style: AppText.detail()),
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          if (child != null) child!,
        ],
      ),
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 28),
      child: Row(
        children: [
          Container(width: 2, height: 40, color: AppColors.lineStrong),
          const SizedBox(width: 6),
          const Icon(Icons.south_rounded, size: 16, color: AppColors.slate),
          const SizedBox(width: 6),
          Expanded(child: Text(label, style: AppText.small(color: AppColors.slate))),
        ],
      ),
    );
  }
}

class _PayoutRow extends StatelessWidget {
  const _PayoutRow(this.p);

  final Payout p;

  @override
  Widget build(BuildContext context) {
    final kind = switch (p.status) {
      'paid' => TagKind.trip,
      'failed' || 'returned' => TagKind.plain,
      _ => TagKind.pending,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: ListTile(
          leading: Icon(p.kind == 'merchant' ? Icons.storefront_outlined : Icons.output_rounded, color: AppColors.pine700),
          title: Text(p.description, style: AppText.body(weight: FontWeight.w600)),
          subtitle: Text('${p.email} · ${formatDay(p.createdAt)}${p.batchId.isEmpty ? '' : '\nPayPal ${p.batchId}'}', style: AppText.detail()),
          isThreeLine: p.batchId.isNotEmpty,
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(formatPaise(p.amountPaise), style: AppText.body(weight: FontWeight.w700)),
              Tag(p.statusLabel, kind: kind),
            ],
          ),
        ),
      ),
    );
  }
}
