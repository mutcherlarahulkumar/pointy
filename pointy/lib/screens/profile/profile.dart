import 'package:flutter/material.dart';

import '../../api.dart';
import '../../models.dart';
import '../../session.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/avatar.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tile_icon.dart';
import '../ai/ai_settings.dart';
import '../money/my_qr.dart';
import '../money/requests.dart';
import 'how_it_works.dart';

/// You: your details, your QR, settings and sign out.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final Future<Me> _me = api.me();

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
            const SectionTitle('Settings'),
            tile(Icons.tune_rounded, 'What the AI may use', 'Choose what suggestions can look at', () => go(const AiSettingsScreen())),
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
