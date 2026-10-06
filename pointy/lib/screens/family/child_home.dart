import 'package:flutter/material.dart';

import '../../api.dart';
import '../../dates.dart';
import '../../models.dart';
import '../../money.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/avatar.dart';
import '../../widgets/section_title.dart';
import '../history/history.dart';
import '../home/alerts.dart';
import '../money/pay_flow.dart';
import '../money/request_flow.dart';
import '../pay/scan.dart';
import '../profile/profile.dart';
import 'family.dart';

/// The child version of Pointy: one calm screen with pocket money, what is
/// left today and this month, four big buttons and the latest payments.
/// No trips, no AI suggestions, no adding money or withdrawing.
class ChildHome extends StatefulWidget {
  const ChildHome({super.key});

  @override
  State<ChildHome> createState() => _ChildHomeState();
}

class _ChildHomeState extends State<ChildHome> {
  late Future<(Me, FamilyView, List<HistoryItem>)> _data = _load();

  Future<(Me, FamilyView, List<HistoryItem>)> _load() async {
    final r = await Future.wait([api.me(), api.family(), api.history()]);
    return (r[0] as Me, r[1] as FamilyView, r[2] as List<HistoryItem>);
  }

  Future<void> _go(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) setState(() { _data = _load(); });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF8EF),
      body: SafeArea(
        child: AsyncView<(Me, FamilyView, List<HistoryItem>)>(
          future: _data,
          onRetry: () => setState(() { _data = _load(); }),
          builder: (context, data) {
            final (me, f, history) = data;
            final c = f.me;
            if (c == null) return const SizedBox.shrink(); // just unlinked: the adult app takes over
            return RefreshIndicator(
              onRefresh: () async => setState(() { _data = _load(); }),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  Row(children: [
                    InkWell(onTap: () => _go(const ProfileScreen()), customBorder: const CircleBorder(), child: Avatar(me.user.name, size: 44)),
                    const SizedBox(width: 12),
                    Expanded(child: Text('Hi ${firstName(me.user.name)}', style: AppText.title())),
                    IconButton(
                      tooltip: 'Alerts',
                      onPressed: () => _go(const AlertsScreen()),
                      icon: Badge(isLabelVisible: me.unreadAlerts > 0, label: Text('${me.unreadAlerts}'), child: const Icon(Icons.notifications_outlined)),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  _PocketCard(balance: me.personalBalancePaise, parent: c.parent.name),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(child: _Ring(label: 'Left today', left: c.dailyLeftPaise, limit: c.dailyLimitPaise, color: const Color(0xFFFF8A4C))),
                    const SizedBox(width: 12),
                    Expanded(child: _Ring(label: 'Left this month', left: c.monthlyLeftPaise, limit: c.monthlyLimitPaise, color: const Color(0xFF7C5CDB))),
                  ]),
                  const SizedBox(height: 16),
                  GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1.9,
                    children: [
                      _Big(icon: Icons.north_east_rounded, label: 'Pay', color: const Color(0xFFFF8A4C), onTap: () => _go(const PayPersonScreen())),
                      _Big(icon: Icons.qr_code_scanner_rounded, label: 'Scan', color: const Color(0xFF2B9ED8), onTap: () => _go(const ScanScreen())),
                      _Big(
                          icon: Icons.volunteer_activism_rounded,
                          label: 'Ask ${firstName(c.parent.name)}',
                          color: const Color(0xFF7C5CDB),
                          onTap: () => _go(RequestAmountScreen(person: c.parent, note: 'Pocket money'))),
                      _Big(icon: Icons.family_restroom_rounded, label: 'My rules', color: const Color(0xFF2E9E6B), onTap: () => _go(const FamilyScreen())),
                    ],
                  ),
                  if (f.approvals.isNotEmpty) ...[
                    SectionTitle('Waiting for ${firstName(c.parent.name)}'),
                    for (final a in f.approvals)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.hourglass_top_rounded, color: Color(0xFF7C5CDB)),
                          title: Text('${formatPaise(a.amountPaise)} to ${a.payee.name}'),
                          subtitle: Text('Paid as soon as ${firstName(c.parent.name)} says yes'),
                        ),
                      ),
                  ],
                  SectionTitle('Latest', action: history.isEmpty ? null : 'See all', onAction: () => _go(const HistoryScreen(standalone: true))),
                  if (history.isEmpty)
                    Text('Your payments show up here.', style: AppText.detail())
                  else
                    SurfaceCard(
                      padding: EdgeInsets.zero,
                      child: Column(children: [
                        for (var i = 0; i < history.length && i < 5; i++) ...[
                          if (i > 0) const Divider(indent: 16),
                          ListTile(
                            title: Text(history[i].title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body(weight: FontWeight.w600)),
                            subtitle: Text(formatDateTime(history[i].at), style: AppText.detail()),
                            trailing: Text(formatPaise(history[i].yourPartPaise), style: AppText.body(weight: FontWeight.w700)),
                          ),
                        ],
                      ]),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PocketCard extends StatelessWidget {
  const _PocketCard({required this.balance, required this.parent});
  final int balance;
  final String parent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: const LinearGradient(colors: [Color(0xFFFF8A4C), Color(0xFFF2B33D)], begin: Alignment.topLeft, end: Alignment.bottomRight),
        boxShadow: [BoxShadow(color: const Color(0xFFFF8A4C).withValues(alpha: 0.3), blurRadius: 20, offset: const Offset(0, 8))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.savings_rounded, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Text('Pocket money', style: AppText.detail(color: Colors.white, weight: FontWeight.w700)),
          ]),
          const SizedBox(height: 8),
          TweenAnimationBuilder<int>(
            tween: IntTween(end: balance),
            duration: const Duration(milliseconds: 700),
            curve: Curves.easeOutCubic,
            builder: (context, v, _) => Text(formatPaise(v), style: AppText.balance(color: Colors.white)),
          ),
          Text('Looked after by $parent', style: AppText.small(color: Colors.white)),
        ],
      ),
    );
  }
}

/// A ring that empties as the money is spent.
class _Ring extends StatelessWidget {
  const _Ring({required this.label, required this.left, required this.limit, required this.color});
  final String label;
  final int left;
  final int limit;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(20)),
      child: Row(children: [
        SizedBox(
          width: 46,
          height: 46,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: limit == 0 ? 0 : left / limit),
            duration: const Duration(milliseconds: 800),
            curve: Curves.easeOutCubic,
            builder: (context, v, _) => CircularProgressIndicator(value: v, strokeWidth: 6, color: color, backgroundColor: color.withValues(alpha: 0.15), strokeCap: StrokeCap.round),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(formatPaise(left), style: AppText.heading())),
            Text(label, style: AppText.small()),
          ]),
        ),
      ]),
    );
  }
}

class _Big extends StatelessWidget {
  const _Big({required this.icon, required this.label, required this.color, required this.onTap});
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: Icon(icon, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body(weight: FontWeight.w700))),
          ]),
        ),
      ),
    );
  }
}
