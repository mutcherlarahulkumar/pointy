import 'package:flutter/material.dart';

import '../../api.dart';
import '../../dates.dart';
import '../../money.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../widgets/amount_field.dart';
import '../../widgets/async_view.dart';
import '../../widgets/avatar.dart';
import '../../widgets/flow_scaffold.dart';
import '../../widgets/person_picker.dart';
import '../../widgets/section_title.dart';
import '../assistant/assistant.dart';
import 'trip_shell.dart';

const _steps = ['Trip', 'Dates', 'People', 'Money'];

/// Everything the trip planner collects across its four steps.
class _Plan {
  String name = '';
  String place = '';
  DateTimeRange? dates;
  List<Person> people = [];
  int depositPaise = 0;
  int? foodPaise;
}

/// Plan a trip, step 1: name and place.
class NewTripScreen extends StatefulWidget {
  const NewTripScreen({super.key});

  @override
  State<NewTripScreen> createState() => _NewTripScreenState();
}

class _NewTripScreenState extends State<NewTripScreen> {
  final _plan = _Plan();
  final _name = TextEditingController();
  final _place = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _place.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FlowScaffold(
      appBarTitle: 'Plan a trip',
      steps: _steps,
      step: 0,
      title: 'Where are you going?',
      hint: 'Give the trip a name and the place.',
      buttonLabel: 'Continue',
      onNext: _name.text.trim().isEmpty
          ? null
          : () {
              _plan
                ..name = _name.text.trim()
                ..place = _place.text.trim();
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => _DatesStep(plan: _plan)));
            },
      children: [
        TextField(
          controller: _name,
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Trip name', hintText: 'Coorg weekend', counterText: ''),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _place,
          maxLength: 40,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Place', hintText: 'Coorg, Karnataka', counterText: '', prefixIcon: Icon(Icons.place_outlined)),
        ),
      ],
    );
  }
}

class _DatesStep extends StatefulWidget {
  const _DatesStep({required this.plan});

  final _Plan plan;

  @override
  State<_DatesStep> createState() => _DatesStepState();
}

class _DatesStepState extends State<_DatesStep> {
  Future<void> _pick() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day).subtract(const Duration(days: 30)),
      lastDate: DateTime(now.year + 2),
      initialDateRange: widget.plan.dates,
      helpText: 'Trip dates',
    );
    if (r != null) setState(() => widget.plan.dates = r);
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.plan.dates;
    return FlowScaffold(
      appBarTitle: 'Plan a trip',
      steps: _steps,
      step: 1,
      title: 'When is it?',
      hint: 'Pick the first and the last day of the trip.',
      buttonLabel: 'Continue',
      onNext: d == null ? null : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _PeopleStep(plan: widget.plan))),
      children: [
        Material(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: _pick,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Icon(Icons.date_range_rounded, color: AppColors.pine700, size: 32),
                  const SizedBox(width: 16),
                  Expanded(
                    child: d == null
                        ? Text('Choose the dates', style: AppText.heading(color: AppColors.pine700))
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${formatWeekday(d.start)} – ${formatWeekday(d.end)}', style: AppText.heading()),
                              Text('${d.duration.inDays + 1} days', style: AppText.detail()),
                            ],
                          ),
                  ),
                  const Icon(Icons.edit_calendar_outlined, color: AppColors.slate),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PeopleStep extends StatefulWidget {
  const _PeopleStep({required this.plan});

  final _Plan plan;

  @override
  State<_PeopleStep> createState() => _PeopleStepState();
}

class _PeopleStepState extends State<_PeopleStep> {
  @override
  Widget build(BuildContext context) {
    final n = widget.plan.people.length;
    return FlowScaffold(
      appBarTitle: 'Plan a trip',
      steps: _steps,
      step: 2,
      title: 'Who is coming?',
      hint: 'Type a friend\'s mobile number and tap Add.',
      subtitle: 'Add friends by their mobile number. They need Pointy installed.',
      buttonLabel: n == 0 ? 'Just me for now' : 'Continue with ${n + 1} people',
      onNext: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _MoneyStep(plan: widget.plan))),
      children: [PersonPicker(multi: true, selected: widget.plan.people, onPicked: (p) => setState(() => widget.plan.people = p))],
    );
  }
}

class _MoneyStep extends StatefulWidget {
  const _MoneyStep({required this.plan});

  final _Plan plan;

  @override
  State<_MoneyStep> createState() => _MoneyStepState();
}

class _MoneyStepState extends State<_MoneyStep> {
  final _deposit = TextEditingController();
  final _food = TextEditingController();
  final _key = SubmitKey();
  bool _busy = false;

  @override
  void dispose() {
    _deposit.dispose();
    _food.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final p = widget.plan;
    p.depositPaise = parseToPaise(_deposit.text) ?? 0;
    p.foodPaise = parseToPaise(_food.text);
    setState(() => _busy = true);
    try {
      final body = {
        'name': p.name,
        'place': p.place,
        'start': toIsoIst(p.dates!.start),
        'end': toIsoIst(p.dates!.end),
        'members': [for (final x in p.people) x.id],
        'deposit_target_paise': p.depositPaise,
        if (p.foodPaise != null) 'budgets_paise': {'food': p.foodPaise},
      };
      final trip = await api.createTrip(body, key: _key.forRequest(body));
      if (!mounted) return;
      final nav = Navigator.of(context)..popUntil((r) => r.isFirst);
      nav.push(tripRoute(trip.id));
      // With a deposit set, hand over to the assistant to ask everyone.
      if (p.depositPaise > 0 && p.people.isNotEmpty) {
        nav.push(MaterialPageRoute(
          builder: (_) => AssistantScreen(trip: trip, initialInstruction: 'Collect ${formatPaise(p.depositPaise)} from everyone'),
        ));
      }
    } catch (e) {
      _key.failed(e);
      if (!mounted) return;
      setState(() => _busy = false);
      showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.plan;
    final depositOk = _deposit.text.isEmpty || parseToPaise(_deposit.text) != null;
    final foodOk = _food.text.isEmpty || parseToPaise(_food.text) != null;
    return FlowScaffold(
      appBarTitle: 'Plan a trip',
      steps: _steps,
      step: 3,
      title: 'How much does each person put in?',
      hint: 'Set the deposit per person. The food budget is optional.',
      subtitle: 'Everyone adds this to the trip wallet. You can change plans later.',
      buttonLabel: 'Create ${p.name}',
      busy: _busy,
      onNext: depositOk && foodOk ? _create : null,
      children: [
        AmountField(controller: _deposit, onChanged: () => setState(() {}), chipsRupees: const [1000, 2000, 5000], hint: 'per person'),
        const SectionTitle('Food budget (optional)'),
        TextField(
          controller: _food,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'For the whole trip', prefixText: '₹ ', helperText: 'Pointy warns before food spending crosses 80%'),
          onChanged: (_) => setState(() {}),
        ),
        const SectionTitle('Summary'),
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${p.name}${p.place.isEmpty ? '' : ' · ${p.place}'}', style: AppText.body(weight: FontWeight.w700)),
              Text('${formatWeekday(p.dates!.start)} – ${formatWeekday(p.dates!.end)}', style: AppText.detail()),
              const SizedBox(height: 10),
              Wrap(
                spacing: -8,
                children: [Avatar('You', size: 32), for (final x in p.people) Avatar(x.name, size: 32)],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
