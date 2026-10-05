import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api.dart';
import '../../models.dart';
import '../../money.dart';
import '../../tabs.dart';
import '../../theme.dart';
import '../../widgets/ai_mark.dart';
import '../../widgets/async_view.dart';
import '../money/pay_flow.dart';
import '../money/request_flow.dart';
import '../money/requests.dart';
import '../money/split_flow.dart';
import '../money/top_up.dart';
import '../trips/expense_flow.dart';
import '../trips/trip_shell.dart';

/// Pointy AI: ask about your own money ("what did I spend this week?") or
/// say a payment ("pay Dev 200 for chai"). Answers come from your account;
/// a payment only opens the usual confirm screen, filled in.
class PointyAiScreen extends StatefulWidget {
  const PointyAiScreen({super.key});

  @override
  State<PointyAiScreen> createState() => _PointyAiScreenState();
}

class _PointyAiScreenState extends State<PointyAiScreen> {
  static const _starters = [
    "What's my balance?",
    'How much did I spend this week?',
    'Who owes me money?',
    'How are my trips going?',
    'Pay Dev 200 for chai',
    'Find sunscreen under 1500',
    'Add money',
  ];

  final _text = TextEditingController();
  final _scroll = ScrollController();
  List<ChatMessage>? _messages;
  String? _loadError;
  bool _thinking = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final m = await api.chatHistory();
      if (!mounted) return;
      setState(() {
        _messages = m;
        _loadError = null;
      });
      _toBottom(jump: true);
    } catch (e) {
      if (mounted) setState(() => _loadError = '$e');
    }
  }

  void _toBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      jump ? _scroll.jumpTo(end) : _scroll.animateTo(end, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    });
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _text.text).trim();
    if (text.isEmpty || _thinking) return;
    HapticFeedback.selectionClick();
    _text.clear();
    // Show the question at once; the reply follows.
    final pending = ChatMessage(id: 'pending', role: 'user', text: text);
    setState(() {
      _messages = [...?_messages, pending];
      _thinking = true;
    });
    _toBottom();
    try {
      final turn = await api.chat(text);
      if (!mounted) return;
      setState(() {
        _messages = [..._messages!.where((m) => m.id != 'pending'), ...turn];
        _thinking = false;
      });
      _toBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages = _messages!.where((m) => m.id != 'pending').toList();
        _thinking = false;
        _text.text = text; // nothing is lost: send again
      });
      showError(context, e);
    }
  }

  Future<void> _clear() async {
    try {
      await api.clearChat();
      if (mounted) setState(() => _messages = []);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _act(ChatAction a) {
    final nav = Navigator.of(context);
    void push(Widget w) => nav.push(MaterialPageRoute(builder: (_) => w));
    void tab(int i) {
      nav.popUntil((r) => r.isFirst);
      MainTabs.current.value = i;
    }

    final p = a.person;
    switch (a.type) {
      case 'pay' when p != null:
        push(a.amountPaise > 0 ? PayConfirmScreen(person: p, amountPaise: a.amountPaise, note: a.note) : PayAmountScreen(person: p, note: a.note));
      case 'request' when p != null:
        push(RequestAmountScreen(person: p, amountPaise: a.amountPaise > 0 ? a.amountPaise : null, note: a.note.isEmpty ? null : a.note));
      case 'open':
        switch (a.screen) {
          case 'add_money':
            push(const TopUpScreen());
          case 'requests':
            push(const RequestsScreen());
          case 'split':
            push(const SplitBillScreen());
          case 'trip' when a.tripId.isNotEmpty:
            nav.push(tripRoute(a.tripId));
          case 'trips' || 'trip':
            tab(1);
          case 'insights':
            tab(2);
          case 'history':
            tab(3);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final messages = _messages;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            const AiMark(size: 34),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Pointy AI', style: AppText.heading()),
                  Text('Knows your account · never pays on its own', style: AppText.small()),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (messages != null && messages.isNotEmpty)
            IconButton(tooltip: 'Clear the chat', icon: const Icon(Icons.delete_sweep_outlined), onPressed: _clear),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _loadError != null
                ? ErrorView(message: _loadError!, onRetry: _load)
                : messages == null
                    ? const Center(child: CircularProgressIndicator())
                    : messages.isEmpty && !_thinking
                        ? _welcome()
                        : ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                            itemCount: messages.length + (_thinking ? 1 : 0),
                            itemBuilder: (context, i) => i == messages.length ? const _Thinking() : _bubble(messages[i]),
                          ),
          ),
          if (messages != null && messages.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final s in _starters)
                    Padding(padding: const EdgeInsets.only(right: 8), child: ActionChip(label: Text(s), onPressed: () => _send(s))),
                ],
              ),
            ),
          _input(),
        ],
      ),
    );
  }

  Widget _welcome() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 20),
      children: [
        const Center(child: _Glow(child: AiMark(size: 72))),
        const SizedBox(height: 20),
        Text('Ask me about your money', textAlign: TextAlign.center, style: AppText.title()),
        const SizedBox(height: 6),
        Text('I read your Pointy account: balance, payments, requests and trips. I can also fill in a payment; you always confirm it.',
            textAlign: TextAlign.center, style: AppText.body(color: AppColors.slate)),
        const SizedBox(height: 24),
        for (final s in _starters)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _send(s),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.line)),
                  child: Row(
                    children: [
                      const Icon(aiIcon, size: 16, color: AppColors.amber500),
                      const SizedBox(width: 10),
                      Expanded(child: Text(s, style: AppText.body())),
                      const Icon(Icons.north_east_rounded, size: 16, color: AppColors.slate),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _bubble(ChatMessage m) {
    final mine = m.mine;
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: mine ? AppColors.pine700 : AppColors.surface,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(mine ? 18 : 4),
          bottomRight: Radius.circular(mine ? 4 : 18),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(m.text, style: AppText.body(color: mine ? Colors.white : AppColors.ink)),
          if (m.action != null && m.action!.type != 'shop') ...[
            const SizedBox(height: 10),
            _actionButton(m.action!),
          ],
          if (!mine && m.source == 'ai') ...[const SizedBox(height: 8), const AiLabel()],
        ],
      ),
    );
    return TweenAnimationBuilder<double>(
      key: ValueKey(m.id),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      builder: (context, v, child) => Opacity(opacity: v, child: Transform.translate(offset: Offset(0, 8 * (1 - v)), child: child)),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (!mine) ...[const AiMark(size: 28), const SizedBox(width: 8)],
                Flexible(child: bubble),
              ],
            ),
            if (m.action?.type == 'shop' && m.action!.items.isNotEmpty) ...[
              const SizedBox(height: 10),
              ShopPicks(items: m.action!.items),
            ],
          ],
        ),
      ),
    );
  }

  Widget _actionButton(ChatAction a) {
    final icon = switch (a.type) {
      'pay' => Icons.north_east_rounded,
      'request' => Icons.call_received_rounded,
      _ => Icons.arrow_forward_rounded,
    };
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: a.type == 'open' ? AppColors.pine100 : AppColors.pine700,
        foregroundColor: a.type == 'open' ? AppColors.pine700 : Colors.white,
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        textStyle: AppText.detail(weight: FontWeight.w700),
      ),
      onPressed: () => _act(a),
      icon: Icon(icon, size: 18),
      label: Text(a.label),
    );
  }

  Widget _input() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _text,
                minLines: 1,
                maxLines: 4,
                maxLength: 500,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: 'Ask, or say "pay Dev 200"…',
                  counterText: '',
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: const BorderSide(color: AppColors.lineStrong)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: const BorderSide(color: AppColors.lineStrong)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: const BorderSide(color: AppColors.pine700, width: 2)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: 'Send',
              style: IconButton.styleFrom(backgroundColor: AppColors.pine700, foregroundColor: Colors.white, minimumSize: const Size(48, 48)),
              onPressed: _thinking ? null : _send,
              icon: const Icon(Icons.arrow_upward_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

/// Three dots while Pointy AI is answering.
class _Thinking extends StatefulWidget {
  const _Thinking();

  @override
  State<_Thinking> createState() => _ThinkingState();
}

class _ThinkingState extends State<_Thinking> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    if (AppMotion.loops) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          const AiMark(size: 28),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(18)),
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < 3; i++)
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: AppColors.amber500.withValues(alpha: 0.35 + 0.65 * (((_c.value * 3 - i) % 3) < 1 ? 1 : 0)),
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A soft amber glow that breathes behind the AI mark.
class _Glow extends StatefulWidget {
  const _Glow({required this.child});
  final Widget child;

  @override
  State<_Glow> createState() => _GlowState();
}

class _GlowState extends State<_Glow> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

  @override
  void initState() {
    super.initState();
    if (AppMotion.loops) _c.repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) => Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: AppColors.amber500.withValues(alpha: 0.25 + 0.3 * _c.value), blurRadius: 20 + 16 * _c.value, spreadRadius: 2)],
        ),
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// The floating Pointy AI button, on every main tab.
class PointyAiButton extends StatefulWidget {
  const PointyAiButton({super.key});

  @override
  State<PointyAiButton> createState() => _PointyAiButtonState();
}

class _PointyAiButtonState extends State<PointyAiButton> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

  @override
  void initState() {
    super.initState();
    if (AppMotion.loops) _c.repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Ask Pointy AI',
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) => Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            boxShadow: [
              BoxShadow(color: AppColors.amber500.withValues(alpha: 0.35 + 0.3 * _c.value), blurRadius: 14 + 10 * _c.value, spreadRadius: 1),
            ],
          ),
          child: child,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(30),
            onTap: () {
              HapticFeedback.lightImpact();
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PointyAiScreen()));
            },
            child: Ink(
              padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(30),
                gradient: const LinearGradient(colors: [Color(0xFFFFD27A), AppColors.amber500]),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(aiIcon, size: 20, color: AppColors.amber900),
                  const SizedBox(width: 6),
                  Text('Ask AI', style: AppText.body(color: AppColors.amber900, weight: FontWeight.w700)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Products Pointy AI found, side by side. Each opens the shop; once bought,
/// it can be split with friends or added to a trip as an expense.
class ShopPicks extends StatelessWidget {
  const ShopPicks({super.key, required this.items});

  final List<ShopItem> items;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 318,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(left: 36),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, i) => _ProductCard(item: items[i]),
      ),
    );
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.item});

  final ShopItem item;

  // Short enough for the "What was it?" fields (40 characters).
  String get _what => item.title.length <= 40 ? item.title : '${item.title.substring(0, 39).trimRight()}…';

  Future<void> _open(BuildContext context) async {
    final ok = await launchUrl(Uri.parse(item.buyUrl), mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) showError(context, 'Could not open ${item.merchant}');
  }

  Future<void> _addToTrip(BuildContext context) async {
    final List<Trip> open;
    try {
      open = (await api.trips()).where((t) => t.isOpen).toList();
    } catch (e) {
      if (context.mounted) showError(context, e);
      return;
    }
    if (!context.mounted) return;
    if (open.isEmpty) {
      showMessage(context, 'You have no open trip. Plan one from the Trips tab.');
      return;
    }
    final trip = open.length == 1
        ? open.first
        : await showModalBottomSheet<Trip>(
            context: context,
            builder: (c) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(padding: const EdgeInsets.all(16), child: Text('Add to which trip?', style: AppText.heading())),
                  for (final t in open)
                    ListTile(leading: const Icon(Icons.luggage_rounded), title: Text(t.name), onTap: () => Navigator.pop(c, t)),
                ],
              ),
            ),
          );
    if (trip == null || !context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ExpenseAmountScreen(trip: trip, amountPaise: item.pricePaise, what: _what, payee: item.merchant),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.line)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 110,
            width: double.infinity,
            color: AppColors.ground,
            child: item.imageUrl.isEmpty
                ? const Icon(Icons.shopping_bag_outlined, color: AppColors.slate, size: 36)
                : Image.network(
                    item.imageUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Icon(Icons.shopping_bag_outlined, color: AppColors.slate, size: 36),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.detail(color: AppColors.ink, weight: FontWeight.w600)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(formatPaise(item.pricePaise), style: AppText.body(color: AppColors.pine700, weight: FontWeight.w700)),
                    if (item.wasPricePaise > item.pricePaise) ...[
                      const SizedBox(width: 6),
                      Text(formatPaise(item.wasPricePaise),
                          style: AppText.small().copyWith(decoration: TextDecoration.lineThrough)),
                    ],
                  ],
                ),
                Text('${item.listPrice} at ${item.merchant}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.small()),
              ],
            ),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 36), textStyle: AppText.detail(weight: FontWeight.w700)),
                    onPressed: () => _open(context),
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: const Text('Open shop'),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 34), padding: EdgeInsets.zero, textStyle: AppText.small(weight: FontWeight.w700)),
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => SplitBillScreen(amountPaise: item.pricePaise, what: _what),
                        )),
                        child: const Text('Split it'),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 34), padding: EdgeInsets.zero, textStyle: AppText.small(weight: FontWeight.w700)),
                        onPressed: () => _addToTrip(context),
                        child: const Text('Add to trip'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
