import 'package:flutter/material.dart';

import '../../api.dart';
import '../../dates.dart';
import '../../money.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../widgets/avatar.dart';
import '../../widgets/tag.dart';

/// The trip assistant. The organiser types an instruction, the assistant
/// drafts a plan, and nothing is sent until the organiser taps "Send".
class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key, required this.trip, this.initialInstruction});

  final Trip trip;
  final String? initialInstruction;

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

/// One bubble in the chat: text from you or the assistant, or a plan card.
class _Message {
  final bool fromMe;
  final String? text;
  final Plan? plan;
  _Message.me(this.text)
      : fromMe = true,
        plan = null;
  _Message.bot(this.text)
      : fromMe = false,
        plan = null;
  _Message.plan(this.plan)
      : fromMe = false,
        text = null;
}

class _AssistantScreenState extends State<AssistantScreen> {
  late final TextEditingController _input = TextEditingController(text: widget.initialInstruction ?? '');
  final _scroll = ScrollController();
  final List<_Message> _messages = [];
  bool _busy = false;
  String? _confirmingPlanId;

  List<String> get _quickPrompts {
    final due = widget.trip.start.subtract(const Duration(days: 2));
    final dueText = due.isAfter(DateTime.now()) ? ' by ${formatDay(due)}' : '';
    return [
      if (widget.trip.depositTargetPaise > 0) 'Collect ${formatPaise(widget.trip.depositTargetPaise)} from everyone$dueText',
      'Ask everyone for ₹2,000$dueText',
      'Collect ₹1,000 each',
    ];
  }

  @override
  void initState() {
    super.initState();
    _messages.add(_Message.bot(
      'Hi! Tell me how much to collect and from whom, in your own words, like “Collect ₹3,000 from everyone by 20 Oct” '
      'or “ask Dev and Meera for 2k by Friday”. I draft the requests and wait for your OK before sending anything.',
    ));
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      });

  Future<void> _ask(String text) async {
    if (text.trim().isEmpty || _busy) return;
    setState(() {
      _messages.add(_Message.me(text.trim()));
      _input.clear();
      _busy = true;
    });
    _toEnd();
    try {
      final plan = await api.draftPlan(widget.trip.id, text.trim());
      setState(() {
        // The model's reply comes first, like a chat, then the plan to approve.
        if (plan.note.isNotEmpty) _messages.add(_Message.bot(plan.note));
        _messages.add(_Message.plan(plan));
      });
    } on ApiException catch (e) {
      setState(() => _messages.add(_Message.bot(e.toString())));
    } finally {
      if (mounted) setState(() => _busy = false);
      _toEnd();
    }
  }

  Future<void> _confirm(Plan plan) async {
    setState(() => _confirmingPlanId = plan.id);
    try {
      // One key per plan: confirming the same plan twice cannot send twice.
      final sent = await api.confirmPlan(widget.trip.id, plan.id, key: 'confirm-${plan.id}');
      setState(() {
        final i = _messages.indexWhere((m) => m.plan?.id == plan.id);
        if (i >= 0) _messages[i] = _Message.plan(plan.withStatus('confirmed'));
        _messages.add(_Message.bot(sent == 0
            ? 'Nothing new to send: everyone has already paid.'
            : 'Sent $sent request${sent == 1 ? '' : 's'}. Each person sees it on their phone and can pay from their balance or with PayPal. '
                'I mark them paid as the money comes in.'));
      });
    } on ApiException catch (e) {
      setState(() => _messages.add(_Message.bot(e.toString())));
    } finally {
      if (mounted) setState(() => _confirmingPlanId = null);
      _toEnd();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(color: AppColors.amber500, borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.auto_awesome, size: 16, color: AppColors.amber900),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text('${widget.trip.name} assistant', overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.all(16),
              children: [
                for (final m in _messages) m.plan != null ? _planCard(m.plan!) : _bubble(m),
                if (_busy) const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator()),
              ],
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final p in _quickPrompts)
                  Padding(padding: const EdgeInsets.only(right: 8), child: ActionChip(label: Text(p), onPressed: () => _ask(p))),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(hintText: 'Tell the assistant what to collect'),
                      onSubmitted: _ask,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    style: IconButton.styleFrom(backgroundColor: AppColors.pine700),
                    icon: const Icon(Icons.send),
                    onPressed: _busy ? null : () => _ask(_input.text),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(_Message m) {
    return Align(
      alignment: m.fromMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        constraints: const BoxConstraints(maxWidth: 300),
        decoration: BoxDecoration(
          color: m.fromMe ? AppColors.pine700 : AppColors.surface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(m.fromMe ? 18 : 4),
            bottomRight: Radius.circular(m.fromMe ? 4 : 18),
          ),
        ),
        child: Text(m.text!, style: AppText.body(color: m.fromMe ? Colors.white : AppColors.ink)),
      ),
    );
  }

  Widget _planCard(Plan p) {
    final waiting = p.status == 'draft';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.amber100, borderRadius: BorderRadius.circular(18)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome, color: AppColors.amber900, size: 18),
              const SizedBox(width: 6),
              Expanded(child: Text('Plan', style: AppText.body(color: AppColors.amber900, weight: FontWeight.w700))),
              waiting ? const Tag('Waiting for your OK', kind: TagKind.pending) : const Tag('Sent', kind: TagKind.trip),
            ],
          ),
          const SizedBox(height: 6),
          Text('${formatPaise(p.perPersonPaise)} each by ${formatWeekday(p.due)}', style: AppText.detail(color: AppColors.amber900)),
          const SizedBox(height: 10),
          for (final it in p.items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Avatar(it.name, size: 28),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(it.name, style: AppText.body(color: AppColors.amber900, weight: FontWeight.w600)),
                        Text(_channel(it), style: AppText.small(color: AppColors.amber900)),
                      ],
                    ),
                  ),
                  Text(formatPaise(it.amountPaise), style: AppText.body(color: AppColors.amber900, weight: FontWeight.w700)),
                ],
              ),
            ),
          const Divider(),
          Text('Total ${formatPaise(p.totalPaise)}', style: AppText.body(color: AppColors.amber900, weight: FontWeight.w700)),
          if (waiting) ...[
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _confirmingPlanId != null || p.requestCount == 0 ? null : () => _confirm(p),
              child: Text(p.requestCount == 0 ? 'Nothing to send' : 'Send ${p.requestCount} request${p.requestCount == 1 ? '' : 's'}'),
            ),
            TextButton(onPressed: () => setState(() => _input.text = p.instruction), child: const Text('Edit plan')),
          ],
        ],
      ),
    );
  }

  String _channel(PlanItem it) => switch (it.channel) {
        'already_paid' => 'Already paid',
        'organiser' => 'You · add it from the Wallet tab',
        _ => 'Gets a request on their phone',
      };
}
