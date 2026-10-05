import 'package:flutter/material.dart';

import '../../api.dart';
import '../../session.dart';
import '../../theme.dart';
import '../../widgets/pin_pad.dart';
import '../../widgets/stepper.dart';
import 'name.dart';

/// Sign-up step 3: choose a 6-digit PIN, then type it again to confirm.
class PinCreateScreen extends StatefulWidget {
  const PinCreateScreen({super.key, required this.phone, required this.name});

  final String phone;
  final String name;

  @override
  State<PinCreateScreen> createState() => _PinCreateScreenState();
}

class _PinCreateScreenState extends State<PinCreateScreen> {
  String _first = '';
  String _pin = '';
  bool _confirming = false;
  bool _busy = false;
  String? _error;

  static bool _weak(String p) {
    var same = true, up = true, down = true;
    for (var i = 1; i < p.length; i++) {
      final d = p.codeUnitAt(i) - p.codeUnitAt(i - 1);
      same &= d == 0;
      up &= d == 1;
      down &= d == -1;
    }
    return same || up || down;
  }

  Future<void> _digit(String d) async {
    if (_pin.length >= 6 || _busy) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length < 6) return;
    if (!_confirming) {
      if (_weak(_pin)) {
        setState(() {
          _error = 'Too easy to guess. Avoid repeats like 111111 or runs like 123456.';
          _pin = '';
        });
        return;
      }
      setState(() {
        _first = _pin;
        _pin = '';
        _confirming = true;
      });
      return;
    }
    if (_pin != _first) {
      setState(() {
        _error = 'The PINs did not match. Choose your PIN again.';
        _pin = '';
        _first = '';
        _confirming = false;
      });
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await api.register(widget.name, widget.phone, _pin);
      await Session.start(r.token, r.user.id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
        _pin = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Column(
          children: [
            const PayStepper(current: 2, steps: signUpSteps),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_confirming ? 'Type it once more' : 'Create a 6-digit PIN', style: AppText.title()),
                  const SizedBox(height: 6),
                  Text(_confirming ? 'Just to be sure.' : 'You will use it to sign in. Keep it to yourself.',
                      style: AppText.body(color: AppColors.slate)),
                ],
              ),
            ),
            const Spacer(),
            PinDots(length: _pin.length, error: _error != null),
            SizedBox(
              height: 56,
              child: Center(
                child: _busy
                    ? const CircularProgressIndicator()
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(_error ?? '', textAlign: TextAlign.center, style: AppText.detail(color: AppColors.error)),
                      ),
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
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
