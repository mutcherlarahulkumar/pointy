import 'dart:async';

import 'package:flutter/material.dart';

import '../../api.dart';
import '../../dates.dart';
import '../../models.dart';
import '../../money.dart';
import '../../payment_lock.dart';
import '../../theme.dart';
import '../../totp.dart';
import '../../widgets/amount_field.dart';
import '../../widgets/async_view.dart';
import '../../widgets/avatar.dart';
import '../../widgets/section_title.dart';
import '../../widgets/tag.dart';
import '../money/pay_flow.dart';
import 'family.dart';

/// One child, for their parent: money, limits, the approval code, every
/// payment, and unlinking.
class ChildDetailScreen extends StatefulWidget {
  const ChildDetailScreen({super.key, required this.childId});
  final String childId;

  @override
  State<ChildDetailScreen> createState() => _ChildDetailScreenState();
}

class _ChildDetailScreenState extends State<ChildDetailScreen> {
  late Future<(ChildView, List<HistoryItem>)> _data = _load();

  Future<(ChildView, List<HistoryItem>)> _load() async {
    final f = await api.family();
    final c = f.children.firstWhere((c) => c.child.id == widget.childId, orElse: () => throw ApiException(404, 'not_found', 'This child is no longer linked.'));
    return (c, await api.childActivity(widget.childId));
  }

  void _reload() => setState(() { _data = _load(); });

  Future<void> _limits(ChildView c) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => _LimitsEditScreen(c: c)));
    if (saved == true) _reload();
  }

  Future<void> _unlink(ChildView c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Unlink ${c.child.name}?'),
        content: Text('Their account becomes an ordinary Pointy account: no limits, and you stop seeing their payments.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Unlink')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final pin = await pinValue(context, 'Unlink ${c.child.name}');
    if (pin == null) return;
    try {
      await api.unlinkChild(c.child.id, pin);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Family')),
      body: AsyncView<(ChildView, List<HistoryItem>)>(
        future: _data,
        onRetry: _reload,
        builder: (context, data) {
          final (c, history) = data;
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                Row(children: [
                  Avatar(c.child.name, size: 56),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(c.child.name, style: AppText.title()),
                      Text('${c.age} years · ${formatPaise(c.balancePaise)} in their Pointy', style: AppText.detail()),
                    ]),
                  ),
                ]),
                const SizedBox(height: 16),
                LimitsCard(c: c),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () async {
                        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PayAmountScreen(person: c.child, note: 'Pocket money')));
                        _reload();
                      },
                      icon: const Icon(Icons.redeem_rounded, size: 18),
                      label: const Text('Pocket money'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ApprovalCodeScreen(child: c.child))),
                      icon: const Icon(Icons.pin_outlined, size: 18),
                      label: const Text('Approval code'),
                    ),
                  ),
                ]),
                const SizedBox(height: 4),
                TextButton.icon(onPressed: () => _limits(c), icon: const Icon(Icons.tune_rounded, size: 18), label: const Text('Change limits')),
                const SectionTitle('Their payments'),
                if (history.isEmpty)
                  Text('Nothing yet.', style: AppText.detail())
                else
                  SurfaceCard(
                    padding: EdgeInsets.zero,
                    child: Column(children: [
                      for (var i = 0; i < history.length && i < 30; i++) ...[
                        if (i > 0) const Divider(indent: 16),
                        _row(history[i]),
                      ],
                    ]),
                  ),
                const SizedBox(height: 20),
                TextButton(
                  onPressed: () => _unlink(c),
                  style: TextButton.styleFrom(foregroundColor: AppColors.error),
                  child: Text('Unlink ${c.child.name}'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _row(HistoryItem h) {
    final incoming = h.kind == 'received' || h.kind == 'topup' || h.kind == 'refund';
    return ListTile(
      title: Text(h.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body(weight: FontWeight.w600)),
      subtitle: Text('${h.subtitle} · ${formatDateTime(h.at)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.detail()),
      trailing: Text('${incoming ? '+' : '−'}${formatPaise(h.yourPartPaise)}',
          style: AppText.body(weight: FontWeight.w700, color: incoming ? AppColors.pine700 : AppColors.ink)),
    );
  }
}

class _LimitsEditScreen extends StatefulWidget {
  const _LimitsEditScreen({required this.c});
  final ChildView c;

  @override
  State<_LimitsEditScreen> createState() => _LimitsEditScreenState();
}

class _LimitsEditScreenState extends State<_LimitsEditScreen> {
  late final _daily = TextEditingController(text: paiseToInput(widget.c.dailyLimitPaise));
  late final _monthly = TextEditingController(text: paiseToInput(widget.c.monthlyLimitPaise));
  bool _busy = false;

  @override
  void dispose() {
    _daily.dispose();
    _monthly.dispose();
    super.dispose();
  }

  Future<void> _save(int d, int m) async {
    final pin = await pinValue(context, 'Change ${widget.c.child.name}\'s limits');
    if (pin == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await api.setChildLimits(widget.c.child.id, d, m, pin);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = parseToPaise(_daily.text), m = parseToPaise(_monthly.text);
    final ok = d != null && m != null && d > 0 && m >= d && m <= 1000000;
    return Scaffold(
      appBar: AppBar(title: Text('${widget.c.child.name}\'s limits')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SectionTitle('Each day'),
          AmountField(controller: _daily, autofocus: false, onChanged: () => setState(() {}), chipsRupees: const [100, 200, 500]),
          const SectionTitle('Each month (at most ₹10,000)'),
          AmountField(controller: _monthly, autofocus: false, onChanged: () => setState(() {}), chipsRupees: const [1000, 3000, 5000]),
          const SizedBox(height: 24),
          FilledButton(onPressed: ok && !_busy ? () => _save(d, m) : null, child: const Text('Save with my PIN')),
        ],
      ),
    );
  }
}

/// The approval code for one child, worked out on this phone and new every
/// 30 seconds. The child types it when an over-limit payment needs an OK
/// and the parent is with them.
class ApprovalCodeScreen extends StatefulWidget {
  const ApprovalCodeScreen({super.key, required this.child});
  final Person child;

  // Keys fetched this session, so the PIN is asked once per child.
  static final _keys = <String, Totp>{};

  @override
  State<ApprovalCodeScreen> createState() => _ApprovalCodeScreenState();
}

class _ApprovalCodeScreenState extends State<ApprovalCodeScreen> {
  Timer? _tick;
  Totp? _totp;

  @override
  void initState() {
    super.initState();
    _totp = ApprovalCodeScreen._keys[widget.child.id];
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    if (_totp == null) WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _unlock() async {
    final pin = await pinValue(context, 'Show ${widget.child.name}\'s approval code');
    if (pin == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    try {
      final secret = await api.childCodeKey(widget.child.id, pin);
      final t = Totp(secret);
      ApprovalCodeScreen._keys[widget.child.id] = t;
      if (mounted) setState(() => _totp = t);
    } catch (e) {
      if (mounted) {
        showError(context, e);
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _totp;
    final left = Totp.secondsLeft();
    final code = t?.code() ?? '';
    return Scaffold(
      appBar: AppBar(title: const Text('Approval code')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Avatar(widget.child.name, size: 64),
              const SizedBox(height: 12),
              Text('Code for ${widget.child.name}', style: AppText.heading()),
              const SizedBox(height: 4),
              Text('Only for ${widget.child.name}: each child has their own.', style: AppText.detail()),
              const SizedBox(height: 28),
              if (t == null)
                const CircularProgressIndicator()
              else ...[
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Text('${code.substring(0, 3)} ${code.substring(3)}',
                      key: ValueKey(code), style: AppText.hero(color: AppColors.pine700).copyWith(fontSize: 52, letterSpacing: 6)),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: 48,
                  height: 48,
                  child: Stack(alignment: Alignment.center, children: [
                    CircularProgressIndicator(value: left / Totp.period, strokeWidth: 4, color: left <= 5 ? AppColors.amber500 : AppColors.pine500, backgroundColor: AppColors.mist),
                    Text('$left', style: AppText.detail(weight: FontWeight.w700)),
                  ]),
                ),
                const SizedBox(height: 16),
                const Tag('Works once', kind: TagKind.pending),
                const SizedBox(height: 16),
                Text('${widget.child.name} types it on their phone to let one payment over the limit through. Never send it to anyone else.',
                    textAlign: TextAlign.center, style: AppText.small()),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
