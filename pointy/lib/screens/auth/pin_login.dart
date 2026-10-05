import 'package:flutter/material.dart';

import '../../api.dart';
import '../../models.dart';
import '../../session.dart';
import '../../theme.dart';
import '../../widgets/avatar.dart';
import '../../widgets/pin_pad.dart';

/// Signing back in: the PIN and nothing else.
class PinLoginScreen extends StatefulWidget {
  const PinLoginScreen({super.key, required this.phone, required this.firstName});

  final String phone;
  final String firstName;

  @override
  State<PinLoginScreen> createState() => _PinLoginScreenState();
}

class _PinLoginScreenState extends State<PinLoginScreen> {
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
      final r = await api.login(widget.phone, _pin);
      await Session.start(r.token, r.user.id);
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
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _pin = '';
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.firstName.isEmpty ? 'there' : widget.firstName;
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 8),
            Avatar(name, size: 64),
            const SizedBox(height: 16),
            Text('Welcome back, $name', style: AppText.title()),
            const SizedBox(height: 4),
            Text('Enter your PIN for +91 ${formatPhone(widget.phone)}', style: AppText.detail()),
            const Spacer(),
            PinDots(length: _pin.length, error: _error != null),
            SizedBox(
              height: 52,
              child: Center(
                child: _busy
                    ? const CircularProgressIndicator()
                    : Text(_error ?? '', textAlign: TextAlign.center, style: AppText.detail(color: AppColors.error)),
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: NumberPad(
                enabled: !_busy,
                onDigit: _digit,
                onBackspace: () => setState(() => _pin = _pin.isEmpty ? '' : _pin.substring(0, _pin.length - 1)),
              ),
            ),
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Not you? Use another number')),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
