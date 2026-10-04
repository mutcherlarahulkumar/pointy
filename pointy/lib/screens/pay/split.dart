import 'package:flutter/material.dart';

import '../../money.dart';
import '../../theme.dart';
import '../../widgets/section_title.dart';
import 'pay_draft.dart';
import 'review.dart';
import 'step_scaffold.dart';

/// Step 4 (trip wallet only): who shares the payment and how.
class SplitScreen extends StatefulWidget {
  const SplitScreen({super.key, required this.draft});

  final PayDraft draft;

  @override
  State<SplitScreen> createState() => _SplitScreenState();
}

class _SplitScreenState extends State<SplitScreen> {
  final Map<String, TextEditingController> _exact = {};

  @override
  void dispose() {
    for (final c in _exact.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _exactFor(String id) => _exact.putIfAbsent(id, () {
        final v = widget.draft.exactPaise[id];
        return TextEditingController(text: v == null || v == 0 ? '' : paiseToInput(v));
      });

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    final trip = d.trip!;
    final shares = d.shares();
    final exactSum = d.orderedParticipants.fold<int>(0, (a, id) => a + (d.exactPaise[id] ?? 0));

    return StepScaffold(
      step: 3,
      title: 'How do you split it?',
      buttonLabel: 'Next',
      onNext: shares == null
          ? null
          : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReviewScreen(draft: d))),
      children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'equal', label: Text('Equally')),
            ButtonSegment(value: 'shares', label: Text('By shares')),
            ButtonSegment(value: 'exact', label: Text('Exact')),
          ],
          selected: {d.splitMethod},
          onSelectionChanged: (v) => setState(() => d.splitMethod = v.first),
        ),
        const SizedBox(height: 8),
        Text('${formatPaise(d.amountPaise)} for ${d.description}', style: AppText.detail()),
        const SectionTitle('Who shares it'),
        for (final m in trip.memberDetails) _row(m.user.id, m.user.name, m.leftPaise, shares?[m.user.id]),
        if (d.splitMethod == 'exact')
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              exactSum == d.amountPaise
                  ? 'Adds up to ${formatPaise(d.amountPaise)}'
                  : '${formatPaise(exactSum)} of ${formatPaise(d.amountPaise)} so far',
              style: AppText.detail(color: exactSum == d.amountPaise ? AppColors.pine700 : AppColors.pending),
            ),
          ),
      ],
    );
  }

  Widget _row(String id, String name, int leftPaise, int? part) {
    final d = widget.draft;
    final on = d.participants.contains(id);
    final after = leftPaise - (part ?? 0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SurfaceCard(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            Checkbox(
              value: on,
              onChanged: (v) => setState(() => v == true ? d.participants.add(id) : d.participants.remove(id)),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: AppText.body(weight: FontWeight.w600)),
                  Text(
                    on && part != null ? 'Share left after this: ${formatPaise(after)}' : 'Share left: ${formatPaise(leftPaise)}',
                    style: AppText.detail(color: after < 0 ? AppColors.error : AppColors.slate),
                  ),
                ],
              ),
            ),
            if (on && d.splitMethod == 'shares') _weightStepper(id),
            if (on && d.splitMethod == 'exact')
              SizedBox(
                width: 96,
                child: TextField(
                  controller: _exactFor(id),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(prefixText: '₹', isDense: true),
                  onChanged: (t) => setState(() => d.exactPaise[id] = parseToPaise(t) ?? 0),
                ),
              ),
            if (on && d.splitMethod != 'exact' && part != null)
              Padding(
                padding: const EdgeInsets.only(left: 8, right: 8),
                child: Text(formatPaise(part), style: AppText.body(weight: FontWeight.w600)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _weightStepper(String id) {
    final d = widget.draft;
    final w = d.weights[id] ?? 1;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: w > 1 ? () => setState(() => d.weights[id] = w - 1) : null,
        ),
        Text('$w', style: AppText.body(weight: FontWeight.w600)),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add_circle_outline),
          onPressed: () => setState(() => d.weights[id] = w + 1),
        ),
      ],
    );
  }
}
