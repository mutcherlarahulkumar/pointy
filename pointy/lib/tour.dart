import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tabs.dart';
import 'theme.dart';
import 'widgets/ai_mark.dart';

/// Marks the parts of the app the tour points at. Wrap a widget in
/// `KeyedSubtree(key: TourKeys.balance, child: ...)` to make it a stop.
class TourKeys {
  static final balance = GlobalKey(debugLabel: 'tour-balance');
  static final addMoney = GlobalKey(debugLabel: 'tour-add-money');
  static final myQr = GlobalKey(debugLabel: 'tour-my-qr');
  static final actions = GlobalKey(debugLabel: 'tour-actions');
  static final ai = GlobalKey(debugLabel: 'tour-ai');
  static final suggestion = GlobalKey(debugLabel: 'tour-suggestion');
  static final people = GlobalKey(debugLabel: 'tour-people');
  static final alerts = GlobalKey(debugLabel: 'tour-alerts');
  static final profile = GlobalKey(debugLabel: 'tour-profile');
  static final trips = GlobalKey(debugLabel: 'tour-trips');
  static final scan = GlobalKey(debugLabel: 'tour-scan');
  static final insights = GlobalKey(debugLabel: 'tour-insights');
  static final history = GlobalKey(debugLabel: 'tour-history');
}

/// One stop: what this part is for, and what Pointy does behind it.
class TourStep {
  const TourStep(this.target, this.icon, this.title, this.body, [this.behind, this.ai = false]);

  final GlobalKey target;
  final IconData icon;
  final String title;
  final String body;

  /// What happens behind the scenes, for the curious.
  final String? behind;

  /// Marks a stop where the AI is at work.
  final bool ai;
}

final homeTour = <TourStep>[
  TourStep(TourKeys.balance, Icons.account_balance_wallet_rounded, 'Your Pointy balance',
      'The money you can spend: pay friends, pay their requests, or move it into a trip.',
      'Every rupee is a line in a double-entry ledger, and your balance is worked out from it, never typed in. So it always adds up.'),
  TourStep(TourKeys.addMoney, Icons.add_card_rounded, 'Add money', 'Top up from PayPal. You see rupees; the PayPal sandbox charges the dollar amount.',
      'Pointy creates a PayPal order, you approve it on PayPal, and when PayPal confirms, your balance is credited exactly once, even if PayPal tells us twice.'),
  TourStep(TourKeys.myQr, Icons.qr_code_2_rounded, 'Your QR', 'Friends scan it to pay you. It works between any two Pointy phones.',
      'Money between people never leaves Pointy, so it is instant and free.'),
  TourStep(TourKeys.actions, Icons.bolt_rounded, 'Pay, request, split',
      'Each opens a short form, one step at a time. You confirm every payment with your fingerprint or PIN.',
      'Each payment carries a one-time key, so a double tap or a retry on a bad network can never pay twice.'),
  TourStep(TourKeys.suggestion, aiIcon, 'AI suggestions',
      'A yellow card with the ✦ sparkle is an idea from the AI, from the time, the place and your trips. Nothing happens until you tap it.',
      'Choose what the AI may look at in Profile → What the AI may use.', true),
  TourStep(TourKeys.people, Icons.group_rounded, 'Your people', 'Everyone you paid or asked recently. Tap a face to pay them again.'),
  TourStep(TourKeys.alerts, Icons.notifications_rounded, 'Alerts', 'Money in, requests, budget warnings and reminders, newest first.'),
  TourStep(TourKeys.profile, Icons.person_rounded, 'Profile',
      'Your QR, requests, how you confirm payments (PIN or fingerprint), AI settings, and this tour again.'),
  TourStep(TourKeys.trips, Icons.luggage_rounded, 'Trips',
      'A shared wallet for a group. Everyone puts money in, you pay from it, it splits for you, and it settles up at the end.',
      'Each person has their own share in the ledger. A payment first holds everyone\'s part, then posts; if anything fails, nothing is written.'),
  TourStep(TourKeys.scan, Icons.qr_code_scanner_rounded, 'Scan', 'Point the camera at a friend\'s Pointy QR to pay them.'),
  TourStep(TourKeys.insights, Icons.insights_rounded, 'Insights',
      'Where the money went: by category, time of day, place and person, with a summary and a tip written by the AI.', null, true),
  TourStep(TourKeys.history, Icons.receipt_long_rounded, 'History', 'Every payment, newest first, tagged Trip or Personal.'),
  TourStep(TourKeys.ai, aiIcon, 'Ask AI, anywhere',
      'Ask about your money ("what did I spend this week?", "who owes me?") or say a payment ("pay Dev 200 for chai"). This button opens it from every tab.',
      'It answers from your own account in the database, and remembers the chat. A payment it suggests only opens the confirm screen: it never pays on its own. Without an AI key, simple rules answer.', true),
];

/// Remembers whether the tour has been offered on this phone.
class TourPrefs {
  static const _key = 'pointy.tour_seen';

  static Future<bool> seen() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(_key) ?? false;
    } catch (_) {
      return true; // storage unavailable: do not nag
    }
  }

  static Future<void> markSeen() async {
    try {
      await (await SharedPreferences.getInstance()).setBool(_key, true);
    } catch (_) {}
  }
}

/// Starts the tour on Home. Call from anywhere: it closes open pages first.
Future<void> startTour(BuildContext context, [List<TourStep>? steps]) async {
  final nav = Navigator.of(context, rootNavigator: true);
  nav.popUntil((r) => r.isFirst);
  MainTabs.current.value = 0;
  await TourPrefs.markSeen();
  await Future<void>.delayed(const Duration(milliseconds: 250));
  await nav.push(PageRouteBuilder<void>(
    opaque: false,
    barrierDismissible: false,
    transitionDuration: const Duration(milliseconds: 250),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (_, __, ___) => _TourOverlay(steps: steps ?? homeTour),
    transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
  ));
  // Back to the top of Home, where the tour started.
  final scroll = _scrolled;
  _scrolled = null;
  if (scroll != null && scroll.hasPixels) {
    await scroll.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }
}

/// The page the tour scrolled, so it can go back to the top afterwards.
ScrollPosition? _scrolled;

class _TourOverlay extends StatefulWidget {
  const _TourOverlay({required this.steps});

  final List<TourStep> steps;

  @override
  State<_TourOverlay> createState() => _TourOverlayState();
}

class _TourOverlayState extends State<_TourOverlay> with SingleTickerProviderStateMixin {
  late final List<TourStep> _steps = widget.steps.where((s) => s.target.currentContext != null).toList();
  int _i = 0;
  Rect? _hole;
  bool _showBehind = false;
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _go(0));
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  bool get _finished => _i >= _steps.length;

  Future<void> _go(int i) async {
    setState(() {
      _i = i;
      _showBehind = false;
    });
    if (_finished) {
      setState(() => _hole = null);
      return;
    }
    final ctx = _steps[i].target.currentContext;
    if (ctx == null) return;
    // Scroll the part into view, then measure where it is on screen.
    final scrollable = Scrollable.maybeOf(ctx);
    if (scrollable != null && scrollable.position.axis == Axis.vertical) _scrolled = scrollable.position;
    await Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignment: 0.3, curve: Curves.easeOut);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    if (!mounted || !(ctx.mounted)) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final topLeft = box.localToGlobal(Offset.zero);
    setState(() => _hole = (topLeft & box.size).inflate(6));
  }

  void _next() {
    HapticFeedback.selectionClick();
    _go(_i + 1);
  }

  void _back() {
    if (_i > 0) _go(_i - 1);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final hole = _hole;
    final cardBelow = hole == null || hole.center.dy < size.height * 0.5;
    return PopScope(
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            // The dimmed screen with a lit window over the current part.
            Positioned.fill(
              child: TweenAnimationBuilder<Rect?>(
                tween: RectTween(end: hole ?? Rect.fromCenter(center: size.center(Offset.zero), width: 0, height: 0)),
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeInOutCubic,
                builder: (context, r, _) => AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, _) => CustomPaint(painter: _ScrimPainter(hole: r, pulse: _pulse.value)),
                ),
              ),
            ),
            // The explanation card, on whichever side has room.
            AnimatedPositioned(
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeInOutCubic,
              left: 16,
              right: 16,
              top: _finished ? size.height * 0.28 : (cardBelow ? (hole?.bottom ?? 0) + 16 : null),
              bottom: !_finished && !cardBelow ? size.height - hole.top + 16 : null,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: _finished ? _doneCard() : _stepCard(_steps[_i]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stepCard(TourStep s) {
    return Container(
      key: ValueKey(_i),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(20), boxShadow: cardShadow),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              s.ai
                  ? const AiMark(size: 34)
                  : Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(color: AppColors.pine100, borderRadius: BorderRadius.circular(11)),
                      child: Icon(s.icon, size: 20, color: AppColors.pine700),
                    ),
              const SizedBox(width: 10),
              Expanded(child: Text(s.title, style: AppText.heading())),
              if (s.ai) const AiLabel(),
            ],
          ),
          const SizedBox(height: 8),
          Text(s.body, style: AppText.body()),
          if (s.behind != null) ...[
            const SizedBox(height: 8),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _showBehind = !_showBehind),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    const Icon(Icons.settings_suggest_outlined, size: 18, color: AppColors.pine700),
                    const SizedBox(width: 6),
                    Text('Behind the scenes', style: AppText.detail(color: AppColors.pine700, weight: FontWeight.w700)),
                    Icon(_showBehind ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18, color: AppColors.pine700),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              alignment: Alignment.topCenter,
              child: _showBehind
                  ? Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: AppColors.ground, borderRadius: BorderRadius.circular(10)),
                      child: Text(s.behind!, style: AppText.detail(color: AppColors.ink)),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Text('${_i + 1} of ${_steps.length}', style: AppText.small(color: AppColors.pine700, weight: FontWeight.w700)),
              const SizedBox(width: 10),
              // Progress dots.
              Expanded(
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (var k = 0; k < _steps.length; k++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: k == _i ? 14 : 6,
                        height: 6,
                        decoration: BoxDecoration(color: k <= _i ? AppColors.pine700 : AppColors.mist, borderRadius: BorderRadius.circular(3)),
                      ),
                  ],
                ),
              ),
            ],
          ),
          Row(
            children: [
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Skip')),
              const Spacer(),
              if (_i > 0) IconButton(tooltip: 'Back', onPressed: _back, icon: const Icon(Icons.arrow_back_rounded)),
              const SizedBox(width: 4),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(96, 40)),
                onPressed: _next,
                child: Text(_i == _steps.length - 1 ? 'Finish' : 'Next'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _doneCard() {
    return Container(
      key: const ValueKey('done'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(20), boxShadow: cardShadow),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(color: AppColors.pine500, shape: BoxShape.circle),
            child: const Icon(Icons.check_rounded, color: Colors.white, size: 40),
          ),
          const SizedBox(height: 12),
          Text('You are all set', style: AppText.title()),
          const SizedBox(height: 6),
          Text('Tap Ask AI and try "What did I spend this week?". You can take this tour again from Profile.',
              textAlign: TextAlign.center, style: AppText.body(color: AppColors.slate)),
          const SizedBox(height: 16),
          FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Start using Pointy')),
        ],
      ),
    );
  }
}

/// Dims everything except [hole], with a soft ring that pulses around it.
class _ScrimPainter extends CustomPainter {
  _ScrimPainter({required this.hole, required this.pulse});

  final Rect? hole;
  final double pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final screen = Path()..addRect(Offset.zero & size);
    final scrim = Paint()..color = const Color(0xB3000000);
    final h = hole;
    if (h == null || h.isEmpty) {
      canvas.drawPath(screen, scrim);
      return;
    }
    final window = RRect.fromRectAndRadius(h, const Radius.circular(18));
    canvas.drawPath(Path.combine(PathOperation.difference, screen, Path()..addRRect(window)), scrim);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = AppColors.amber500.withValues(alpha: 1 - pulse);
    canvas.drawRRect(window.inflate(2 + 8 * pulse), ring);
    canvas.drawRRect(window, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = AppColors.amber500);
  }

  @override
  bool shouldRepaint(_ScrimPainter old) => old.hole != hole || old.pulse != pulse;
}
