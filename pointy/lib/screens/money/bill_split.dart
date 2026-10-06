import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../api.dart';
import '../../models.dart';
import '../../money.dart';
import '../../theme.dart';
import '../../widgets/ai_mark.dart';
import '../../widgets/async_view.dart';
import '../../widgets/avatar.dart';
import '../../widgets/flow_scaffold.dart';
import '../../widgets/person_picker.dart';
import '../../widgets/section_title.dart';
import '../../widgets/success.dart';

const _steps = ['Bill', 'People', 'Who had what'];

/// One line of the bill being split, and who had it.
class _Item {
  _Item(this.name, this.amountPaise);
  String name;
  int amountPaise;
  final Set<String> people = {};
}

class _Draft {
  String what = '';
  final items = <_Item>[];
  int extraPaise = 0; // tax, service, tip; negative for a discount
  List<Person> people = [];

  int get subtotal => items.fold(0, (a, i) => a + i.amountPaise);
  int get total => subtotal + extraPaise;
}

/// Split a bill by who had what, step 1: the bill. Scan it and the AI reads
/// every line and the taxes, or type the items yourself.
class BillSplitScreen extends StatefulWidget {
  const BillSplitScreen({super.key});

  @override
  State<BillSplitScreen> createState() => _BillSplitScreenState();
}

class _BillSplitScreenState extends State<BillSplitScreen> {
  final _d = _Draft();
  final _what = TextEditingController();
  late final _extra = TextEditingController();
  bool _scanning = false;
  bool? _matched; // after a scan: did the lines add up to the total?

  @override
  void dispose() {
    _what.dispose();
    _extra.dispose();
    super.dispose();
  }

  Future<void> _scan(ImageSource source) async {
    Navigator.of(context).pop();
    final XFile? photo;
    try {
      photo = await ImagePicker().pickImage(source: source, maxWidth: 1600, imageQuality: 80);
    } catch (_) {
      if (mounted) showError(context, 'Could not open the ${source == ImageSource.camera ? 'camera' : 'gallery'}');
      return;
    }
    if (photo == null) return;
    setState(() => _scanning = true);
    try {
      final r = await api.scanReceipt(await photo.readAsBytes());
      if (!mounted) return;
      setState(() {
        _what.text = r.description;
        _d.items
          ..clear()
          ..addAll([for (final l in r.items) _Item(l.quantity > 1 ? '${l.name} ×${l.quantity}' : l.name, l.amountPaise)]);
        final extra = r.charges.fold<int>(0, (a, c) => a + c.amountPaise);
        // If the lines did not add up, put the difference in the extras so
        // the total is right; the person sees a note to check.
        final gap = r.amountPaise - _d.subtotal - extra;
        _d.extraPaise = r.itemsMatch ? extra : extra + gap;
        _extra.text = _d.extraPaise == 0 ? '' : paiseToInput(_d.extraPaise);
        _matched = r.itemsMatch;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  void _chooseSource() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.photo_camera_outlined), title: const Text('Take a photo'), onTap: () => _scan(ImageSource.camera)),
          ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('Choose from gallery'), onTap: () => _scan(ImageSource.gallery)),
        ]),
      ),
    );
  }

  Future<void> _editItem([_Item? item]) async {
    final r = await showDialog<_ItemEdit>(context: context, builder: (_) => _ItemDialog(item: item));
    if (r == null) return;
    setState(() {
      if (r.remove) {
        _d.items.remove(item);
      } else if (item == null) {
        _d.items.add(_Item(r.name, r.paise));
      } else {
        item
          ..name = r.name
          ..amountPaise = r.paise;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final extra = _extra.text.trim().isEmpty ? 0 : parseSignedPaise(_extra.text);
    if (extra != null) _d.extraPaise = extra;
    final ok = _d.items.isNotEmpty && extra != null && _d.total > 0;
    return FlowScaffold(
      appBarTitle: 'Split by items',
      steps: _steps,
      step: 0,
      title: 'What was on the bill?',
      subtitle: 'Scan it and the AI reads every line, or add the items yourself.',
      buttonLabel: ok ? 'Continue · ${formatPaise(_d.total)}' : 'Add the items',
      onNext: ok
          ? () {
              _d.what = _what.text.trim().isEmpty ? 'the bill' : _what.text.trim();
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => _PeopleScreen(d: _d)));
            }
          : null,
      children: [
        Material(
          color: AppColors.amber100,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: _scanning ? null : _chooseSource,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                const AiMark(size: 26),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(_scanning ? 'Reading the bill…' : 'Scan the bill with AI',
                      style: AppText.body(weight: FontWeight.w700, color: AppColors.amber900)),
                ),
                if (_scanning) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) else const Icon(Icons.photo_camera_outlined, color: AppColors.amber900),
              ]),
            ),
          ),
        ),
        if (_matched == false) ...[
          const SizedBox(height: 8),
          Text('The lines did not add up to the total, so the difference is in the extras. Check them.', style: AppText.detail(color: AppColors.pending)),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: _what,
          maxLength: 40,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'What was it?', hintText: 'Dinner at Britto\'s', counterText: ''),
        ),
        SectionTitle('Items', action: 'Add', onAction: () => _editItem()),
        if (_d.items.isEmpty)
          Text('No items yet.', style: AppText.detail())
        else
          SurfaceCard(
            padding: EdgeInsets.zero,
            child: Column(children: [
              for (var i = 0; i < _d.items.length; i++) ...[
                if (i > 0) const Divider(indent: 16),
                ListTile(
                  dense: true,
                  title: Text(_d.items[i].name, style: AppText.body()),
                  trailing: Text(formatPaise(_d.items[i].amountPaise), style: AppText.body(weight: FontWeight.w600)),
                  onTap: () => _editItem(_d.items[i]),
                ),
              ],
            ]),
          ),
        const SizedBox(height: 12),
        TextField(
          controller: _extra,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Tax, service and tip',
            prefixText: '₹ ',
            helperText: extra == null ? 'Type an amount, or -50 for a discount' : 'Shared by what each person had',
          ),
        ),
      ],
    );
  }
}

/// Like parseToPaise, but a leading minus is a discount.
int? parseSignedPaise(String text) {
  final t = text.trim();
  final neg = t.startsWith('-');
  final v = parseToPaise(neg ? t.substring(1) : t);
  if (v == null) return null;
  return neg ? -v : v;
}

/// Step 2: who was there. You are always in.
class _PeopleScreen extends StatefulWidget {
  const _PeopleScreen({required this.d});
  final _Draft d;

  @override
  State<_PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<_PeopleScreen> {
  @override
  Widget build(BuildContext context) {
    final d = widget.d;
    return FlowScaffold(
      appBarTitle: 'Split by items',
      steps: _steps,
      step: 1,
      title: 'Who was there?',
      subtitle: 'You are in already. Add everyone who shared the bill.',
      buttonLabel: d.people.isEmpty ? 'Add at least one person' : 'Continue with ${d.people.length + 1} people',
      onNext: d.people.isEmpty ? null : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _AssignScreen(d: d))),
      children: [PersonPicker(multi: true, selected: d.people, onPicked: (p) => setState(() => d.people = p))],
    );
  }
}

/// Step 3: tap who had each item; everyone's total updates as you go.
class _AssignScreen extends StatefulWidget {
  const _AssignScreen({required this.d});
  final _Draft d;

  @override
  State<_AssignScreen> createState() => _AssignScreenState();
}

class _AssignScreenState extends State<_AssignScreen> {
  final _key = SubmitKey();
  bool _busy = false;

  List<Person> get _everyone => [Person(id: api.userId, name: 'You', phone: ''), ...widget.d.people];

  @override
  void initState() {
    super.initState();
    // Back on step 2 someone may have been taken off the list: their items
    // are no longer theirs (they would still be asked to pay otherwise).
    final ids = _everyone.map((p) => p.id).toSet();
    for (final it in widget.d.items) {
      it.people.retainAll(ids);
    }
  }

  // A preview of each person's part, with the same rules as the server:
  // items split equally between who had them, extras by each subtotal.
  Map<String, int> _preview() {
    final d = widget.d;
    final sub = <String, int>{};
    for (final it in d.items) {
      if (it.people.isEmpty) continue;
      final ids = _everyone.map((p) => p.id).where(it.people.contains).toList();
      final parts = splitPaise(it.amountPaise, [for (final _ in ids) 1]);
      for (var i = 0; i < ids.length; i++) {
        sub[ids[i]] = (sub[ids[i]] ?? 0) + parts[i];
      }
    }
    final total = sub.values.fold(0, (a, b) => a + b);
    if (total == 0 || d.extraPaise == 0) return sub;
    final ids = sub.keys.where((k) => sub[k]! > 0).toList();
    final ex = splitPaise(d.extraPaise.abs(), [for (final id in ids) sub[id]!]);
    return {for (var i = 0; i < ids.length; i++) ids[i]: sub[ids[i]]! + (d.extraPaise < 0 ? -ex[i] : ex[i])};
  }

  Future<void> _send() async {
    setState(() => _busy = true);
    try {
      final items = [for (final it in widget.d.items) {'name': it.name, 'amount_paise': it.amountPaise, 'people': it.people.toList()}];
      final parts = await api.splitByItems(widget.d.what, items, widget.d.extraPaise,
          key: _key.forRequest([widget.d.what, items, widget.d.extraPaise]));
      if (!mounted) return;
      final nav = Navigator.of(context)..popUntil((r) => r.isFirst);
      final asked = parts.where((p) => p.user.id != api.userId);
      nav.push(MaterialPageRoute(
        builder: (_) => SuccessScreen(
          pending: true,
          title: 'Sent ${asked.length} request${asked.length == 1 ? '' : 's'}',
          amount: formatPaise(asked.fold(0, (a, p) => a + p.totalPaise)),
          subtitle: 'for ${widget.d.what}, by what each person had',
          rows: [for (final p in parts) (p.user.id == api.userId ? 'You' : p.user.name, formatPaise(p.totalPaise))],
        ),
      ));
    } catch (e) {
      _key.failed(e);
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.d;
    final everyone = _everyone;
    final unassigned = d.items.where((i) => i.people.isEmpty).length;
    final preview = _preview();
    return FlowScaffold(
      appBarTitle: 'Split by items',
      steps: _steps,
      step: 2,
      title: 'Who had what?',
      subtitle: 'Tap the people for each item. Shared dishes: tap everyone who had some.',
      buttonLabel: unassigned > 0 ? '$unassigned item${unassigned == 1 ? '' : 's'} left to share' : 'Send requests',
      busy: _busy,
      onNext: unassigned > 0 ? null : _send,
      children: [
        for (final it in d.items)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(child: Text(it.name, style: AppText.body(weight: FontWeight.w600))),
                    Text(formatPaise(it.amountPaise), style: AppText.body(weight: FontWeight.w700)),
                  ]),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final p in everyone)
                      FilterChip(
                        avatar: Avatar(p.name, size: 22),
                        label: Text(firstName(p.name)),
                        selected: it.people.contains(p.id),
                        showCheckmark: false,
                        onSelected: (on) => setState(() => on ? it.people.add(p.id) : it.people.remove(p.id)),
                      ),
                    ActionChip(
                      label: const Text('Everyone'),
                      onPressed: () => setState(() => it.people.addAll(everyone.map((p) => p.id))),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        const SectionTitle('Each person pays'),
        SurfaceCard(
          child: Column(children: [
            for (final p in everyone)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  Avatar(p.name, size: 28),
                  const SizedBox(width: 10),
                  Expanded(child: Text(p.name, style: AppText.body())),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Text(formatPaise(preview[p.id] ?? 0), key: ValueKey(preview[p.id]), style: AppText.body(weight: FontWeight.w700)),
                  ),
                ]),
              ),
            const Divider(),
            Row(children: [
              Expanded(child: Text('Bill', style: AppText.detail())),
              Text(formatPaise(d.total), style: AppText.body(weight: FontWeight.w700)),
            ]),
          ]),
        ),
      ],
    );
  }
}

class _ItemEdit {
  _ItemEdit(this.name, this.paise, {this.remove = false});
  final String name;
  final int paise;
  final bool remove;
}

/// Add or edit one item. It owns its text fields, so they live exactly as
/// long as the dialog (including its closing animation).
class _ItemDialog extends StatefulWidget {
  const _ItemDialog({this.item});
  final _Item? item;

  @override
  State<_ItemDialog> createState() => _ItemDialogState();
}

class _ItemDialogState extends State<_ItemDialog> {
  late final _name = TextEditingController(text: widget.item?.name ?? '');
  late final _price = TextEditingController(text: widget.item == null ? '' : paiseToInput(widget.item!.amountPaise));

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = parseToPaise(_price.text);
    final ok = _name.text.trim().isNotEmpty && p != null && p > 0;
    return AlertDialog(
      title: Text(widget.item == null ? 'Add an item' : 'Edit item'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
          controller: _name,
          autofocus: true,
          maxLength: 40,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(labelText: 'Item', hintText: 'Paneer tikka', counterText: ''),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _price,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(labelText: 'Price', prefixText: '₹ '),
        ),
      ]),
      actions: [
        if (widget.item != null)
          TextButton(
            onPressed: () => Navigator.pop(context, _ItemEdit('', 0, remove: true)),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Remove'),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: ok ? () => Navigator.pop(context, _ItemEdit(_name.text.trim(), p)) : null, child: const Text('Save')),
      ],
    );
  }
}
