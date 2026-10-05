import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api.dart';
import '../../models.dart';
import '../../money.dart';
import '../../payment_lock.dart';
import '../../theme.dart';
import '../../widgets/amount_field.dart';
import '../../widgets/async_view.dart';
import '../../widgets/family_link_scene.dart';
import '../../widgets/flow_scaffold.dart';
import '../../widgets/section_title.dart';
import 'terms.dart';

const _steps = ['Terms', 'Child', 'Limits'];

/// Linking a child, step by step. Nothing changes for the child until they
/// enter the code from this phone on theirs, with their own PIN.
class _Draft {
  bool agreed = false;
  String phone = '';
  DateTime? birth;
  int dailyPaise = 20000; // ₹200
  int monthlyPaise = 300000; // ₹3,000
}

/// Step 1: the terms, read and accepted.
class AddChildScreen extends StatefulWidget {
  const AddChildScreen({super.key});

  @override
  State<AddChildScreen> createState() => _AddChildScreenState();
}

class _AddChildScreenState extends State<AddChildScreen> {
  final _d = _Draft();

  @override
  Widget build(BuildContext context) {
    return FlowScaffold(
      appBarTitle: 'Add a child',
      steps: _steps,
      step: 0,
      title: 'Before you start',
      subtitle: 'Pointy Parenting terms · $familyTermsVersion',
      buttonLabel: 'Continue',
      onNext: _d.agreed ? () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _ChildScreen(d: _d))) : null,
      children: [
        for (final (title, body) in familyTerms)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppText.body(weight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(body, style: AppText.detail()),
              ],
            ),
          ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _d.agreed,
          onChanged: (v) => setState(() => _d.agreed = v ?? false),
          title: Text('I am the parent or lawful guardian, I am 18 or older, and I accept these terms', style: AppText.detail(color: AppColors.ink)),
        ),
      ],
    );
  }
}

/// Step 2: the child's mobile number and date of birth.
class _ChildScreen extends StatefulWidget {
  const _ChildScreen({required this.d});
  final _Draft d;

  @override
  State<_ChildScreen> createState() => _ChildScreenState();
}

class _ChildScreenState extends State<_ChildScreen> {
  late final _phone = TextEditingController(text: widget.d.phone);

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  int? get _age {
    final b = widget.d.birth;
    if (b == null) return null;
    final now = DateTime.now();
    var a = now.year - b.year;
    if (now.month < b.month || (now.month == b.month && now.day < b.day)) a--;
    return a;
  }

  Future<void> _pickBirth() async {
    final now = DateTime.now();
    final b = await showDatePicker(
      context: context,
      helpText: 'Child\'s date of birth',
      initialDate: widget.d.birth ?? DateTime(now.year - 12, now.month, now.day),
      firstDate: DateTime(now.year - 18, now.month, now.day + 1),
      lastDate: now,
    );
    if (b != null) setState(() => widget.d.birth = b);
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.d;
    final ok = _phone.text.length == 10 && _age != null && _age! < 18;
    return FlowScaffold(
      appBarTitle: 'Add a child',
      steps: _steps,
      step: 1,
      title: 'Who is your child?',
      subtitle: 'They need their own Pointy account first. Only children under 18 can be linked.',
      buttonLabel: 'Continue',
      onNext: ok
          ? () {
              d.phone = _phone.text;
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => _LimitsScreen(d: d)));
            }
          : null,
      children: [
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)],
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(labelText: 'Child\'s mobile number', prefixText: '+91  '),
        ),
        const SizedBox(height: 12),
        SurfaceCard(
          padding: EdgeInsets.zero,
          child: ListTile(
            leading: Icon(Icons.cake_outlined, color: AppColors.pine700),
            title: Text(d.birth == null ? 'Date of birth' : '${d.birth!.day}/${d.birth!.month}/${d.birth!.year}', style: AppText.body(weight: FontWeight.w600)),
            subtitle: Text(_age == null ? 'Tap to choose' : '$_age years old', style: AppText.detail()),
            trailing: const Icon(Icons.edit_calendar_outlined),
            onTap: _pickBirth,
          ),
        ),
      ],
    );
  }
}

/// Step 3: daily and monthly limits, then the parent's PIN and the code.
class _LimitsScreen extends StatefulWidget {
  const _LimitsScreen({required this.d});
  final _Draft d;

  @override
  State<_LimitsScreen> createState() => _LimitsScreenState();
}

class _LimitsScreenState extends State<_LimitsScreen> {
  late final _daily = TextEditingController(text: paiseToInput(widget.d.dailyPaise));
  late final _monthly = TextEditingController(text: paiseToInput(widget.d.monthlyPaise));
  bool _busy = false;

  static const _maxMonth = 1000000; // ₹10,000, the RBI cap for small wallets

  @override
  void dispose() {
    _daily.dispose();
    _monthly.dispose();
    super.dispose();
  }

  Future<void> _link(int daily, int monthly) async {
    final d = widget.d;
    final pin = await pinValue(context, 'Link your child with your PIN');
    if (pin == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final b = d.birth!;
      final inv = await api.inviteChild({
        'child_phone': d.phone,
        'birth_date': '${b.year}-${b.month.toString().padLeft(2, '0')}-${b.day.toString().padLeft(2, '0')}',
        'daily_limit_paise': daily,
        'monthly_limit_paise': monthly,
        'accept_terms': familyTermsVersion,
        'pin': pin,
      });
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.settings.name == 'family' || r.isFirst);
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => PairingCodeScreen(invite: inv)));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final daily = parseToPaise(_daily.text), monthly = parseToPaise(_monthly.text);
    String? problem;
    if (daily == null || monthly == null || daily <= 0 || monthly <= 0) {
      problem = 'Set both limits';
    } else if (daily > monthly) {
      problem = 'The daily limit cannot be more than the monthly one';
    } else if (monthly > _maxMonth) {
      problem = 'The monthly limit can be at most ${formatPaise(_maxMonth)}';
    }
    return FlowScaffold(
      appBarTitle: 'Add a child',
      steps: _steps,
      step: 2,
      title: 'How much can they spend?',
      subtitle: 'Anything over a limit waits for your OK. You can change these later.',
      buttonLabel: problem ?? 'Link with my PIN',
      busy: _busy,
      onNext: problem == null ? () => _link(daily!, monthly!) : null,
      children: [
        const SectionTitle('Each day'),
        AmountField(controller: _daily, autofocus: false, onChanged: () => setState(() {}), chipsRupees: const [100, 200, 500]),
        const SectionTitle('Each month'),
        AmountField(controller: _monthly, autofocus: false, onChanged: () => setState(() {}), chipsRupees: const [1000, 3000, 5000]),
      ],
    );
  }
}

/// The code for the child's phone, with a countdown. Shown once.
class PairingCodeScreen extends StatefulWidget {
  const PairingCodeScreen({super.key, required this.invite});
  final FamilyInvite invite;

  @override
  State<PairingCodeScreen> createState() => _PairingCodeScreenState();
}

class _PairingCodeScreenState extends State<PairingCodeScreen> {
  // The countdown ticks every second; every three, look whether the child
  // has accepted, and celebrate when they have.
  late final Timer _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  late final Timer _poll = Timer.periodic(const Duration(seconds: 3), (_) => _check());
  bool _linked = false;

  @override
  void initState() {
    super.initState();
    _poll; // start polling
  }

  @override
  void dispose() {
    _tick.cancel();
    _poll.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    if (_linked) return;
    try {
      final f = await api.family();
      final c = f.children.where((c) => c.linkId == widget.invite.child.linkId).firstOrNull;
      if (c != null && c.isActive && mounted) {
        _linked = true;
        Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => FamilyLinkedScreen(
            parent: c.parent.name,
            child: c.child.name,
            forParent: true,
            limits: '${formatPaise(c.dailyLimitPaise)} a day · ${formatPaise(c.monthlyLimitPaise)} a month',
          ),
        ));
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.invite.expires.difference(DateTime.now());
    final expired = left.isNegative;
    final name = widget.invite.child.child.name;
    final code = widget.invite.code;
    return Scaffold(
      appBar: AppBar(title: const Text('Link your child')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Spacer(),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              child: _linked
                  ? Column(
                      key: const ValueKey('done'),
                      children: [
                        Icon(Icons.verified_rounded, size: 72, color: AppColors.pine500),
                        const SizedBox(height: 12),
                        Text('$name is linked', style: AppText.title()),
                        const SizedBox(height: 8),
                        Text('You will see their payments, and anything over a limit waits for you.', textAlign: TextAlign.center, style: AppText.body(color: AppColors.slate)),
                      ],
                    )
                  : Column(
                      key: const ValueKey('code'),
                      children: [
                        Text('On $name\'s phone', style: AppText.body(color: AppColors.slate)),
                        const SizedBox(height: 4),
                        Text('Profile → Family → type this code', style: AppText.heading()),
                        const SizedBox(height: 20),
                        Text(expired ? '— — —' : '${code.substring(0, 3)} ${code.substring(3)}',
                            style: AppText.hero(color: expired ? AppColors.slate : AppColors.pine700).copyWith(fontSize: 48, letterSpacing: 6)),
                        const SizedBox(height: 8),
                        Text(expired ? 'This code ran out. Start again.' : 'Works for ${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')} more · only once',
                            style: AppText.detail()),
                        const SizedBox(height: 16),
                        Text('They will also need their own PIN, so nobody can link an account without its owner.', textAlign: TextAlign.center, style: AppText.small()),
                      ],
                    ),
            ),
            const Spacer(flex: 2),
            FilledButton(onPressed: () => Navigator.of(context).pop(), child: Text(_linked ? 'Done' : 'Close')),
          ],
        ),
      ),
    );
  }
}
