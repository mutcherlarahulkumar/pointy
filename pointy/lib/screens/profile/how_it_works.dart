import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tile_icon.dart';

/// A plain explanation of the money model, for judges and curious users.
class HowItWorksScreen extends StatelessWidget {
  const HowItWorksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    Widget item(IconData icon, String title, String body) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SurfaceCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TileIcon(icon),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: AppText.body(weight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(body, style: AppText.detail()),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('How Pointy works')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          item(Icons.login_rounded, 'Money comes in with PayPal',
              'Adding money uses PayPal checkout. This demo uses the PayPal sandbox with a US business account, so amounts are charged in USD and shown in rupees.'),
          item(Icons.swap_horiz_rounded, 'Everything else stays in Pointy',
              'Paying friends, splitting, trip wallets and refunds move money between Pointy balances instantly. PayPal stopped payments between Indian accounts in 2021, so Pointy does not rely on them.'),
          item(Icons.output_rounded, 'Money goes out with Withdraw',
              'Withdraw sends money from your Pointy balance to your PayPal account, and from there to your bank. It is the only time money leaves Pointy.'),
          item(Icons.account_balance_rounded, 'Every rupee is accounted for',
              'A double-entry ledger records each movement. Balances are always worked out from it, never typed in.'),
          item(Icons.qr_code_2_rounded, 'Pointy QR codes, not UPI',
              'PayPal cannot pay UPI QR codes, so Pointy scans its own codes. Paid a shop by UPI? Log it in a trip as "I paid" and the trip wallet pays you back.'),
          item(Icons.auto_awesome, 'The assistant never moves money',
              'Suggestions and deposit plans wait for your tap. Nothing is paid or sent on its own.'),
        ],
      ),
    );
  }
}
