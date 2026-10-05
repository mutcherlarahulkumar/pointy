import 'package:flutter/material.dart';

import '../../payment_lock.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/flow_scaffold.dart';

/// Profile → Confirm payments: choose the Pointy PIN (the default) or the
/// phone's fingerprint or face. Every payment asks one of them.
class PaymentCheckScreen extends StatefulWidget {
  const PaymentCheckScreen({super.key});

  @override
  State<PaymentCheckScreen> createState() => _PaymentCheckScreenState();
}

class _PaymentCheckScreenState extends State<PaymentCheckScreen> {
  PayCheck? _mode;
  bool _canBio = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final lock = PaymentLock.instance;
    final mode = await lock.mode();
    final can = await lock.canUseBiometrics();
    if (mounted) {
      setState(() {
        _mode = mode;
        _canBio = can;
      });
    }
  }

  Future<void> _choose(PayCheck m) async {
    if (m == _mode || _busy) return;
    setState(() => _busy = true);
    final lock = PaymentLock.instance;
    // Changing how payments are confirmed needs the PIN first, so someone
    // holding an unlocked phone cannot weaken it.
    var ok = await askPin(context, m == PayCheck.biometric ? 'Turn on fingerprint for payments' : 'Use your PIN for payments');
    if (ok && m == PayCheck.biometric) {
      // One successful scan proves the fingerprint works before relying on it.
      ok = await lock.biometricCheck('Scan to turn on fingerprint for payments');
      if (!ok && mounted) showError(context, 'Fingerprint not confirmed, so payments still use your PIN.');
    }
    if (ok) {
      await lock.setMode(m);
      if (mounted) showMessage(context, m == PayCheck.biometric ? 'Payments now ask for your fingerprint' : 'Payments now ask for your PIN');
    }
    if (mounted) {
      setState(() {
        _busy = false;
        if (ok) _mode = m;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Confirm payments')),
      body: _mode == null
          ? const SizedBox.shrink()
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text('How do you confirm a payment?', style: AppText.title()),
                const SizedBox(height: 6),
                Text('Pointy asks every time money leaves your balance or a trip wallet.', style: AppText.body(color: AppColors.slate)),
                const SizedBox(height: 14),
                const StepHint(icon: Icons.verified_user_outlined, text: 'Changing this asks for your PIN first.'),
                const SizedBox(height: 20),
                _option(
                  PayCheck.pin,
                  Icons.pin_rounded,
                  'Pointy PIN',
                  'The 6 digits you set when you signed up. Works on every phone.',
                  tag: 'Default',
                ),
                const SizedBox(height: 12),
                _option(
                  PayCheck.biometric,
                  Icons.fingerprint_rounded,
                  'Fingerprint or face',
                  _canBio
                      ? 'Faster: scan instead of typing. If a scan fails, your PIN still works.'
                      : 'Add a fingerprint or face in your phone\'s settings to use this.',
                  enabled: _canBio,
                ),
              ],
            ),
    );
  }

  Widget _option(PayCheck m, IconData icon, String title, String body, {String? tag, bool enabled = true}) {
    final selected = _mode == m;
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: Material(
        color: selected ? AppColors.pine100 : AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: enabled ? () => _choose(m) : null,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: selected ? AppColors.pine700 : AppColors.line, width: selected ? 2 : 1),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: selected ? AppColors.pine700 : AppColors.pine100, borderRadius: BorderRadius.circular(12)),
                  child: Icon(icon, color: selected ? Colors.white : AppColors.pine700),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(child: Text(title, style: AppText.body(weight: FontWeight.w700))),
                          if (tag != null) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(color: AppColors.mist, borderRadius: BorderRadius.circular(20)),
                              child: Text(tag, style: AppText.small(color: AppColors.slate, weight: FontWeight.w700)),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(body, style: AppText.detail()),
                    ],
                  ),
                ),
                Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                    color: selected ? AppColors.pine700 : AppColors.slate),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
