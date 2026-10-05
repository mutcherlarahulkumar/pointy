import 'package:flutter/material.dart';

import '../../api.dart';
import '../../models.dart';
import '../../payment_lock.dart';
import '../../session.dart';
import '../../look.dart';
import '../../theme.dart';
import '../../tour.dart';
import '../../widgets/async_view.dart';
import '../../widgets/avatar.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tile_icon.dart';
import '../ai/ai_settings.dart';
import '../money/my_qr.dart';
import '../money/paypal_account.dart';
import '../money/requests.dart';
import 'how_it_works.dart';
import 'payment_check.dart';

/// You: your details, your QR, settings and sign out.
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

  @override
  Widget build(BuildContext context) {
    void go(Widget s) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => s));
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
            const SectionTitle('Money'),
            tile(Icons.qr_code_2_rounded, 'My QR', 'Friends scan it to pay you', () => go(const MyQrScreen())),
            tile(Icons.swap_vert_rounded, 'Requests', 'Money asked of you, and by you', () => go(const RequestsScreen())),
            tile(Icons.account_balance_rounded, 'Withdrawal account', me.paypalEmail.isEmpty ? 'Add the PayPal account your withdrawals go to' : 'PayPal · ${me.paypalEmail}',
                () async {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PayPalAccountScreen(current: me.paypalEmail)));
              setState(() => _me = api.me());
            }),
            const SectionTitle('Settings'),
            tile(
              _check == PayCheck.biometric ? Icons.fingerprint_rounded : Icons.pin_rounded,
              'Confirm payments',
              _check == PayCheck.biometric ? 'With your fingerprint or face' : 'With your Pointy PIN',
              () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PaymentCheckScreen()));
                _loadCheck();
              },
            ),
            tile(Icons.palette_outlined, 'App colour', AppColors.palette.name, _pickColour),
            tile(Icons.tune_rounded, 'What the AI may use', 'Choose what suggestions can look at', () => go(const AiSettingsScreen())),
            tile(Icons.explore_outlined, 'Take the tour', 'What each part of the app does, step by step', () => startTour(context)),
            tile(Icons.info_outline_rounded, 'How Pointy works in India', 'Where PayPal fits in', () => go(const HowItWorksScreen())),
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
