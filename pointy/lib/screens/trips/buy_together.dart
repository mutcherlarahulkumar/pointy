import 'package:flutter/material.dart';

import '../../api.dart';
import '../../models.dart';
import '../../money.dart';
import '../../theme.dart';
import '../../widgets/ai_mark.dart';
import '../../widgets/async_view.dart';
import '../../widgets/product_image.dart';
import 'group_buy.dart';

/// The trip's shopping agent: say what the group needs, get up to three
/// picks with a reason each, and propose one to the group. Nothing is
/// bought here.
class BuyTogetherScreen extends StatefulWidget {
  const BuyTogetherScreen({super.key, required this.trip});

  final Trip trip;

  @override
  State<BuyTogetherScreen> createState() => _BuyTogetherScreenState();
}

class _BuyTogetherScreenState extends State<BuyTogetherScreen> {
  final _ask = TextEditingController();
  AgentAnswer? _answer;
  bool _busy = false;
  int? _proposing; // index of the pick being proposed

  static const _ideas = ['Sunscreen under 800', 'A beach speaker', 'First-aid kit', 'Snacks for the road'];

  @override
  void dispose() {
    _ask.dispose();
    super.dispose();
  }

  Future<void> _search([String? text]) async {
    final q = (text ?? _ask.text).trim();
    if (q.isEmpty || _busy) return;
    _ask.text = q;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      final a = await api.shopAgent(widget.trip.id, q);
      if (mounted) setState(() => _answer = a);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _propose(AgentPick p) async {
    setState(() => _proposing = p.index);
    try {
      final g = await api.proposeGroupBuy(widget.trip.id, _answer!.searchId, p, key: newIdempotencyKey());
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => GroupBuyScreen(trip: widget.trip, id: g.id, initial: g)));
    } catch (e) {
      if (mounted) {
        setState(() => _proposing = null);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = _answer;
    return Scaffold(
      appBar: AppBar(title: const Text('Buy together')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          Text('What does the group need?', style: AppText.title()),
          const SizedBox(height: 6),
          Text('The AI finds it in online shops. You pick one; it is bought only if all ${widget.trip.members.length} of you say yes.',
              style: AppText.body(color: AppColors.slate)),
          const SizedBox(height: 16),
          TextField(
            controller: _ask,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: 'e.g. a speaker for the beach under 2000',
              prefixIcon: const Padding(padding: EdgeInsets.all(12), child: AiMark(size: 22)),
              suffixIcon: IconButton(icon: const Icon(Icons.arrow_upward_rounded), onPressed: _busy ? null : () => _search()),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [for (final i in _ideas) ActionChip(label: Text(i), onPressed: _busy ? null : () => _search(i))]),
          const SizedBox(height: 20),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: _busy
                ? const _Searching(key: ValueKey('busy'))
                : a == null
                    ? const SizedBox.shrink()
                    : Column(
                        key: ValueKey(a.searchId),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const AiMark(size: 22),
                              const SizedBox(width: 8),
                              Expanded(child: Text(a.reply, style: AppText.body())),
                            ],
                          ),
                          const SizedBox(height: 12),
                          for (final p in a.picks) _PickCard(pick: p, busy: _proposing == p.index, onPropose: _proposing == null ? () => _propose(p) : null),
                        ],
                      ),
          ),
        ],
      ),
    );
  }
}

class _Searching extends StatelessWidget {
  const _Searching({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Text('Looking through the shops…', style: AppText.detail()),
        ],
      ),
    );
  }
}

class _PickCard extends StatelessWidget {
  const _PickCard({required this.pick, required this.busy, required this.onPropose});

  final AgentPick pick;
  final bool busy;
  final VoidCallback? onPropose;

  @override
  Widget build(BuildContext context) {
    final it = pick.item;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: AppColors.line)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ProductImage(it.imageUrl),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(it.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body(weight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(it.merchant, style: AppText.small()),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Text(formatPaise(it.pricePaise), style: AppText.body(color: AppColors.pine700, weight: FontWeight.w700)),
                          const SizedBox(width: 8),
                          Text('${formatPaise(pick.eachPaise)} each', style: AppText.detail()),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(color: AppColors.amber100, borderRadius: BorderRadius.circular(10)),
              child: Text(pick.why, style: AppText.detail(color: AppColors.amber900)),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: busy ? null : onPropose,
                child: busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Propose to the group'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
