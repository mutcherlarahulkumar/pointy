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
import '../../widgets/section_title.dart';
import '../../widgets/success.dart';

const _steps = ['Bill', 'People', 'Split'];

/// Split a bill you already paid (cash, UPI, card): step 1, the bill.
class SplitBillScreen extends StatefulWidget {
  const SplitBillScreen({super.key});

  @override
  State<SplitBillScreen> createState() => _SplitBillScreenState();
}

class _SplitBillScreenState extends State<SplitBillScreen> {
  final _amount = TextEditingController();
  final _what = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    _what.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final paise = parseToPaise(_amount.text);
    return FlowScaffold(
      appBarTitle: 'Split a bill',
      steps: _steps,
      step: 0,
      title: 'What did you pay for?',
      hint: 'Type the total you paid and what it was for.',
      subtitle: 'Paid the whole bill yourself? Pointy asks everyone for their share.',
      buttonLabel: 'Continue',
      onNext: paise == null || _what.text.trim().isEmpty
          ? null
          : () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => _SplitPeopleScreen(what: _what.text.trim(), amountPaise: paise))),
      children: [
        AmountField(controller: _amount, onChanged: () => setState(() {})),
        const SizedBox(height: 16),
        TextField(
          controller: _what,
          maxLength: 40,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'What was it?', hintText: 'Dinner at Toit', counterText: ''),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }
}

class _SplitPeopleScreen extends StatefulWidget {
  const _SplitPeopleScreen({required this.what, required this.amountPaise});

  final String what;
  final int amountPaise;

  @override
  State<_SplitPeopleScreen> createState() => _SplitPeopleScreenState();
}

class _SplitPeopleScreenState extends State<_SplitPeopleScreen> {
  List<Person> _people = [];

  @override
  Widget build(BuildContext context) {
    return FlowScaffold(
      appBarTitle: 'Split a bill',
      steps: _steps,
      step: 1,
      title: 'Who was there?',
      hint: 'Tick everyone who shared it. You are counted too.',
      buttonLabel: _people.isEmpty ? 'Add at least one person' : 'Continue with ${_people.length + 1} people',
      onNext: _people.isEmpty
          ? null
          : () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => _SplitReviewScreen(what: widget.what, amountPaise: widget.amountPaise, people: _people))),
      children: [PersonPicker(multi: true, selected: _people, onPicked: (p) => setState(() => _people = p))],
    );
  }
}

class _SplitReviewScreen extends StatefulWidget {
  const _SplitReviewScreen({required this.what, required this.amountPaise, required this.people});

  final String what;
  final int amountPaise;
  final List<Person> people;

  @override
  State<_SplitReviewScreen> createState() => _SplitReviewScreenState();
}

class _SplitReviewScreenState extends State<_SplitReviewScreen> {
  bool _includeMe = true;
  bool _byShares = false;
  final Map<String, int> _weights = {};
  final _key = newIdempotencyKey();
  bool _busy = false;

  List<String> get _ids => [if (_includeMe) api.userId, ...widget.people.map((p) => p.id)];

  Map<String, int> get _parts {
    final ids = _ids;
    final parts = splitPaise(widget.amountPaise, [for (final id in ids) _byShares ? (_weights[id] ?? 1) : 1]);
    return {for (var i = 0; i < ids.length; i++) ids[i]: parts[i]};
  }

  Future<void> _send() async {
    setState(() => _busy = true);
    try {
      final made = await api.splitBill({
        'description': widget.what,
        'amount_paise': widget.amountPaise,
        'split_method': _byShares ? 'shares' : 'equal',
        'participants': [for (final id in _ids) {'user_id': id, 'weight': _weights[id] ?? 1}],
      }, key: _key);
      if (!mounted) return;
      final asked = made.fold<int>(0, (a, r) => a + r.amountPaise);
      final nav = Navigator.of(context)..popUntil((r) => r.isFirst);
      nav.push(MaterialPageRoute(
        builder: (_) => SuccessScreen(
          pending: true,
          title: 'Sent ${made.length} request${made.length == 1 ? '' : 's'}',
          amount: formatPaise(asked),
          subtitle: 'for ${widget.what}',
          rows: [for (final r in made) (r.payer.name, formatPaise(r.amountPaise))],
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
    final parts = _parts;
    final others = parts.entries.where((e) => e.key != api.userId).fold<int>(0, (a, e) => a + e.value);
    String nameOf(String id) => id == api.userId ? 'You' : widget.people.firstWhere((p) => p.id == id).name;
    return FlowScaffold(
      appBarTitle: 'Split a bill',
      steps: _steps,
      step: 2,
      title: '${formatPaise(widget.amountPaise)} for ${widget.what}',
      hint: 'Check each share, then send the requests.',
      buttonLabel: 'Ask for ${formatPaise(others)}',
      busy: _busy,
      onNext: _send,
      children: [
        SegmentedButton<bool>(
          segments: const [ButtonSegment(value: false, label: Text('Equally')), ButtonSegment(value: true, label: Text('By shares'))],
          selected: {_byShares},
          onSelectionChanged: (v) => setState(() => _byShares = v.first),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('I had some too'),
          subtitle: const Text('Keep a share for yourself'),
          value: _includeMe,
          onChanged: (v) => setState(() => _includeMe = v),
        ),
        const SectionTitle('Each person'),
        for (final id in _ids)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SurfaceCard(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Avatar(nameOf(id), size: 36),
                  const SizedBox(width: 12),
                  Expanded(child: Text(nameOf(id), style: AppText.body(weight: FontWeight.w600))),
                  if (_byShares) ...[
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: (_weights[id] ?? 1) > 1 ? () => setState(() => _weights[id] = (_weights[id] ?? 1) - 1) : null,
                    ),
                    Text('${_weights[id] ?? 1}×', style: AppText.body(weight: FontWeight.w600)),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.add_circle_outline),
                      onPressed: () => setState(() => _weights[id] = (_weights[id] ?? 1) + 1),
                    ),
                  ],
                  Text(formatPaise(parts[id] ?? 0), style: AppText.body(weight: FontWeight.w700)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
