import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../api.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/avatar.dart';

/// The text inside a Pointy QR code. Scanning it opens "Pay" for that person.
String qrPayload(Person p) => 'pointy://pay?u=${Uri.encodeComponent(p.id)}&n=${Uri.encodeComponent(p.name)}';

/// Your QR code: a friend scans it to pay you.
class MyQrScreen extends StatefulWidget {
  const MyQrScreen({super.key});

  @override
  State<MyQrScreen> createState() => _MyQrScreenState();
}

class _MyQrScreenState extends State<MyQrScreen> {
  late final Future<Me> _me = api.me();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.pine900,
      appBar: AppBar(
        backgroundColor: AppColors.pine900,
        foregroundColor: Colors.white,
        title: Text('My QR', style: AppText.heading(color: Colors.white)),
      ),
      body: AsyncView<Me>(
        future: _me,
        builder: (context, me) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(28), boxShadow: cardShadow),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Avatar(me.user.name, size: 56),
                  const SizedBox(height: 10),
                  Text(me.user.name, style: AppText.heading()),
                  Text('+91 ${formatPhone(me.user.phone)}', style: AppText.detail()),
                  const SizedBox(height: 16),
                  QrImageView(
                    data: qrPayload(me.user),
                    size: 220,
                    eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.circle, color: AppColors.pine900),
                    dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.circle, color: AppColors.pine900),
                  ),
                  const SizedBox(height: 12),
                  Text('Scan with Pointy to pay me', style: AppText.detail(weight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
