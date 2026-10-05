import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'avatar.dart';
import 'section_title.dart';

/// Find people on Pointy: type their mobile number, or pick someone you have
/// paid or travelled with. In single mode tapping a person returns them; in
/// multi mode people are ticked and returned together.
class PersonPicker extends StatefulWidget {
  const PersonPicker({
    super.key,
    required this.onPicked,
    this.multi = false,
    this.selected = const [],
    this.exclude = const {},
    this.onScan,
  });

  final ValueChanged<List<Person>> onPicked;
  final bool multi;
  final List<Person> selected;

  /// Ids not to offer (yourself, people already on a trip).
  final Set<String> exclude;

  /// Shows a "Scan QR" button when set.
  final VoidCallback? onScan;

  @override
  State<PersonPicker> createState() => _PersonPickerState();
}

class _PersonPickerState extends State<PersonPicker> {
  final _phone = TextEditingController();
  late final Future<List<Person>> _contacts = api.contacts();
  late final List<Person> _picked = [...widget.selected];
  Person? _found;
  String? _lookupError;
  bool _looking = false;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  // Looks the number up as soon as all ten digits are in.
  Future<void> _onPhoneChanged(String v) async {
    setState(() {
      _found = null;
      _lookupError = null;
    });
    if (v.length != 10) return;
    setState(() => _looking = true);
    try {
      final p = await api.lookupPhone(v);
      if (!mounted || _phone.text != v) return;
      setState(() {
        if (p.id == api.userId) {
          _lookupError = 'That is your own number';
        } else if (widget.exclude.contains(p.id)) {
          _lookupError = '${p.name} is already added';
        } else {
          _found = p;
        }
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _lookupError = e.toString());
    } finally {
      if (mounted) setState(() => _looking = false);
    }
  }

  void _tap(Person p) {
    if (!widget.multi) {
      widget.onPicked([p]);
      return;
    }
    setState(() => _picked.contains(p) ? _picked.remove(p) : _picked.add(p));
    widget.onPicked(List.of(_picked));
  }

  Widget _tile(Person p) {
    final on = _picked.contains(p);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Avatar(p.name),
      title: Text(p.name, style: AppText.body(weight: FontWeight.w600)),
      subtitle: Text('+91 ${formatPhone(p.phone)}', style: AppText.detail()),
      trailing: widget.multi
          ? Icon(on ? Icons.check_circle : Icons.add_circle_outline, color: on ? AppColors.pine700 : AppColors.slate)
          : const Icon(Icons.chevron_right),
      onTap: () => _tap(p),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)],
          decoration: InputDecoration(
            labelText: 'Mobile number',
            prefixText: '+91  ',
            suffixIcon: _looking
                ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                : const Icon(Icons.search),
          ),
          onChanged: _onPhoneChanged,
        ),
        if (_lookupError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_lookupError!, style: AppText.detail(color: AppColors.error)),
          ),
        if (_found != null) ...[const SizedBox(height: 8), SurfaceCard(padding: const EdgeInsets.symmetric(horizontal: 12), child: _tile(_found!))],
        if (widget.onScan != null) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(onPressed: widget.onScan, icon: const Icon(Icons.qr_code_scanner), label: const Text('Scan their Pointy QR')),
        ],
        if (widget.multi && _picked.isNotEmpty) ...[
          const SectionTitle('Added'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in _picked)
                InputChip(
                  avatar: Avatar(p.name, size: 24),
                  label: Text(firstName(p.name)),
                  onDeleted: () => _tap(p),
                ),
            ],
          ),
        ],
        FutureBuilder<List<Person>>(
          future: _contacts,
          builder: (context, snap) {
            final people = (snap.data ?? const <Person>[]).where((p) => !widget.exclude.contains(p.id)).toList();
            if (people.isEmpty) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [const SectionTitle('Recent'), for (final p in people) _tile(p)],
            );
          },
        ),
      ],
    );
  }
}
