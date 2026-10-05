import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../api.dart';
import '../../theme.dart';
import '../money/pay_flow.dart';

/// Camera screen that reads a Pointy QR code and opens "Pay" for that
/// person. (PayPal cannot pay UPI QR codes, so only Pointy codes work.)
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _handling = false;
  String? _message;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handling) return; // the camera reports the same code many times a second
    final raw = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
    if (raw == null) return;
    final id = userIdFromQr(raw);
    if (id == null) {
      setState(() => _message = raw.startsWith('upi:')
          ? 'That is a UPI code. Pointy pays Pointy codes only.'
          : 'That is not a Pointy code.');
      return;
    }
    _handling = true;
    try {
      final person = await api.person(id);
      if (!mounted) return;
      if (person.id == api.userId) {
        setState(() => _message = 'That is your own code.');
        _handling = false;
        return;
      }
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => PayAmountScreen(person: person)));
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
      _handling = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.ink,
      appBar: AppBar(
        backgroundColor: AppColors.ink,
        foregroundColor: Colors.white,
        title: Text('Scan to pay', style: AppText.heading(color: Colors.white)),
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MobileScanner(
                      onDetect: _onDetect,
                      errorBuilder: (context, error) => Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
                          child: Text('The camera is not available. Allow camera access, or pay by mobile number.',
                              textAlign: TextAlign.center, style: AppText.body(color: Colors.white)),
                        ),
                      ),
                    ),
                    // A frame to aim with.
                    Center(
                      child: Container(
                        width: 220,
                        height: 220,
                        decoration: BoxDecoration(
                          border: Border.all(color: AppColors.amber500, width: 3),
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Text(_message ?? 'Point at a friend\'s Pointy QR', style: AppText.body(color: _message == null ? AppColors.lineStrong : AppColors.amber500)),
          Padding(
            padding: const EdgeInsets.all(24),
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: AppColors.slate)),
              onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const PayPersonScreen())),
              child: const Text('Pay by mobile number instead'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Reads the user id out of `pointy://pay?u=ID&n=NAME`.
String? userIdFromQr(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.scheme != 'pointy' || uri.host != 'pay') return null;
  final id = uri.queryParameters['u'];
  return (id == null || id.isEmpty) ? null : id;
}
