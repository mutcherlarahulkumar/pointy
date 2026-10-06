import 'package:flutter/material.dart';

import '../../api.dart';
import '../../models.dart';
import '../../payment_lock.dart';
import '../../session.dart';
import '../../look.dart';
import '../family/family.dart';
import '../../theme.dart';
import '../../tour.dart';
import '../../widgets/async_view.dart';
import '../../widgets/avatar.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tile_icon.dart';
import '../../tabs.dart';
import '../ai/ai_settings.dart';
import '../ai/pointy_ai.dart';
import '../ai/suggestions.dart';
import '../assistant/assistant.dart';
import '../history/history.dart';
import '../money/pay_flow.dart';
import '../money/request_flow.dart';
import '../money/split_flow.dart';
import '../money/top_up.dart';
import '../money/withdraw.dart';
import '../pay/scan.dart';
import '../trips/buy_together.dart';
import '../trips/expense_flow.dart';
import '../trips/new_trip.dart';
import '../money/bill_split.dart';
import '../money/my_qr.dart';
import '../money/paypal_account.dart';
import '../money/requests.dart';
import 'how_it_works.dart';
import 'payment_check.dart';

/// You: your details, every feature of Pointy in one list, settings and
/// sign out.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late Future<Me> _me = api.me();
  PayCheck? _check;

  @override
  void initState() {
    super.initState();
    _loadCheck();
  }

  Future<void> _loadCheck() async {
    final m = await PaymentLock.instance.mode();
    if (mounted) setState(() => _check = m);
  }

  Future<void> _signOut() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You will need your mobile number and PIN to sign back in.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sign out')),
        ],
      ),
    );
    if (ok == true) await Session.signOut();
  }

  // Two swatches; the app redraws in the chosen colour at once.
  Future<void> _pickColour() async {
    final picked = await showModalBottomSheet<AppPalette>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('App colour', style: AppText.heading()),
              const SizedBox(height: 4),
              Text('Buttons, the trip wallet and highlights use it.', style: AppText.detail()),
              const SizedBox(height: 16),
              Row(
                children: [
                  for (final p in AppPalette.all) ...[
                    if (p != AppPalette.all.first) const SizedBox(width: 12),
                    Expanded(child: _Swatch(palette: p, on: p.id == AppColors.palette.id, onTap: () => Navigator.pop(c, p))),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && picked.id != AppColors.palette.id) await AppLook.use(picked);
  }

  void _go(Widget s) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => s));

  // Opens one of the bottom-bar tabs from here.
  void _tab(int i) {
    Navigator.of(context).popUntil((r) => r.isFirst);
    MainTabs.current.value = i;
  }

  // Features that live inside a trip: pick the trip first (or plan one).
  Future<void> _withTrip(String what, Widget Function(Trip) screen) async {
    final List<Trip> open;
    try {
      open = (await api.trips()).where((t) => t.isOpen).toList();
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (!mounted) return;
    if (open.isEmpty) {
      showMessage(context, '$what happens inside a trip. Plan one first.');
      _go(const NewTripScreen());
      return;
    }
    final trip = open.length == 1
        ? open.first
        : await showModalBottomSheet<Trip>(
            context: context,
            showDragHandle: true,
            builder: (c) => SafeArea(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('$what for which trip?', style: AppText.heading()),
                const SizedBox(height: 8),
                for (final t in open)
                  ListTile(leading: const Icon(Icons.luggage_rounded), title: Text(t.name), subtitle: Text(t.place), onTap: () => Navigator.pop(c, t)),
              ]),
            ),
          );
    if (trip != null && mounted) _go(screen(trip));
  }

  Future<void> _family() async {
    await Navigator.of(context).push(familyRoute());
    if (mounted) setState(() { _me = api.me(); });
  }

  /// Everything Pointy does, grouped, each with one line saying what it is,
  /// so nothing is hidden. Child accounts see only what they can use.
  List<(String, List<(IconData, String, String, VoidCallback)>)> _features(Me me) {
    final family = (
      Icons.family_restroom_rounded,
      'Family',
      me.isChild
          ? 'Your parent and your limits'
          : (me.familyInvites > 0 ? 'A parent is asking to link your account' : 'Pointy Parenting: look after a child\'s wallet'),
      _family,
    );
    final settings = <(IconData, String, String, VoidCallback)>[
      (
        _check == PayCheck.biometric ? Icons.fingerprint_rounded : Icons.pin_rounded,
        'Confirm payments',
        _check == PayCheck.biometric ? 'With your fingerprint or face' : 'With your Pointy PIN',
        () async {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PaymentCheckScreen()));
          _loadCheck();
        }
      ),
      (Icons.palette_outlined, 'App colour', AppColors.palette.name, _pickColour),
      if (!me.isChild) (Icons.explore_outlined, 'Take the tour', 'What each part of the app does, step by step', () => startTour(context)),
      (Icons.info_outline_rounded, 'How Pointy works in India', 'Where PayPal fits in, and why', () => _go(const HowItWorksScreen())),
    ];
    if (me.isChild) {
      return [
        ('Money', [
          (Icons.north_east_rounded, 'Pay someone', 'By mobile number or from your people', () => _go(const PayPersonScreen())),
          (Icons.qr_code_scanner_rounded, 'Scan a QR', 'Pay a friend\'s Pointy QR code', () => _go(const ScanScreen())),
          (Icons.qr_code_2_rounded, 'My QR', 'Friends scan it to pay you', () => _go(const MyQrScreen())),
          (Icons.swap_vert_rounded, 'Requests', 'Money asked of you, and by you', () => _go(const RequestsScreen())),
          (Icons.receipt_long_rounded, 'History', 'Every payment, newest first', () => _go(const HistoryScreen(standalone: true))),
        ]),
        ('Family', [family]),
        ('Settings', settings),
      ];
    }
    return [
      ('Money', [
        (Icons.add_card_rounded, 'Add money', 'Top up your balance with PayPal', () => _go(const TopUpScreen())),
        (Icons.north_east_rounded, 'Pay someone', 'Instant, to anyone on Pointy', () => _go(const PayPersonScreen())),
        (Icons.call_received_rounded, 'Request money', 'Ask someone to pay you', () => _go(const RequestPersonScreen())),
        (Icons.call_split_rounded, 'Split a bill', 'Everyone gets a request for their part', () => _go(const SplitBillScreen())),
        (Icons.receipt_long_rounded, 'Split by items', 'Scan the bill; each pays for what they had', () => _go(const BillSplitScreen())),
        (Icons.qr_code_scanner_rounded, 'Scan a QR', 'Pay a friend\'s Pointy QR code', () => _go(const ScanScreen())),
        (Icons.qr_code_2_rounded, 'My QR', 'Friends scan it to pay you', () => _go(const MyQrScreen())),
        (Icons.swap_vert_rounded, 'Requests', 'Money asked of you, and by you', () => _go(const RequestsScreen())),
        (Icons.output_rounded, 'Withdraw', 'To your PayPal, then your bank', () => _go(const WithdrawScreen())),
        (
          Icons.account_balance_rounded,
          'Withdrawal account',
          me.paypalEmail.isEmpty ? 'Add the PayPal account your withdrawals go to' : 'PayPal · ${me.paypalEmail}',
          () async {
            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PayPalAccountScreen(current: me.paypalEmail)));
            setState(() { _me = api.me(); });
          }
        ),
        (Icons.receipt_long_rounded, 'History', 'Every payment, newest first, tagged Trip or Personal', () => _tab(3)),
      ]),
      ('Trips', [
        (Icons.luggage_rounded, 'Your trips', 'Shared wallets for a group', () => _tab(1)),
        (Icons.add_location_alt_outlined, 'Plan a trip', 'Dates, people and how much each puts in', () => _go(const NewTripScreen())),
        (Icons.send_to_mobile_rounded, 'Pay from a trip', 'Pay anyone; the cost is split. Scan the bill with AI', () => _withTrip('Paying', (t) => ExpenseAmountScreen(trip: t))),
        (Icons.savings_outlined, 'Collect deposits', 'The assistant drafts requests; you OK them', () => _withTrip('Collecting', (t) => AssistantScreen(trip: t))),
      ]),
      ('AI', [
        (Icons.auto_awesome, 'Ask Pointy AI', 'Questions about your money, or "pay Dev 200"', () => _go(const PointyAiScreen())),
        (Icons.shopping_bag_outlined, 'Shop with AI', 'Find things to buy, with prices from real shops', () => _go(const PointyAiScreen(draft: 'Find '))),
        (Icons.groups_rounded, 'Buy together', 'AI finds it; bought only if the whole trip says yes', () => _withTrip('Buying together', (t) => BuyTogetherScreen(trip: t))),
        (Icons.lightbulb_outline_rounded, 'Suggestions', 'Ideas from the time, place and your trips', () => _go(const SuggestionsScreen())),
        (Icons.insights_rounded, 'Insights', 'Where the money went, with an AI summary', () => _tab(2)),
        (Icons.tune_rounded, 'What the AI may use', 'Choose what suggestions can look at', () => _go(const AiSettingsScreen())),
      ]),
      ('Family', [family]),
      ('Settings', settings),
    ];
  }

  @override
  Widget build(BuildContext context) {
    Widget tile(IconData icon, String title, String sub, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Card(
            child: ListTile(
              leading: TileIcon(icon),
              title: Text(title, style: AppText.body(weight: FontWeight.w600)),
              subtitle: Text(sub, style: AppText.detail()),
              trailing: const Icon(Icons.chevron_right),
              onTap: onTap,
            ),
          ),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: AsyncView<Me>(
        future: _me,
        builder: (context, me) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Center(child: Avatar(me.user.name, size: 80)),
            const SizedBox(height: 12),
            Center(child: Text(me.user.name, style: AppText.title())),
            Center(child: Text('+91 ${formatPhone(me.user.phone)}', style: AppText.body(color: AppColors.slate))),
            for (final group in _features(me)) ...[
              SectionTitle(group.$1),
              for (final f in group.$2) tile(f.$1, f.$2, f.$3, f.$4),
            ],
            const SizedBox(height: 8),
            Text('Server: ${api.baseUrl} · PayPal: ${me.paypalMode}', textAlign: TextAlign.center, style: AppText.small()),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: AppColors.error, side: const BorderSide(color: AppColors.errorBg)),
              icon: const Icon(Icons.logout_rounded),
              label: const Text('Sign out'),
              onPressed: _signOut,
            ),
          ],
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.palette, required this.on, required this.onTap});

  final AppPalette palette;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: palette.c100,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: on ? palette.c700 : Colors.transparent, width: 2),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                for (final c in [palette.c900, palette.c700, palette.c500]) ...[
                  Container(width: 22, height: 22, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
                  const SizedBox(width: 4),
                ],
                const Spacer(),
                if (on) Icon(Icons.check_circle_rounded, color: palette.c700),
              ]),
              const SizedBox(height: 10),
              Text(palette.name, style: AppText.body(weight: FontWeight.w700, color: palette.c900)),
            ],
          ),
        ),
      ),
    );
  }
}
