import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../widgets/flow_scaffold.dart';
import 'pin_create.dart';

const signUpSteps = ['Number', 'Name', 'PIN'];

/// Sign-up step 2: what friends see.
class NameScreen extends StatefulWidget {
  const NameScreen({super.key, required this.phone});

  final String phone;

  @override
  State<NameScreen> createState() => _NameScreenState();
}

class _NameScreenState extends State<NameScreen> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _valid => _name.text.trim().length >= 2;

  void _next() => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PinCreateScreen(phone: widget.phone, name: _name.text.trim())));

  @override
  Widget build(BuildContext context) {
    return FlowScaffold(
      steps: signUpSteps,
      step: 1,
      title: 'What should friends call you?',
      subtitle: 'This is the name people see when you pay or ask them for money.',
      buttonLabel: 'Continue',
      onNext: _valid ? _next : null,
      children: [
        TextField(
          controller: _name,
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.words,
          style: AppText.heading(),
          decoration: const InputDecoration(labelText: 'Your name', hintText: 'e.g. Asha Rao', counterText: ''),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _valid ? _next() : null,
        ),
      ],
    );
  }
}
