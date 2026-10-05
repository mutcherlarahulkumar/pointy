import 'package:flutter/material.dart';

import '../../api.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/flow_scaffold.dart';

/// Where Pointy pays you out: your PayPal account's email. Used when you
/// withdraw and when a trip settles.
class PayPalAccountScreen extends StatefulWidget {
  const PayPalAccountScreen({super.key, this.current = ''});

  final String current;

  @override
  State<PayPalAccountScreen> createState() => _PayPalAccountScreenState();
}

class _PayPalAccountScreenState extends State<PayPalAccountScreen> {
  late final _email = TextEditingController(text: widget.current);
  bool _busy = false;

  bool get _valid => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_email.text.trim());

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await api.setPayPalEmail(_email.text.trim());
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FlowScaffold(
      appBarTitle: 'PayPal for payouts',
      title: 'Where should Pointy pay you?',
      subtitle: 'When you withdraw, or a trip settles, the money goes from Pointy\'s PayPal business account to this PayPal account.',
      hint: 'Type the email of your PayPal account. For the demo, a sandbox personal account.',
      buttonLabel: 'Save',
      busy: _busy,
      onNext: _valid ? _save : null,
      children: [
        TextField(
          controller: _email,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(labelText: 'PayPal email', hintText: 'you@example.com', prefixIcon: Icon(Icons.alternate_email_rounded)),
        ),
        const SizedBox(height: 12),
        Text('Only you see it. Change it any time in Profile.', style: AppText.small()),
      ],
    );
  }
}
