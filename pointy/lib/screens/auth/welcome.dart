import 'package:flutter/material.dart';

import '../../theme.dart';
import 'phone.dart';

/// The first screen: what Pointy does, and one button to start.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    Widget point(IconData icon, String title, String body) => Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
                child: Icon(icon, color: AppColors.amber500, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppText.body(color: Colors.white, weight: FontWeight.w700)),
                    Text(body, style: AppText.detail(color: AppColors.pine100)),
                  ],
                ),
              ),
            ],
          ),
        );

    return Scaffold(
      backgroundColor: AppColors.pine900,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: AppColors.amber500, borderRadius: BorderRadius.circular(14)),
                    child: const Icon(Icons.near_me_rounded, color: AppColors.amber900),
                  ),
                  const SizedBox(width: 12),
                  Text('Pointy', style: AppText.title(color: Colors.white)),
                ],
              ),
              const Spacer(),
              Text('Money with friends,\nsorted.', style: AppText.hero(color: Colors.white)),
              const SizedBox(height: 28),
              point(Icons.bolt_rounded, 'Pay friends instantly', 'Find them by mobile number or scan their QR.'),
              point(Icons.luggage_rounded, 'Trip wallets', 'Everyone chips in, pays from one pot, splits fairly.'),
              point(Icons.auto_awesome, 'A helpful assistant', 'Suggests splits, warns on budgets, collects deposits.'),
              const Spacer(),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: AppColors.amber500, foregroundColor: AppColors.amber900),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PhoneScreen())),
                child: const Text('Get started'),
              ),
              const SizedBox(height: 10),
              Center(
                child: Text('Money is added with PayPal (sandbox for this demo).',
                    textAlign: TextAlign.center, style: AppText.small(color: AppColors.pine100)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
