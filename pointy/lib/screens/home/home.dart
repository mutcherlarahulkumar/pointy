import 'dart:async';

import 'package:flutter/material.dart';

import '../../api.dart';
import '../../dates.dart';
import '../../money.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../widgets/ai_card.dart';
import '../../widgets/async_view.dart';
import '../../widgets/avatar.dart';
import '../../widgets/personal_card.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tile_icon.dart';
import '../money/my_qr.dart';
import '../money/pay_flow.dart';
import '../money/request_flow.dart';
import '../money/requests.dart';
import '../money/split_flow.dart';
import '../money/top_up.dart';
import '../pay/scan.dart';
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

class _HomeScreenState extends State<HomeScreen> {
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
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _refreshQuietly());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
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
        if (snap.data == null) return const Center(child: CircularProgressIndicator());
        return _body(snap.data!);
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
              GestureDetector(onTap: () => _go(const ProfileScreen()), child: Avatar(me.user.name, size: 44)),
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
          PersonalCard(
            balancePaise: me.personalBalancePaise,
            caption: me.isMock ? 'Demo mode · PayPal is simulated' : 'Add money with PayPal sandbox',
            actions: [
              CardButton(icon: Icons.add_rounded, label: 'Add money', primary: true, onTap: () => _go(const TopUpScreen())),
              CardButton(icon: Icons.qr_code_2_rounded, label: 'My QR', onTap: () => _go(const MyQrScreen())),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              _action(Icons.north_east_rounded, 'Pay', () => _go(const PayPersonScreen())),
              _action(Icons.call_received_rounded, 'Request', () => _go(const RequestPersonScreen())),
              _action(Icons.call_split_rounded, 'Split bill', () => _go(const SplitBillScreen())),
              _action(Icons.qr_code_scanner_rounded, 'Scan', () => _go(const ScanScreen())),
            ],
          ),
          if (d.toPay.isNotEmpty) ...[
            const SizedBox(height: 16),
            _waiting(d.toPay),
          ],
          const SizedBox(height: 16),
          AiCard(
            title: d.suggestion.title,
            reasons: d.suggestion.reasons,
            actionLabel: d.suggestion.wallet == 'trip' ? 'Open the trip' : 'Pay someone',
            onTap: d.suggestion.wallet == 'trip' ? widget.onOpenTrips : () => _go(const PayPersonScreen()),
          ),
          SectionTitle('People', action: 'Requests', onAction: () => _go(const RequestsScreen())),
          if (d.people.isEmpty)
            SurfaceCard(
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
