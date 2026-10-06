import 'package:flutter/material.dart';

import '../../api.dart';
import '../../models.dart';
import '../../money.dart';
import '../../payment_lock.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/avatar.dart';
import '../../widgets/section_title.dart';
import '../../widgets/success.dart';
import '../../widgets/tag.dart';
import 'accept_invite.dart';
import 'add_child.dart';
import 'child_detail.dart';

/// Opens the Family screen. The route is named so the add-a-child flow can
/// come back to it.
Route<void> familyRoute() => MaterialPageRoute(settings: const RouteSettings(name: 'family'), builder: (_) => const FamilyScreen());

/// Pointy Parenting in one place: for a parent, their children and the
/// payments waiting for an OK; for a child, who looks after them and their
/// limits; for anyone, a parent asking to link.
class FamilyScreen extends StatefulWidget {
  const FamilyScreen({super.key});

  @override
  State<FamilyScreen> createState() => _FamilyScreenState();
}

class _FamilyScreenState extends State<FamilyScreen> {
  late Future<FamilyView> _family = api.family();

  // One key per approval and choice: a retry of the same tap cannot pay twice.
  final _keys = <String, SubmitKey>{};

  void _reload() => setState(() { _family = api.family(); });

  Future<void> _go(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    _reload();
  }

  Future<void> _decide(Approval a, bool approve) async {
    String pin = '';
    if (approve) {
      final p = await pinValue(context, 'Approve ${formatPaise(a.amountPaise)} to ${a.payee.name}');
      if (p == null) return;
      pin = p;
    }
    final key = _keys.putIfAbsent('${a.id}/$approve', SubmitKey.new);
    try {
      await api.decideApproval(a.id, approve: approve, pin: pin, key: key.forRequest(pin));
      if (!mounted) return;
      if (approve) {
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => SuccessScreen(
            title: 'Approved',
            amount: formatPaise(a.amountPaise),
            subtitle: '${a.child.name} paid ${a.payee.name}',
            rows: [if (a.note.isNotEmpty) ('For', a.note), ('From', '${a.child.name}\'s pocket money')],
          ),
        ));
      } else {
        showMessage(context, 'Declined; nothing was paid');
      }
    } catch (e) {
      key.failed(e);
      if (mounted) showError(context, e);
    }
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Family')),
      body: AsyncView<FamilyView>(
        future: _family,
        onRetry: _reload,
        builder: (context, f) {
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                for (final inv in f.invites) _InviteCard(inv: inv, onOpen: () => _go(AcceptInviteScreen(invite: inv))),
                if (f.role == 'child' && f.me != null) ..._child(f.me!, f),
                if (f.role != 'child') ..._parent(f),
              ],
            ),
          );
        },
      ),
    );
  }

  List<Widget> _child(ChildView me, FamilyView f) => [
        Text('Looked after by ${me.parent.name}', style: AppText.title()),
        const SizedBox(height: 6),
        Text('${me.parent.name} sees your payments and sets your limits. Anything over a limit needs their OK.', style: AppText.body(color: AppColors.slate)),
        const SizedBox(height: 16),
        LimitsCard(c: me),
        if (f.approvals.isNotEmpty) ...[
          const SectionTitle('Waiting for an OK'),
          for (final a in f.approvals)
            Card(
              child: ListTile(
                leading: const Icon(Icons.hourglass_top_rounded),
                title: Text('${formatPaise(a.amountPaise)} to ${a.payee.name}'),
                subtitle: Text(a.note.isEmpty ? 'Sent to ${me.parent.name}' : a.note),
              ),
            ),
        ],
        const SectionTitle('Your rules'),
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _rule(Icons.payments_outlined, 'At most ${formatPaise(f.maxPaymentPaise)} in one payment'),
              _rule(Icons.savings_outlined, 'Your Pointy holds at most ${formatPaise(f.maxBalancePaise)}'),
              _rule(Icons.block_rounded, 'No adding money with PayPal, withdrawing or trip wallets'),
              _rule(Icons.cake_outlined, 'On your 18th birthday your account becomes your own'),
            ],
          ),
        ),
      ];

  Widget _rule(IconData icon, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [Icon(icon, size: 20, color: AppColors.pine700), const SizedBox(width: 10), Expanded(child: Text(text, style: AppText.body()))]),
      );

  List<Widget> _parent(FamilyView f) => [
        if (f.children.isEmpty) ...[
          const SizedBox(height: 8),
          Icon(Icons.family_restroom_rounded, size: 56, color: AppColors.pine500),
          const SizedBox(height: 12),
          Text('Pointy Parenting', textAlign: TextAlign.center, style: AppText.title()),
          const SizedBox(height: 8),
          Text('Look after your child\'s Pointy: set daily and monthly limits, see every payment, and approve anything over a limit.',
              textAlign: TextAlign.center, style: AppText.body(color: AppColors.slate)),
          const SizedBox(height: 20),
        ],
        if (f.approvals.isNotEmpty) ...[
          const SectionTitle('Waiting for your OK'),
          for (final a in f.approvals) _ApprovalCard(a: a, onDecide: (ok) => _decide(a, ok)),
        ],
        if (f.children.isNotEmpty) const SectionTitle('Your children'),
        for (final c in f.children)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _ChildCard(c: c, onTap: c.isActive ? () => _go(ChildDetailScreen(childId: c.child.id)) : null),
          ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: () async {
            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddChildScreen()));
            _reload();
          },
          icon: const Icon(Icons.person_add_alt_1_rounded),
          label: const Text('Add a child'),
        ),
      ];
}

/// Today's and this month's spending against the limits.
class LimitsCard extends StatelessWidget {
  const LimitsCard({super.key, required this.c});
  final ChildView c;

  @override
  Widget build(BuildContext context) {
    Widget line(String label, int spent, int limit, int left) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text(label, style: AppText.detail())),
              Text('${formatPaise(left)} left', style: AppText.body(weight: FontWeight.w700, color: left == 0 ? AppColors.error : AppColors.ink)),
            ]),
            const SizedBox(height: 6),
            TweenAnimationBuilder<double>(
              tween: Tween(end: limit == 0 ? 0 : spent / limit),
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => Bar(fraction: v, color: v >= 1 ? AppColors.error : (v >= 0.8 ? AppColors.amber500 : null)),
            ),
            const SizedBox(height: 4),
            Text('${formatPaise(spent)} of ${formatPaise(limit)}', style: AppText.small()),
          ],
        );
    return SurfaceCard(
      child: Column(
        children: [
          line('Today', c.spentTodayPaise, c.dailyLimitPaise, c.dailyLeftPaise),
          const SizedBox(height: 14),
          line('This month', c.spentMonthPaise, c.monthlyLimitPaise, c.monthlyLeftPaise),
        ],
      ),
    );
  }
}

class _ChildCard extends StatelessWidget {
  const _ChildCard({required this.c, required this.onTap});
  final ChildView c;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Avatar(c.child.name, size: 48),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(child: Text(c.child.name, overflow: TextOverflow.ellipsis, style: AppText.body(weight: FontWeight.w700))),
                      if (c.pending > 0) ...[const SizedBox(width: 8), Tag('${c.pending} to approve', kind: TagKind.pending)],
                    ]),
                    const SizedBox(height: 2),
                    Text(
                      c.isActive
                          ? '${formatPaise(c.balancePaise)} · ${formatPaise(c.dailyLeftPaise)} left today'
                          : 'Waiting for ${c.child.name} to type the code',
                      style: AppText.detail(),
                    ),
                  ],
                ),
              ),
              if (c.isActive) const Icon(Icons.chevron_right_rounded, color: AppColors.slate),
            ],
          ),
        ),
      ),
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({required this.a, required this.onDecide});
  final Approval a;
  final ValueChanged<bool> onDecide;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: AppColors.pendingBg, borderRadius: BorderRadius.circular(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${a.child.name} wants to pay ${formatPaise(a.amountPaise)}', style: AppText.body(weight: FontWeight.w700, color: AppColors.pending)),
            const SizedBox(height: 2),
            Text('To ${a.payee.name}${a.note.isEmpty ? '' : ' · ${a.note}'} · over their ${a.reason} limit', style: AppText.detail(color: AppColors.pending)),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: () => onDecide(false), child: const Text('No'))),
              const SizedBox(width: 10),
              Expanded(child: FilledButton(onPressed: () => onDecide(true), child: const Text('Approve'))),
            ]),
          ],
        ),
      ),
    );
  }
}

class _InviteCard extends StatelessWidget {
  const _InviteCard({required this.inv, required this.onOpen});
  final ChildView inv;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: AppColors.pine100, borderRadius: BorderRadius.circular(18)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${inv.parent.name} wants to look after your Pointy', style: AppText.heading()),
            const SizedBox(height: 4),
            Text('You need the code on their phone, and your PIN.', style: AppText.detail()),
            const SizedBox(height: 12),
            FilledButton(onPressed: onOpen, child: const Text('See what changes')),
          ],
        ),
      ),
    );
  }
}
