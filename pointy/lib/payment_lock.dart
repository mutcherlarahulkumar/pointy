import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'theme.dart';
import 'widgets/pin_pad.dart';

/// Asks the person to prove it is them before money leaves their balance or
/// share: the phone's fingerprint, face or screen lock when it has one,
/// otherwise their Pointy PIN (checked by the server).
class PaymentLock {
  static const _prefKey = 'pointy.payment_lock';

  /// Tests swap this for one that does not talk to the phone.
  static PaymentLock instance = PaymentLock();

  final _auth = LocalAuthentication();

  /// Whether payments ask at all. On unless the person turned it off.
  Future<bool> isOn() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(_prefKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<void> setOn(bool on) async {
    try {
      await (await SharedPreferences.getInstance()).setBool(_prefKey, on);
    } catch (_) {}
  }

  /// The phone's own check. Null means the phone cannot do it (no lock set,
  /// no hardware, or the plugin is missing), so the caller asks for the PIN.
  Future<bool?> deviceCheck(String reason) async {
    try {
      if (!await _auth.isDeviceSupported()) return null;
      return await _auth.authenticate(localizedReason: reason, persistAcrossBackgrounding: true);
    } on LocalAuthException catch (e) {
      // The person cancelled: stop. Anything else: fall back to the PIN.
      if (e.code == LocalAuthExceptionCode.userCanceled || e.code == LocalAuthExceptionCode.systemCanceled) return false;
      return null;
    } catch (_) {
      return null;
    }
  }
}

/// Call right before a payment. Returns true when the person confirmed it.
/// [what] reads as "Pay ₹200 to Asha".
Future<bool> confirmPayment(BuildContext context, String what) async {
  final lock = PaymentLock.instance;
  if (!await lock.isOn()) return true;
  final device = await lock.deviceCheck(what);
  if (device != null) return device;
  if (!context.mounted) return false;
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (_) => _PinSheet(what: what),
  );
  return ok == true;
}

/// The Pointy PIN, for phones without a fingerprint or screen lock.
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
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.line, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),
            const Icon(Icons.lock_outline_rounded, color: AppColors.pine700, size: 32),
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
