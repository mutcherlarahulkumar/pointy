import 'package:flutter/material.dart';

import '../../api.dart';
import '../../dates.dart';
import '../../models.dart';
import '../../money.dart';
import '../../theme.dart';
import '../../widgets/ai_card.dart';
import '../../widgets/async_view.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tag.dart';
import '../../widgets/tile_icon.dart';
import '../pay/pay_draft.dart';
import '../pay/payee.dart';
import '../pay/scan.dart';
import 'alerts.dart';

/// Where the phone is right now. The demo fixes this to the beach shack in
/// the designs; a real build would look up the nearby place type at
/// payment time, with the person's consent.
const demoPlaceType = 'restaurant';
const demoPlaceName = 'Baga';

/// Home shows your own money only: no trip wallet and no recent list.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeData {
  final Me me;
  final Suggestion suggestion;
  final List<User> payAgain;
  _HomeData(this.me, this.suggestion, this.payAgain);
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<_HomeData> _data = _load();

  Future<_HomeData> _load() async {
    final me = await api.me();
    final suggestion = await api.suggest(placeType: demoPlaceType, placeName: demoPlaceName);
    final payAgain = contactsFrom(await api.trips(), me.user.id);
    return _HomeData(me, suggestion, payAgain);
  }

  void _reload() => setState(() => _data = _load());

  Future<void> _pay(PayDraft d) async {
    await startPay(context, draft: d);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return AsyncView<_HomeData>(
      future: _data,
      onRetry: _reload,
      builder: (context, data) {
        final me = data.me;
        final s = data.suggestion;
        return RefreshIndicator(
          onRefresh: () async => _reload(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          const Icon(Icons.place_outlined, size: 16, color: AppColors.slate),
                          const SizedBox(width: 4),
                          Text('Near $demoPlaceName', style: AppText.detail()),
                        ]),
                        Text(formatDateTime(me.now), style: AppText.detail()),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Alerts',
                    icon: const Icon(Icons.notifications_outlined),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AlertsScreen())),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SurfaceCard(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Text('Personal balance', style: AppText.detail()),
                      const Spacer(),
                      Tag.wallet(false),
                    ]),
                    const SizedBox(height: 8),
                    Text(formatPaise(me.personalBalancePaise), style: AppText.balance()),
                    if (me.isMock) Text('PayPal sandbox · demo mode', style: AppText.small()),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  _action(Icons.qr_code_scanner, 'Scan to pay',
                      () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ScanScreen()))),
                  _action(Icons.person_outline, 'Pay a contact', () => _pay(PayDraft())),
                  _action(Icons.alternate_email, 'Pay by ID', () => _pay(PayDraft())),
                  _action(Icons.call_received, 'Request money', _requestMoney),
                ],
              ),
              const SizedBox(height: 16),
              AiCard(
                title: s.title,
                reasons: s.reasons,
                actionLabel: 'Start this payment',
                onTap: () => _pay(PayDraft()
                  ..placeType = demoPlaceType
                  ..placeName = demoPlaceName
                  ..applySuggestion(s)),
              ),
              if (data.payAgain.isNotEmpty) ...[
                const SectionTitle('Pay again'),
                SizedBox(
                  height: 84,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final u in data.payAgain)
                        Padding(
                          padding: const EdgeInsets.only(right: 16),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => _pay(PayDraft()
                              ..payeeName = u.name
                              ..payeeEmail = u.paypalEmail
                              ..payeeUserId = u.id),
                            child: Column(
                              children: [
                                CircleAvatar(
                                  radius: 26,
                                  backgroundColor: AppColors.pine100,
                                  child: Text(u.name[0], style: AppText.heading(color: AppColors.pine700)),
                                ),
                                const SizedBox(height: 6),
                                Text(u.name, style: AppText.small(color: AppColors.ink)),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  void _requestMoney() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Request money'),
        content: const Text('Asking one person for money is not in the backend yet. '
            'To collect trip deposits, open a trip and use the assistant on the Deposits tab.'),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  }

  Widget _action(IconData icon, String label, VoidCallback onTap) => Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              children: [
                TileIcon(icon, size: 48),
                const SizedBox(height: 6),
                Text(label, textAlign: TextAlign.center, style: AppText.small(color: AppColors.ink)),
              ],
            ),
          ),
        ),
      );
}
