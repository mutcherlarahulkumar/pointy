import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../theme.dart';
import 'pay_draft.dart';
import 'payee.dart';

/// Camera screen that reads an app or PayPal payee QR code, then opens the
/// Payee step with what it found.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, this.draft});

  final PayDraft? draft;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _done = false;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    final raw = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
    if (raw == null) return;
    _done = true; // the camera reports the same code many times a second
    final draft = widget.draft ?? PayDraft();
    applyScannedCode(draft, raw);
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => PayeeScreen(draft: draft)));
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
                borderRadius: BorderRadius.circular(24),
                child: MobileScanner(
                  onDetect: _onDetect,
                  errorBuilder: (context, error) => Center(
                    child: Text(
                      'The camera is not available here.\nEnter the payee instead.',
                      textAlign: TextAlign.center,
                      style: AppText.body(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Text('Point at a Pointy or PayPal payee code', style: AppText.detail(color: AppColors.lineStrong)),
          Padding(
            padding: const EdgeInsets.all(24),
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: AppColors.slate)),
              onPressed: () => Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => PayeeScreen(draft: widget.draft ?? PayDraft())),
              ),
              child: const Text('Enter phone or ID instead'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Reads a payee out of a QR code. Understands links with query parameters
/// such as "upi://pay?pa=shack@upi&pn=Beach%20shack" or
/// "pointy://pay?email=shack@example.com&name=Beach%20shack", and a bare
/// email or PayPal.me link.
void applyScannedCode(PayDraft d, String raw) {
  final uri = Uri.tryParse(raw.trim());
  final q = uri?.queryParameters ?? const {};
  final email = q['email'] ?? q['pa'] ?? '';
  final name = q['name'] ?? q['pn'] ?? '';
  if (email.isNotEmpty || name.isNotEmpty) {
    d.payeeEmail = email;
    d.payeeName = name.isNotEmpty ? name : email;
    final am = q['am'];
    if (am != null && d.amountPaise == 0) {
      // "am" is rupees with up to two decimals; parse it as text, not a double.
      final m = RegExp(r'^(\d+)(?:\.(\d{1,2}))?$').firstMatch(am);
      if (m != null) d.amountPaise = int.parse(m.group(1)!) * 100 + int.parse((m.group(2) ?? '').padRight(2, '0'));
    }
    return;
  }
  if (uri != null && uri.host.contains('paypal.me') && uri.pathSegments.isNotEmpty) {
    d.payeeName = uri.pathSegments.first;
    return;
  }
  d.payeeName = raw.trim();
  if (raw.contains('@')) d.payeeEmail = raw.trim();
}
