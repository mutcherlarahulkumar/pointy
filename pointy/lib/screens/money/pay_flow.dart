import 'package:flutter/material.dart';

import '../../api.dart';
import '../../payment_lock.dart';
import '../../money.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/avatar.dart';
import '../../widgets/amount_field.dart';
import '../../widgets/flow_scaffold.dart';
import '../../widgets/person_picker.dart';
import '../../widgets/section_title.dart';
import '../../widgets/success.dart';
import '../pay/scan.dart';
import 'top_up.dart';

const _steps = ['Who', 'Amount', 'Pay'];

/// Step 1 of paying someone: find them.
class PayPersonScreen extends StatelessWidget {
  const PayPersonScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return FlowScaffold(
      appBarTitle: 'Pay',
      steps: _steps,
      step: 0,
      title: 'Who are you paying?',
      hint: 'Pick a friend, type their mobile number, or scan their QR.',
      buttonLabel: 'Choose someone above',
      onNext: null,
      children: [
        PersonPicker(
          onScan: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const ScanScreen())),
          onPicked: (people) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PayAmountScreen(person: people.first))),
        ),
      ],
    );
  }
}

/// Step 2: how much and what for.
class PayAmountScreen extends StatefulWidget {
  const PayAmountScreen({super.key, required this.person, this.amountPaise, this.note});

  final Person person;
  final int? amountPaise;
  final String? note;

  @override
  State<PayAmountScreen> createState() => _PayAmountScreenState();
}

class _PayAmountScreenState extends State<PayAmountScreen> {
  late final _amount = TextEditingController(text: widget.amountPaise == null ? '' : paiseToInput(widget.amountPaise!));
  late final _note = TextEditingController(text: widget.note ?? '');

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final paise = parseToPaise(_amount.text);
    return FlowScaffold(
      appBarTitle: 'Pay',
      steps: _steps,
      step: 1,
      title: 'How much?',
      hint: 'Type the amount. A short note tells them what it is for.',
      buttonLabel: 'Continue',
      onNext: paise == null
          ? null
          : () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => PayConfirmScreen(person: widget.person, amountPaise: paise, note: _note.text.trim()))),
      children: [
        Center(child: Avatar(widget.person.name, size: 56)),
        const SizedBox(height: 8),
        Center(child: Text('Paying ${widget.person.name}', style: AppText.body(weight: FontWeight.w600))),
        Center(child: Text('+91 ${formatPhone(widget.person.phone)}', style: AppText.detail())),
        const SizedBox(height: 8),
        AmountField(controller: _amount, onChanged: () => setState(() {}), chipsRupees: const [100, 250, 500, 1000]),
        const SizedBox(height: 16),
        TextField(
          controller: _note,
          maxLength: 60,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'What is it for? (optional)', hintText: 'Chai, cab, movie…', counterText: ''),
        ),
      ],
    );
  }
}

/// Step 3: check and pay from your balance.
class PayConfirmScreen extends StatefulWidget {
  const PayConfirmScreen({super.key, required this.person, required this.amountPaise, required this.note});

  final Person person;
  final int amountPaise;
  final String note;

  @override
  State<PayConfirmScreen> createState() => _PayConfirmScreenState();
}

class _PayConfirmScreenState extends State<PayConfirmScreen> {
  late Future<Me> _me = api.me();
  // One key per payment: a double tap or a retry cannot pay twice.
  final _key = SubmitKey();
  bool _busy = false;

  Future<void> _pay({String parentCode = ''}) async {
    // A parent's code is the OK for this payment; the PIN was asked already.
    if (parentCode.isEmpty && !await confirmPayment(context, 'Pay ${formatPaise(widget.amountPaise)} to ${widget.person.name}')) return;
    setState(() => _busy = true);
    try {
      final body = {
        'payee_user_id': widget.person.id,
        'amount_paise': widget.amountPaise,
        'description': widget.note.isEmpty ? 'Payment' : widget.note,
        'category': 'other',
        if (parentCode.isNotEmpty) 'parent_code': parentCode,
      };
      final e = await api.payPerson(body, key: _key.forRequest(body));
      if (!mounted) return;
      // Close the flow and show the result on top of where it started.
      final nav = Navigator.of(context)..popUntil((r) => r.isFirst);
      nav.push(MaterialPageRoute(
        builder: (_) => SuccessScreen(
          title: 'Paid',
          amount: formatPaise(e.amountPaise),
          subtitle: 'to ${widget.person.name}',
          rows: [('For', e.description), ('From', 'Your balance'), ('Reference', e.id)],
        ),
      ));
    } on ApiException catch (e) {
      _key.failed(e);
      if (!mounted) return;
      setState(() => _busy = false);
      if (e.code == 'needs_parent') return _askParent(e);
      showError(context, e);
      if (e.code == 'insufficient_balance') setState(() => _me = api.me());
    }
  }

  // A child's payment over their limit: ask the parent to approve it on
  // their phone, or type the code from the parent's app if they are here.
  Future<void> _askParent(ApiException e) async {
    final parent = (e.details?['parent'] as String?) ?? 'your parent';
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('This needs $parent\'s OK', style: AppText.title()),
              const SizedBox(height: 6),
              Text(e.toString(), style: AppText.body(color: AppColors.slate)),
              const SizedBox(height: 20),
              FilledButton.icon(onPressed: () => Navigator.pop(c, 'ask'), icon: const Icon(Icons.send_to_mobile_rounded), label: Text('Ask $parent on their phone')),
              const SizedBox(height: 10),
              OutlinedButton.icon(onPressed: () => Navigator.pop(c, 'code'), icon: const Icon(Icons.pin_outlined), label: Text('$parent is here: type their code')),
            ],
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'code') {
      final code = await _codeDialog(parent);
      if (code != null && mounted) await _pay(parentCode: code);
      return;
    }
    try {
      await api.askApproval(widget.person.id, widget.amountPaise, widget.note);
      if (!mounted) return;
      final nav = Navigator.of(context)..popUntil((r) => r.isFirst);
      nav.push(MaterialPageRoute(
        builder: (_) => SuccessScreen(
          pending: true,
          title: 'Sent to $parent',
          amount: formatPaise(widget.amountPaise),
          subtitle: 'to ${widget.person.name}. It is paid as soon as $parent approves.',
        ),
      ));
    } catch (err) {
      if (mounted) showError(context, err);
    }
  }

  Future<String?> _codeDialog(String parent) {
    final field = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('$parent\'s code'),
        content: TextField(
          controller: field,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          textAlign: TextAlign.center,
          style: AppText.title().copyWith(letterSpacing: 8),
          decoration: InputDecoration(hintText: '••••••', helperText: 'In $parent\'s Pointy: Family → you → Approval code'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, field.text.trim()), child: const Text('Pay')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AsyncView<Me>(
      future: _me,
      onRetry: () => setState(() => _me = api.me()),
      builder: (context, me) {
        final after = me.personalBalancePaise - widget.amountPaise;
        final short = after < 0;
        return FlowScaffold(
          appBarTitle: 'Pay',
          steps: _steps,
          step: 2,
          title: 'Check and pay',
          hint: 'Check the details. You confirm with your fingerprint or PIN.',
          buttonLabel: short ? (me.isChild ? 'Not enough pocket money' : 'Add money first') : 'Pay ${formatPaise(widget.amountPaise)}',
          busy: _busy,
          onNext: short && me.isChild
              ? null
              : short
              ? () async {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TopUpScreen(suggestPaise: -after)));
                  setState(() => _me = api.me());
                }
              : _pay,
          footer: Text.rich(
            TextSpan(children: [
              const WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.fingerprint_rounded, size: 14, color: AppColors.slate)),
              ),
              TextSpan(text: 'Instant, from your balance. You confirm with your fingerprint or PIN.', style: AppText.small()),
            ]),
            textAlign: TextAlign.center,
          ),
          children: [
            SurfaceCard(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Avatar(widget.person.name, size: 56),
                  const SizedBox(height: 10),
                  Text(widget.person.name, style: AppText.heading()),
                  Text('+91 ${formatPhone(widget.person.phone)}', style: AppText.detail()),
                  const SizedBox(height: 16),
                  Text(formatPaise(widget.amountPaise), style: AppText.balance()),
                  if (widget.note.isNotEmpty) Text(widget.note, style: AppText.body(color: AppColors.slate)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SurfaceCard(
              child: Column(
                children: [
                  _row('Your balance', formatPaise(me.personalBalancePaise)),
                  _row('After paying', formatPaise(after), color: short ? AppColors.error : null),
                ],
              ),
            ),
            if (short)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text('You need ${formatPaise(-after)} more. Add it with PayPal, then come back.',
                    style: AppText.detail(color: AppColors.error)),
              ),
          ],
        );
      },
    );
  }

  Widget _row(String label, String value, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(child: Text(label, style: AppText.detail())),
            Text(value, style: AppText.body(weight: FontWeight.w600, color: color ?? AppColors.ink)),
          ],
        ),
      );
}
