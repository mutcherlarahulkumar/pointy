import 'package:flutter/material.dart';

import '../../api.dart';
import '../../models.dart';
import '../../widgets/async_view.dart';
import '../../widgets/flow_scaffold.dart';
import '../../widgets/person_picker.dart';

/// The organiser adds more friends to an open trip.
class AddPeopleScreen extends StatefulWidget {
  const AddPeopleScreen({super.key, required this.trip});

  final Trip trip;

  @override
  State<AddPeopleScreen> createState() => _AddPeopleScreenState();
}

class _AddPeopleScreenState extends State<AddPeopleScreen> {
  List<Person> _people = [];
  bool _busy = false;

  Future<void> _add() async {
    setState(() => _busy = true);
    try {
      await api.addMembers(widget.trip.id, [for (final p in _people) p.id]);
      if (!mounted) return;
      showMessage(context, 'Added ${_people.length} to ${widget.trip.name}');
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FlowScaffold(
      appBarTitle: widget.trip.name,
      title: 'Add people',
      hint: 'Type a mobile number and tap Add.',
      subtitle: 'They see the trip on their phone straight away.',
      buttonLabel: _people.isEmpty ? 'Choose people' : 'Add ${_people.length}',
      busy: _busy,
      onNext: _people.isEmpty ? null : _add,
      children: [
        PersonPicker(multi: true, exclude: widget.trip.members.toSet(), onPicked: (p) => setState(() => _people = p)),
      ],
    );
  }
}
