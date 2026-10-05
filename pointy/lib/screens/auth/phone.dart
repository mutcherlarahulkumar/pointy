import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api.dart';
import '../../theme.dart';
import '../../widgets/flow_scaffold.dart';
import 'name.dart';
import 'pin_login.dart';

/// Step 1: the mobile number. It decides whether this is a new account
/// (then name and PIN) or a returning one (then just the PIN).
class PhoneScreen extends StatefulWidget {
  const PhoneScreen({super.key});

  @override
  State<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends State<PhoneScreen> {
  final _phone = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  bool get _valid => RegExp(r'^[6-9][0-9]{9}$').hasMatch(_phone.text);

  Future<void> _next() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final check = await api.checkPhone(_phone.text);
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => check.exists ? PinLoginScreen(phone: check.phone, firstName: check.firstName) : NameScreen(phone: check.phone),
      ));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FlowScaffold(
      title: 'Your mobile number',
      hint: 'Type your 10-digit Indian mobile number.',
      subtitle: 'We use it to sign you in, and so friends can find you.',
      buttonLabel: 'Continue',
      busy: _busy,
      onNext: _valid ? _next : null,
      footer: _busy ? Text('Waking the server can take a moment…', style: AppText.small()) : null,
      children: [
        TextField(
          controller: _phone,
          autofocus: true,
          keyboardType: TextInputType.phone,
          style: AppText.title(),
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)],
          decoration: InputDecoration(
            prefixText: '+91  ',
            prefixStyle: AppText.title(color: AppColors.slate),
            hintText: '98765 43210',
          ),
          onChanged: (_) => setState(() => _error = null),
          onSubmitted: (_) => _valid ? _next() : null,
        ),
        const SizedBox(height: 8),
        if (_error != null)
          Text(_error!, style: AppText.detail(color: AppColors.error))
        else if (_phone.text.length == 10 && !_valid)
          Text('Indian mobile numbers start with 6, 7, 8 or 9', style: AppText.detail(color: AppColors.error)),
      ],
    );
  }
}
