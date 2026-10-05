import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../api.dart';
import '../../payment_lock.dart';
import '../../location.dart';
import '../../money.dart';
import '../../models.dart';
import '../../prefs.dart';
import '../../theme.dart';
import '../../widgets/ai_card.dart';
import '../../widgets/ai_mark.dart';
import '../../widgets/amount_field.dart';
import '../../widgets/async_view.dart';
import '../../widgets/avatar.dart';
import '../../widgets/flow_scaffold.dart';
import '../../widgets/section_title.dart';
import '../../widgets/success.dart';
import '../../widgets/tag.dart';
import '../../widgets/tile_icon.dart';

const _steps = ['Amount', 'Who paid', 'Split', 'Review'];

/// Everything chosen so far in "Add an expense".
class _Draft {
  _Draft(this.trip) {
    participants.addAll(trip.members);
  }

  final Trip trip;
  int amountPaise = 0;
  String description = '';
  String category = 'other';
  String mode = 'reimburse'; // reimburse (I paid) or member (pay someone on the trip)
  String payee = ''; // shop name for the receipt
  String payeeUserId = '';
  String splitMethod = 'equal';
  final Set<String> participants = {};
  final Map<String, int> weights = {};
  final Map<String, int> exactPaise = {};

  List<String> get ordered => trip.members.where(participants.contains).toList();

  /// Each person's part as the backend computes it, or null when exact
  /// amounts do not add up yet.
  Map<String, int>? shares() {
    final ids = ordered;
    if (ids.isEmpty || amountPaise <= 0) return null;
    if (splitMethod == 'exact') {
      final parts = {for (final id in ids) id: exactPaise[id] ?? 0};
      return parts.values.fold<int>(0, (a, b) => a + b) == amountPaise ? parts : null;
    }
    final parts = splitPaise(amountPaise, [for (final id in ids) splitMethod == 'shares' ? (weights[id] ?? 1) : 1]);
    return {for (var i = 0; i < ids.length; i++) ids[i]: parts[i]};
  }

  Map<String, dynamic> toJson({bool confirmOverBudget = false, double? lat, double? lng}) => {
        'description': description,
        'category': category,
        'amount_paise': amountPaise,
        'mode': mode,
        'payee': payee,
        if (mode == 'member') 'payee_user_id': payeeUserId,
        'split_method': splitMethod,
        'participants': [
          for (final id in ordered)
            {
              'user_id': id,
              if (splitMethod == 'shares') 'weight': weights[id] ?? 1,
              if (splitMethod == 'exact') 'exact_paise': exactPaise[id] ?? 0,
            }
        ],
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
        if (confirmOverBudget) 'confirm_over_budget': true,
      };
}

/// Suggests a category from words in the description, with the reason.
(String, String)? guessCategory(String text) {
  final t = text.toLowerCase();
  const words = {
    'food': ['dinner', 'lunch', 'breakfast', 'food', 'chai', 'coffee', 'snack', 'restaurant', 'cafe', 'pizza', 'biryani', 'drinks', 'groceries', 'shack'],
    'transport': ['cab', 'taxi', 'uber', 'ola', 'auto', 'fuel', 'petrol', 'diesel', 'bus', 'train', 'flight', 'scooter', 'bike', 'toll', 'parking'],
    'stay': ['hotel', 'stay', 'villa', 'room', 'hostel', 'airbnb', 'homestay', 'resort', 'camp'],
  };
  for (final e in words.entries) {
    for (final w in e.value) {
      if (t.contains(w)) return (e.key, '"$w" in the description');
    }
  }
  return null;
}

/// Step 1: how much and what for.
class ExpenseAmountScreen extends StatefulWidget {
  const ExpenseAmountScreen({super.key, required this.trip});

  final Trip trip;

  @override
  State<ExpenseAmountScreen> createState() => _ExpenseAmountScreenState();
}

class _ExpenseAmountScreenState extends State<ExpenseAmountScreen> {
  late final _d = _Draft(widget.trip);
  final _amount = TextEditingController();
  final _what = TextEditingController();
  bool _picked = false; // the person chose a category themselves
  ScannedReceipt? _scanned;
  bool _scanning = false;

  // Takes or chooses a photo of the bill and fills the form from it. The
  // person still checks everything before paying.
  Future<void> _scan(ImageSource source) async {
    Navigator.of(context).pop(); // the camera / gallery sheet
    final XFile? photo;
    try {
      // A smaller photo uploads faster and is plenty for reading a bill.
      photo = await ImagePicker().pickImage(source: source, maxWidth: 1600, imageQuality: 80);
    } catch (e) {
      if (mounted) showError(context, 'Could not open the ${source == ImageSource.camera ? 'camera' : 'gallery'}');
      return;
    }
    if (photo == null) return;
    setState(() => _scanning = true);
    try {
      final r = await api.scanReceipt(await photo.readAsBytes());
      if (!mounted) return;
      setState(() {
        _scanned = r;
        _amount.text = paiseToInput(r.amountPaise);
        _what.text = r.description;
        _d.payee = r.merchant;
        if (categories.contains(r.category)) {
          _d.category = r.category;
          _picked = true;
        }
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: const Icon(Icons.photo_camera_outlined), title: const Text('Take a photo'), onTap: () => _scan(ImageSource.camera)),
            ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('Choose from gallery'), onTap: () => _scan(ImageSource.gallery)),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _amount.dispose();
    _what.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final paise = parseToPaise(_amount.text);
    final guess = AiPrefs.pastChoices || AiPrefs.time ? guessCategory(_what.text) : null;
    if (guess != null && !_picked) _d.category = guess.$1;
    return FlowScaffold(
      appBarTitle: widget.trip.name,
      steps: _steps,
      step: 0,
      title: 'What was it?',
      hint: 'Type the amount and what it was for, or scan the bill.',
      buttonLabel: 'Continue',
      onNext: paise == null || _what.text.trim().isEmpty
          ? null
          : () {
              _d
                ..amountPaise = paise
                ..description = _what.text.trim();
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => _WhoPaidScreen(d: _d)));
            },
      children: [
        AiButton(
          label: _scanning ? 'Reading the receipt…' : 'Scan a receipt with AI',
          busy: _scanning,
          onPressed: _chooseSource,
        ),
        if (_scanned != null) ...[
          const SizedBox(height: 10),
          AiCard(
            title: 'Filled in from your receipt',
            body: 'Check the amount before you continue.',
            reasons: [
              if (_scanned!.merchant.isNotEmpty) _scanned!.merchant,
              if (_scanned!.date.isNotEmpty) _scanned!.date,
              categoryLabel(_scanned!.category),
            ],
          ),
        ],
        const SizedBox(height: 8),
        AmountField(controller: _amount, onChanged: () => setState(() {}), autofocus: false),
        const SizedBox(height: 16),
        TextField(
          controller: _what,
          maxLength: 40,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Description', hintText: 'Dinner at the beach shack', counterText: ''),
          onChanged: (_) => setState(() {}),
        ),
        if (guess != null && !_picked && _scanned == null) ...[
          const SizedBox(height: 4),
          AiCard(title: 'Looks like ${categoryLabel(guess.$1)}', reasons: [guess.$2]),
        ],
        const SectionTitle('Category'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in categories)
              ChoiceChip(
                showCheckmark: false,
                avatar: Icon(categoryIcon(c), size: 18),
                label: Text(categoryLabel(c)),
                selected: _d.category == c,
                onSelected: (_) => setState(() {
                  _d.category = c;
                  _picked = true;
                }),
              ),
          ],
        ),
      ],
    );
  }
}

/// Step 2: who gets the money from the wallet.
class _WhoPaidScreen extends StatefulWidget {
  const _WhoPaidScreen({required this.d});

  final _Draft d;

  @override
  State<_WhoPaidScreen> createState() => _WhoPaidScreenState();
}

class _WhoPaidScreenState extends State<_WhoPaidScreen> {
  late final _shop = TextEditingController(text: widget.d.payee);

  @override
  void dispose() {
    _shop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.d;
    final others = d.trip.memberDetails.where((m) => m.user.id != api.userId).toList();
    final ok = d.mode == 'reimburse' || d.payeeUserId.isNotEmpty;
    return FlowScaffold(
      appBarTitle: d.trip.name,
      steps: _steps,
      step: 1,
      title: 'Who gets the money?',
      hint: 'Choose who receives the money from the trip wallet.',
      subtitle: '${formatPaise(d.amountPaise)} for ${d.description}',
      buttonLabel: 'Continue',
      onNext: ok
          ? () {
              d.payee = d.mode == 'reimburse' ? _shop.text.trim() : d.trip.nameOf(d.payeeUserId);
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => _SplitScreen(d: d)));
            }
          : null,
      children: [
        _option(
          on: d.mode == 'reimburse',
          icon: Icons.reply_rounded,
          title: 'I paid already, pay me back',
          body: 'You paid the shop by cash, UPI or card. The wallet pays you back.',
          onTap: () => setState(() => d.mode = 'reimburse'),
        ),
        if (d.mode == 'reimburse') ...[
          const SizedBox(height: 4),
          TextField(
            controller: _shop,
            maxLength: 40,
            decoration: const InputDecoration(labelText: 'Paid to (optional)', hintText: 'Beach shack, Baga', counterText: ''),
          ),
        ],
        const SizedBox(height: 8),
        _option(
          on: d.mode == 'member',
          icon: Icons.person_pin_circle_outlined,
          title: 'Pay someone on the trip',
          body: 'Someone else paid, or is owed. It lands in their Pointy balance.',
          onTap: others.isEmpty ? null : () => setState(() => d.mode = 'member'),
        ),
        if (d.mode == 'member')
          for (final m in others)
            ListTile(
              leading: Avatar(m.user.name, size: 36),
              title: Text(m.user.name),
              trailing: Icon(d.payeeUserId == m.user.id ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: d.payeeUserId == m.user.id ? AppColors.pine700 : AppColors.slate),
              onTap: () => setState(() => d.payeeUserId = m.user.id),
            ),
      ],
    );
  }

  Widget _option({required bool on, required IconData icon, required String title, required String body, VoidCallback? onTap}) {
    return Material(
      color: on ? AppColors.pine100 : AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: on ? AppColors.pine700 : AppColors.line, width: on ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              TileIcon(icon),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppText.body(weight: FontWeight.w700, color: onTap == null ? AppColors.slate : AppColors.ink)),
                    Text(onTap == null ? 'Add people to the trip first.' : body, style: AppText.detail()),
                  ],
                ),
              ),
              Icon(on ? Icons.radio_button_checked : Icons.radio_button_off, color: on ? AppColors.pine700 : AppColors.slate),
            ],
          ),
        ),
      ),
    );
  }
}

/// Step 3: who shares it, and how.
class _SplitScreen extends StatefulWidget {
  const _SplitScreen({required this.d});

  final _Draft d;

  @override
  State<_SplitScreen> createState() => _SplitScreenState();
}

class _SplitScreenState extends State<_SplitScreen> {
  final Map<String, TextEditingController> _exact = {};

  @override
  void dispose() {
    for (final c in _exact.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.d;
    final shares = d.shares();
    final exactSum = d.ordered.fold<int>(0, (a, id) => a + (d.exactPaise[id] ?? 0));
    return FlowScaffold(
      appBarTitle: d.trip.name,
      steps: _steps,
      step: 2,
      title: 'How do you split it?',
      hint: 'Choose how to share it, and tick who is in.',
      buttonLabel: 'Continue',
      onNext: shares == null ? null : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _ReviewScreen(d: d))),
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
        const SectionTitle('Who shares it'),
        for (final m in d.trip.memberDetails) _row(m, shares?[m.user.id]),
        if (d.splitMethod == 'exact')
          Text(
            exactSum == d.amountPaise ? 'Adds up to ${formatPaise(d.amountPaise)}' : '${formatPaise(exactSum)} of ${formatPaise(d.amountPaise)} so far',
            style: AppText.detail(color: exactSum == d.amountPaise ? AppColors.pine700 : AppColors.pending),
          ),
      ],
    );
  }

  Widget _row(MemberDetail m, int? part) {
    final d = widget.d;
    final id = m.user.id;
    final on = d.participants.contains(id);
    final after = m.leftPaise - (on ? (part ?? 0) : 0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SurfaceCard(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            Checkbox(value: on, onChanged: (v) => setState(() => v == true ? d.participants.add(id) : d.participants.remove(id))),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m.user.name, style: AppText.body(weight: FontWeight.w600)),
                  Text('Share left after: ${formatPaise(after)}', style: AppText.detail(color: after < 0 ? AppColors.error : AppColors.slate)),
                ],
              ),
            ),
            if (on && d.splitMethod == 'shares') ...[
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: (d.weights[id] ?? 1) > 1 ? () => setState(() => d.weights[id] = (d.weights[id] ?? 1) - 1) : null,
              ),
              Text('${d.weights[id] ?? 1}×'),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () => setState(() => d.weights[id] = (d.weights[id] ?? 1) + 1),
              ),
            ],
            if (on && d.splitMethod == 'exact')
              SizedBox(
                width: 96,
                child: TextField(
                  controller: _exact.putIfAbsent(id, () => TextEditingController()),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(prefixText: '₹', isDense: true),
                  onChanged: (t) => setState(() => d.exactPaise[id] = parseToPaise(t) ?? 0),
                ),
              )
            else if (on && part != null)
              Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text(formatPaise(part), style: AppText.body(weight: FontWeight.w700))),
          ],
        ),
      ),
    );
  }
}

/// Step 4: every choice on one screen, then pay from the wallet.
class _ReviewScreen extends StatefulWidget {
  const _ReviewScreen({required this.d});

  final _Draft d;

  @override
  State<_ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<_ReviewScreen> {
  String _key = newIdempotencyKey();
  bool _busy = false;

  Future<void> _pay({bool confirmOverBudget = false}) async {
    final d = widget.d;
    // Asked once: "Pay anyway" after a budget warning is the same payment.
    if (!confirmOverBudget && !await confirmPayment(context, 'Pay ${formatPaise(d.amountPaise)} from the ${d.trip.name} wallet')) return;
    setState(() => _busy = true);
    try {
      final loc = await coarseLocation();
      final e = await api.addExpense(d.trip.id, d.toJson(confirmOverBudget: confirmOverBudget, lat: loc?.lat, lng: loc?.lng), key: _key);
      if (!mounted) return;
      final nav = Navigator.of(context);
      // Back to the trip, with the receipt on top.
      nav.popUntil((r) => r.settings.name == 'trip' || r.isFirst);
      nav.push(MaterialPageRoute(
        builder: (_) => SuccessScreen(
          title: d.mode == 'reimburse' ? 'Paid back to you' : 'Paid to ${d.trip.nameOf(d.payeeUserId)}',
          amount: formatPaise(e.amountPaise),
          subtitle: '${e.description} · from the ${d.trip.name} wallet',
          rows: [
            ('Category', categoryLabel(e.category)),
            ('Split', e.isEvenSplit && e.shares.isNotEmpty ? '${e.shares.length} ways, ${formatPaise(e.shares.first.amountPaise)} each' : '${e.shares.length} people'),
            if (e.payee.isNotEmpty) ('Paid to', e.payee),
            ('Reference', e.id),
          ],
        ),
      ));
    } on ApiException catch (e) {
      _key = newIdempotencyKey(); // the server stored this answer under the old key
      if (!mounted) return;
      setState(() => _busy = false);
      if (e.code == 'budget_warning' && e.details != null) {
        final choice = await Navigator.of(context).push<_BudgetChoice>(MaterialPageRoute(
          builder: (_) => _BudgetCheckScreen(trip: d.trip, check: BudgetCheck.fromJson(e.details!)),
        ));
        if (choice == _BudgetChoice.payAnyway) await _pay(confirmOverBudget: true);
        if (choice == _BudgetChoice.raised) await _pay();
        return;
      }
      showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.d;
    final shares = d.shares() ?? const <String, int>{};
    final mine = shares[api.userId] ?? 0;
    return FlowScaffold(
      appBarTitle: d.trip.name,
      steps: _steps,
      step: 3,
      title: 'Check and pay',
      hint: 'Check everything. You confirm with your fingerprint or PIN.',
      buttonLabel: 'Pay ${formatPaise(d.amountPaise)} from the wallet',
      busy: _busy,
      onNext: _pay,
      children: [
        SurfaceCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              TileIcon(categoryIcon(d.category), size: 52),
              const SizedBox(height: 10),
              Text(formatPaise(d.amountPaise), style: AppText.balance()),
              Text(d.description, style: AppText.body(color: AppColors.slate)),
              const SizedBox(height: 8),
              Tag.wallet(true),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SurfaceCard(
          child: Column(
            children: [
              _row('Money goes to', d.mode == 'reimburse' ? 'You (paying you back)' : d.trip.nameOf(d.payeeUserId)),
              if (d.payee.isNotEmpty && d.mode == 'reimburse') _row('Paid to', d.payee),
              _row('Category', categoryLabel(d.category)),
              _row('Your part', formatPaise(mine)),
              _row('Wallet after', formatPaise(d.trip.balancePaise - d.amountPaise)),
            ],
          ),
        ),
        const SectionTitle('Each person'),
        SurfaceCard(
          child: Column(children: [for (final e in shares.entries) _row(d.trip.nameOf(e.key), formatPaise(e.value))]),
        ),
      ],
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(child: Text(label, style: AppText.detail())),
            Text(value, style: AppText.body(weight: FontWeight.w600)),
          ],
        ),
      );
}

enum _BudgetChoice { payAnyway, raised }

/// Shown only when the backend answers budget_warning.
class _BudgetCheckScreen extends StatefulWidget {
  const _BudgetCheckScreen({required this.trip, required this.check});

  final Trip trip;
  final BudgetCheck check;

  @override
  State<_BudgetCheckScreen> createState() => _BudgetCheckScreenState();
}

class _BudgetCheckScreenState extends State<_BudgetCheckScreen> {
  bool _busy = false;

  // A limit that keeps this payment under the 80% line, rounded up to ₹1,000.
  int get _raisedLimit {
    const step = 100000;
    final needed = widget.check.afterPaise * 5 ~/ 4 + 1;
    final rounded = ((needed + step - 1) ~/ step) * step;
    return rounded > widget.check.limitPaise ? rounded : widget.check.limitPaise + step;
  }

  Future<void> _raise() async {
    setState(() => _busy = true);
    try {
      await api.setBudgets(widget.trip.id, {widget.check.category: _raisedLimit});
      if (mounted) Navigator.of(context).pop(_BudgetChoice.raised);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.check;
    final name = categoryLabel(c.category);
    final limit = c.limitPaise == 0 ? 1 : c.limitPaise;
    return Scaffold(
      appBar: AppBar(title: const Text('Budget check')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: TileIcon(Icons.warning_amber_rounded, size: 56, background: AppColors.pendingBg, color: AppColors.pending),
          ),
          const SizedBox(height: 16),
          Text(c.over100 ? 'This goes over the $name budget' : 'This takes $name to ${c.percentAfter}%', style: AppText.title()),
          const SizedBox(height: 6),
          Text('${widget.trip.name} · $name budget ${formatPaise(c.limitPaise)}', style: AppText.detail()),
          const SizedBox(height: 20),
          Bar(fraction: c.usedPaise / limit, extra: c.thisPaymentPaise / limit, extraColor: c.over100 ? AppColors.error : AppColors.amber500),
          const SizedBox(height: 6),
          Row(children: [
            Text('${c.percentBefore}% used', style: AppText.small()),
            const Spacer(),
            Text('${c.percentAfter}% after', style: AppText.small(color: AppColors.pending)),
          ]),
          const SizedBox(height: 20),
          SurfaceCard(
            child: Column(
              children: [
                _row('Used so far', formatPaise(c.usedPaise)),
                _row('This payment', formatPaise(c.thisPaymentPaise)),
                _row(c.leftAfterPaise < 0 ? 'Over the budget' : 'Left after', formatPaise(c.leftAfterPaise.abs())),
              ],
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: _busy ? null : () => Navigator.of(context).pop(_BudgetChoice.payAnyway), child: const Text('Pay anyway')),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _busy ? null : _raise, child: Text('Raise the budget to ${formatPaise(_raisedLimit)}')),
          TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Go back')),
        ],
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [Expanded(child: Text(label, style: AppText.detail())), Text(value, style: AppText.body(weight: FontWeight.w600))]),
      );
}
