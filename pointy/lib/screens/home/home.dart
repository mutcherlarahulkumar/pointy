import 'dart:async';

import 'package:flutter/material.dart';

import '../../api.dart';
import '../../dates.dart';
import '../../money.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../tabs.dart';
import '../../tour.dart';
import '../../widgets/ai_card.dart';
import '../../widgets/async_view.dart';
import '../../widgets/avatar.dart';
import '../../widgets/personal_card.dart';
import '../../widgets/section_title.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/tile_icon.dart';
import '../money/my_qr.dart';
import '../money/pay_flow.dart';
import '../money/request_flow.dart';
import '../money/requests.dart';
import '../money/split_flow.dart';
import '../money/top_up.dart';
import '../money/withdraw.dart';
import '../profile/profile.dart';
import 'alerts.dart';

/// Home is about your own money: balance, quick actions, what people are
/// asking you for, and who you pay often. It refreshes every few seconds so
/// a payment from a friend's phone shows up by itself.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.onOpenTrips});

  final VoidCallback? onOpenTrips;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeData {
  final Me me;
  final Suggestion suggestion;
  final List<Person> people;
  final List<MoneyRequest> toPay;
  _HomeData(this.me, this.suggestion, this.people, this.toPay);
}

class _HomeScreenState extends State<HomeScreen> with ReloadWhenShown {
  late Future<_HomeData> _data = _load();
  _HomeData? _last;
  Timer? _timer;

  Future<_HomeData> _load() async {
    final results = await Future.wait([api.me(), api.suggest(), api.contacts(), api.moneyRequests()]);
    final d = _HomeData(
      results[0] as Me,
      results[1] as Suggestion,
      results[2] as List<Person>,
      (results[3] as List<MoneyRequest>).where((r) => r.isIncoming && r.isOpen).toList(),
    );
    api.userId = d.me.user.id;
    _last = d;
    return d;
  }

  @override
  void initState() {
    super.initState();
    _checkTour();
    // Only while Home is on screen: other tabs and pages pause it.
    _timer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (MainTabs.current.value == 0 && (ModalRoute.of(context)?.isCurrent ?? true)) _refreshQuietly();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  void reloadQuietly() => _refreshQuietly();

  // Offers the tour on Home until it has been taken or dismissed.
  bool _offerTour = false;

  void _checkTour() async {
    final seen = await TourPrefs.seen();
    if (mounted && !seen) setState(() => _offerTour = true);
  }

  Widget _tourBanner() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(color: AppColors.pine100, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          const Icon(Icons.explore_rounded, color: AppColors.pine700, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('New to Pointy?', style: AppText.body(color: AppColors.pine900, weight: FontWeight.w700)),
                Text('A one-minute tour of what each part does.', style: AppText.detail(color: AppColors.pine900)),
              ],
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40), padding: const EdgeInsets.symmetric(horizontal: 14)),
            onPressed: () {
              setState(() => _offerTour = false);
              startTour(context);
            },
            child: const Text('Start tour'),
          ),
          IconButton(
            tooltip: 'Not now',
            icon: const Icon(Icons.close_rounded, size: 20, color: AppColors.pine700),
            onPressed: () {
              setState(() => _offerTour = false);
              TourPrefs.markSeen();
            },
          ),
        ],
      ),
    );
  }

  // Updates in place without showing a spinner.
  Future<void> _refreshQuietly() async {
    try {
      final d = await _load();
      if (mounted) setState(() => _data = Future.value(d));
    } catch (_) {
      // Keep showing what we have; the next tick tries again.
    }
  }

  Future<void> _go(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    _refreshQuietly();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_HomeData>(
      future: _data,
      initialData: _last,
      builder: (context, snap) {
        if (snap.hasError && snap.data == null) {
          return ErrorView(message: '${snap.error}', onRetry: () => setState(() => _data = _load()));
        }
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: snap.data == null ? const Skeleton(key: ValueKey('loading')) : KeyedSubtree(key: const ValueKey('home'), child: _body(snap.data!)),
        );
      },
    );
  }

  Widget _body(_HomeData d) {
    final me = d.me;
    return RefreshIndicator(
      onRefresh: _refreshQuietly,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
        children: [
          Row(
            children: [
              GestureDetector(key: TourKeys.profile, onTap: () => _go(const ProfileScreen()), child: Avatar(me.user.name, size: 44)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${_greeting(me.now)}, ${firstName(me.user.name)}', style: AppText.heading()),
                    Text(formatDateTime(me.now), style: AppText.detail()),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Take the tour',
                onPressed: () => startTour(context),
                icon: const Icon(Icons.explore_outlined),
              ),
              IconButton(
                key: TourKeys.alerts,
                tooltip: 'Alerts',
                onPressed: () => _go(const AlertsScreen()),
                icon: Badge(
                  isLabelVisible: me.unreadAlerts > 0,
                  label: Text('${me.unreadAlerts}'),
                  backgroundColor: AppColors.error,
                  child: const Icon(Icons.notifications_outlined),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_offerTour) ...[_tourBanner(), const SizedBox(height: 16)],
          PersonalCard(
            key: TourKeys.balance,
            balancePaise: me.personalBalancePaise,
            caption: me.isMock ? 'Demo mode · PayPal is simulated' : 'Your Pointy wallet',
            actions: [
              CardButton(key: TourKeys.addMoney, icon: Icons.add_rounded, label: 'Add money', primary: true, onTap: () => _go(const TopUpScreen())),
              CardButton(icon: Icons.output_rounded, label: 'Withdraw', onTap: () => _go(const WithdrawScreen())),
              CardButton(key: TourKeys.myQr, icon: Icons.qr_code_2_rounded, label: 'My QR', onTap: () => _go(const MyQrScreen())),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            key: TourKeys.actions,
            children: [
              _action(Icons.north_east_rounded, 'Pay', () => _go(const PayPersonScreen())),
              _action(Icons.call_received_rounded, 'Request', () => _go(const RequestPersonScreen())),
              _action(Icons.call_split_rounded, 'Split bill', () => _go(const SplitBillScreen())),
            ],
          ),
          if (d.toPay.isNotEmpty) ...[
            const SizedBox(height: 16),
            _waiting(d.toPay),
          ],
          const SizedBox(height: 16),
          AiCard(
            key: TourKeys.suggestion,
            title: d.suggestion.title,
            reasons: d.suggestion.reasons,
            actionLabel: d.suggestion.wallet == 'trip' ? 'Open the trip' : 'Pay someone',
            onTap: d.suggestion.wallet == 'trip' ? widget.onOpenTrips : () => _go(const PayPersonScreen()),
          ),
          SectionTitle('People', action: 'Requests', onAction: () => _go(const RequestsScreen())),
          if (d.people.isEmpty)
            SurfaceCard(
              key: TourKeys.people,
              child: Row(
                children: [
                  const TileIcon(Icons.group_add_outlined),
                  const SizedBox(width: 12),
                  Expanded(child: Text('Pay or request money from a friend and they appear here.', style: AppText.detail())),
                ],
              ),
            )
          else
            SizedBox(
              key: TourKeys.people,
              height: 88,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final p in d.people)
                    Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _go(PayAmountScreen(person: p)),
                        child: SizedBox(
                          width: 64,
                          child: Column(
                            children: [
                              Avatar(p.name, size: 52),
                              const SizedBox(height: 6),
                              Text(firstName(p.name), overflow: TextOverflow.ellipsis, style: AppText.small(color: AppColors.ink)),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _waiting(List<MoneyRequest> toPay) {
    final first = toPay.first;
    return Material(
      color: AppColors.pendingBg,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _go(const RequestsScreen()),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Avatar(first.requester.name, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${firstName(first.requester.name)} asked for ${formatPaise(first.amountPaise)}',
                        style: AppText.body(color: AppColors.pending, weight: FontWeight.w700)),
                    Text(toPay.length > 1 ? '+ ${toPay.length - 1} more waiting' : (first.note.isEmpty ? 'Tap to pay or decline' : first.note),
                        style: AppText.detail(color: AppColors.pending)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.pending),
            ],
          ),
        ),
      ),
    );
  }

  Widget _action(IconData icon, String label, VoidCallback onTap) => Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: [
                TileIcon(icon, size: 54),
                const SizedBox(height: 6),
                Text(label, textAlign: TextAlign.center, style: AppText.small(color: AppColors.ink, weight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      );

  String _greeting(DateTime now) => now.hour < 12 ? 'Good morning' : (now.hour < 17 ? 'Good afternoon' : 'Good evening');
}
