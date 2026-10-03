import 'package:flutter/material.dart';

import '../../api.dart';
import '../../dates.dart';
import '../../models.dart';
import '../../money.dart';
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/section_title.dart';
import '../assistant/assistant.dart';
import '../pay/payee.dart';

/// Plan a trip: name, dates, place, people, deposit per person, pay-by
/// date and an optional food budget.
class NewTripScreen extends StatefulWidget {
  const NewTripScreen({super.key});

  @override
  State<NewTripScreen> createState() => _NewTripScreenState();
}

class _NewTripScreenState extends State<NewTripScreen> {
  final _name = TextEditingController();
  final _place = TextEditingController();
  final _deposit = TextEditingController();
  final _food = TextEditingController();
  DateTime? _start;
  DateTime? _end;
  DateTime? _payBy;
  final Set<String> _people = {};
  late final Future<List<User>> _contacts = _loadContacts();
  final _key = newIdempotencyKey();
  bool _busy = false;

  Future<List<User>> _loadContacts() async => contactsFrom(await api.trips(), api.userId);

  @override
  void dispose() {
    for (final c in [_name, _place, _deposit, _food]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _valid =>
      _name.text.trim().isNotEmpty &&
      _start != null &&
      _end != null &&
      !_end!.isBefore(_start!) &&
      (_deposit.text.isEmpty || parseToPaise(_deposit.text) != null) &&
      (_food.text.isEmpty || parseToPaise(_food.text) != null);

  Future<DateTime?> _pick(DateTime? initial) => showDatePicker(
        context: context,
        initialDate: initial ?? DateTime.now(),
        firstDate: DateTime(2024),
        lastDate: DateTime(2030),
      );

  Future<void> _create() async {
    setState(() => _busy = true);
    final deposit = parseToPaise(_deposit.text) ?? 0;
    final food = parseToPaise(_food.text);
    try {
      final trip = await api.createTrip({
        'name': _name.text.trim(),
        'place': _place.text.trim(),
        'start': toIsoIst(_start!),
        'end': toIsoIst(_end!),
        'members': _people.toList(),
        'deposit_target_paise': deposit,
        if (food != null) 'budgets_paise': {'food': food},
      }, key: _key);
      if (!mounted) return;
      if (deposit > 0 && _payBy != null && _people.isNotEmpty) {
        // Hand over to the assistant with the instruction filled in. It only
        // drafts; nothing is sent until the organiser confirms.
        Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => AssistantScreen(
            trip: trip,
            initialInstruction: 'Collect ${formatPaise(deposit)} from everyone by ${formatDay(_payBy!)}',
          ),
        ));
      } else {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Plan a trip')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Trip name', hintText: 'Coorg weekend'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(controller: _place, decoration: const InputDecoration(labelText: 'Place')),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _dateButton('From', _start, () async {
                final d = await _pick(_start);
                if (d != null) setState(() => _start = d);
              })),
              const SizedBox(width: 8),
              Expanded(child: _dateButton('To', _end, () async {
                final d = await _pick(_end ?? _start);
                if (d != null) setState(() => _end = d);
              })),
            ],
          ),
          if (_start != null && _end != null && _end!.isBefore(_start!))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('The trip has to end on or after it starts', style: AppText.detail(color: AppColors.error)),
            ),
          const SectionTitle('People'),
          FutureBuilder<List<User>>(
            future: _contacts,
            builder: (context, snap) {
              if (!snap.hasData) return const LinearProgressIndicator();
              return Wrap(
                spacing: 8,
                children: [
                  for (final u in snap.data!)
                    FilterChip(
                      label: Text(u.name),
                      selected: _people.contains(u.id),
                      onSelected: (on) => setState(() => on ? _people.add(u.id) : _people.remove(u.id)),
                    ),
                ],
              );
            },
          ),
          const SectionTitle('Deposit'),
          TextField(
            controller: _deposit,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Each person puts in', prefixText: '₹ '),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          _dateButton('Pay by', _payBy, () async {
            final d = await _pick(_payBy);
            if (d != null) setState(() => _payBy = d);
          }),
          const SectionTitle('Food budget (optional)'),
          TextField(
            controller: _food,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Food for the whole trip', prefixText: '₹ '),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: _busy || !_valid ? null : _create, child: const Text('Create trip')),
        ],
      ),
    );
  }

  Widget _dateButton(String label, DateTime? value, VoidCallback onTap) => OutlinedButton.icon(
        icon: const Icon(Icons.event_outlined),
        label: Text(value == null ? label : '$label ${formatWeekday(value)}'),
        onPressed: onTap,
      );
}
