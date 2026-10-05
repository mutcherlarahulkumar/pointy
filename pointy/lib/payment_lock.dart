import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'theme.dart';
import 'widgets/pin_pad.dart';

/// How payments are confirmed. The Pointy PIN (set at sign-up) is the
/// default; the person can switch to fingerprint or face in Profile.
enum PayCheck { pin, biometric }

/// Asks the person to prove it is them before money leaves their balance or
/// share: every payment, every time.
class PaymentLock {
  static const _modeKey = 'pointy.pay_check';

  /// Tests swap this for one that does not talk to the phone.
  static PaymentLock instance = PaymentLock();

  final _auth = LocalAuthentication();

  /// The chosen check; the PIN unless the person picked fingerprint.
  Future<PayCheck> mode() async {
    try {
      final v = (await SharedPreferences.getInstance()).getString(_modeKey);
      return v == 'biometric' ? PayCheck.biometric : PayCheck.pin;
    } catch (_) {
      return PayCheck.pin;
    }
  }

  Future<void> setMode(PayCheck m) async {
    try {
      await (await SharedPreferences.getInstance()).setString(_modeKey, m.name);
    } catch (_) {}
  }

  /// Whether this phone has a fingerprint or face enrolled.
  Future<bool> canUseBiometrics() async {
    try {
      if (!await _auth.isDeviceSupported() || !await _auth.canCheckBiometrics) return false;
      return (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// The fingerprint or face prompt (not the phone's own PIN). True when it
  /// matched; false when cancelled or not available, so the caller asks for
  /// the Pointy PIN instead.
  Future<bool> biometricCheck(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason, biometricOnly: true, persistAcrossBackgrounding: true);
    } catch (_) {
      return false;
    }
  }
}

/// Call right before a payment. Returns true when the person confirmed it.
/// [what] reads as "Pay ₹200 to Asha". With fingerprint chosen, a failed or
/// cancelled scan falls back to the PIN, so nobody is ever locked out.
Future<bool> confirmPayment(BuildContext context, String what) async {
  final lock = PaymentLock.instance;
  if (await lock.mode() == PayCheck.biometric && await lock.biometricCheck(what)) return true;
  if (!context.mounted) return false;
  return askPin(context, what);
}

/// Shows the Pointy PIN sheet; true when the server accepted the PIN.
Future<bool> askPin(BuildContext context, String what) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (_) => _PinSheet(what: what),
  );
  return ok == true;
}

/// The Pointy PIN sheet: six digits, checked by the server.
class _PinSheet extends StatefulWidget {
  const _PinSheet({required this.what});
  final String what;

  @override
  State<_PinSheet> createState() => _PinSheetState();
}

class _PinSheetState extends State<_PinSheet> {
  String _pin = '';
  bool _busy = false;
  String? _error;

  Future<void> _digit(String d) async {
    if (_pin.length >= 6 || _busy) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length < 6) return;
    setState(() => _busy = true);
    try {
      await api.verifyPin(_pin);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      final left = e.details?['attempts_left'];
      setState(() {
        _busy = false;
        _pin = '';
        _error = e.code == 'wrong_pin' && left is num
            ? 'Wrong PIN. ${left.toInt()} ${left == 1 ? 'try' : 'tries'} left.'
            : e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      // Scrolls on short screens instead of cutting off the number pad.
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.line, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),
            Icon(Icons.lock_outline_rounded, color: AppColors.pine700, size: 32),
            const SizedBox(height: 8),
            Text('Enter your PIN', style: AppText.title()),
            const SizedBox(height: 4),
            Text(widget.what, textAlign: TextAlign.center, style: AppText.body(color: AppColors.slate)),
            const SizedBox(height: 20),
            PinDots(length: _pin.length, error: _error != null),
            SizedBox(
              height: 44,
              child: Center(
                child: _busy
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(_error ?? '', textAlign: TextAlign.center, style: AppText.detail(color: AppColors.error)),
              ),
            ),
            NumberPad(
              enabled: !_busy,
              onDigit: _digit,
              onBackspace: () => setState(() => _pin = _pin.isEmpty ? '' : _pin.substring(0, _pin.length - 1)),
            ),
          ],
        ),
      ),
    );
  }
}
