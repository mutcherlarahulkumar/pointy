import 'package:flutter/material.dart';

import '../../api.dart';
import '../../money.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../widgets/amount_field.dart';
import '../../widgets/async_view.dart';
import '../../widgets/avatar.dart';
import '../../widgets/flow_scaffold.dart';
import '../../widgets/person_picker.dart';
import '../../widgets/success.dart';

const _steps = ['Who', 'Amount'];

/// Ask someone for money, step 1: who.
class RequestPersonScreen extends StatelessWidget {
  const RequestPersonScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return FlowScaffold(
      appBarTitle: 'Request money',
      steps: _steps,
      step: 0,
      title: 'Who should pay you?',
      buttonLabel: 'Choose someone above',
      onNext: null,
      children: [
        PersonPicker(
          onPicked: (people) =>
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => RequestAmountScreen(person: people.first))),
        ),
      ],
    );
  }
}

/// Step 2: how much and why, then send.
class RequestAmountScreen extends StatefulWidget {
  const RequestAmountScreen({super.key, required this.person, this.amountPaise, this.note});

  final Person person;
  final int? amountPaise;
  final String? note;

  @override
  State<RequestAmountScreen> createState() => _RequestAmountScreenState();
}

class _RequestAmountScreenState extends State<RequestAmountScreen> {
  late final _amount = TextEditingController(text: widget.amountPaise == null ? '' : paiseToInput(widget.amountPaise!));
  late final _note = TextEditingController(text: widget.note ?? '');
  final _key = newIdempotencyKey();
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _send(int paise) async {
    setState(() => _busy = true);
    try {
      final r = await api.requestMoney(widget.person.id, paise, _note.text.trim(), key: _key);
      if (!mounted) return;
      // Close the flow and show the result on top of where it started.
      final nav = Navigator.of(context)..popUntil((r) => r.isFirst);
      nav.push(MaterialPageRoute(
        builder: (_) => SuccessScreen(
          pending: true,
          title: 'Request sent',
          amount: formatPaise(r.amountPaise),
          subtitle: '${widget.person.name} can pay it from their Pointy app',
          rows: [if (r.note.isNotEmpty) ('For', r.note), ('Status', 'Waiting for ${firstName(widget.person.name)}')],
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final paise = parseToPaise(_amount.text);
    return FlowScaffold(
      appBarTitle: 'Request money',
      steps: _steps,
      step: 1,
      title: 'How much?',
      buttonLabel: paise == null ? 'Send request' : 'Ask for ${formatPaise(paise)}',
      busy: _busy,
      onNext: paise == null ? null : () => _send(paise),
      children: [
        Center(child: Avatar(widget.person.name, size: 56)),
        const SizedBox(height: 8),
        Center(child: Text('From ${widget.person.name}', style: AppText.body(weight: FontWeight.w600))),
        AmountField(controller: _amount, onChanged: () => setState(() {}), chipsRupees: const [100, 200, 500, 1000]),
        const SizedBox(height: 16),
        TextField(
          controller: _note,
          maxLength: 60,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'What is it for?', hintText: 'Movie tickets', counterText: ''),
        ),
      ],
    );
  }
}
