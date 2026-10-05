import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'section_title.dart';

/// The end of a money flow: a calm "done" animation in the colours of what
/// was paid for, the amount and the details.
class SuccessScreen extends StatefulWidget {
  const SuccessScreen({
    super.key,
    required this.title,
    required this.amount,
    this.subtitle,
    this.rows = const [],
    this.doneLabel = 'Done',
    this.pending = false,
    this.category,
  });

  final String title;
  final String amount;
  final String? subtitle;

  /// Label and value pairs shown in a card.
  final List<(String, String)> rows;
  final String doneLabel;

  /// A request sent rather than money moved: an amber clock, not a tick.
  final bool pending;

  /// food, stay, transport or other picks the colour and the little icons
  /// that drift out; null (money between people, top-ups) uses rupees.
  final String? category;

  @override
  State<SuccessScreen> createState() => _SuccessScreenState();
}

class _SuccessScreenState extends State<SuccessScreen> with TickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))..forward();
  // After the burst the circle keeps breathing gently.
  late final _breath = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  @override
  void initState() {
    super.initState();
    // A firm tap when money has moved, a light one for a request sent.
    widget.pending ? HapticFeedback.lightImpact() : HapticFeedback.mediumImpact();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted && AppMotion.loops) _breath.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    _breath.dispose();
    super.dispose();
  }

  // Parts of the one timeline, so every piece flows into the next.
  Animation<double> _part(double from, double to, [Curve curve = Curves.easeOutCubic]) =>
      CurvedAnimation(parent: _c, curve: Interval(from, to, curve: curve));

  @override
  Widget build(BuildContext context) {
    final pending = widget.pending;
    final theme = pending ? _Theme.pending : _Theme.of(widget.category);
    final rows = widget.rows;
    final details = _part(0.45, 0.8);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              const Spacer(),
              _Burst(controller: _c, breath: _breath, theme: theme, pending: pending),
              const SizedBox(height: 8),
              FadeTransition(
                opacity: details,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(details),
                  child: Column(
                    children: [
                      Text(widget.title, textAlign: TextAlign.center, style: AppText.heading(color: pending ? AppColors.pending : AppColors.pine700)),
                      const SizedBox(height: 4),
                      FittedBox(child: Text(widget.amount, style: AppText.balance())),
                      if (widget.subtitle != null) Text(widget.subtitle!, textAlign: TextAlign.center, style: AppText.body(color: AppColors.slate)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              if (rows.isNotEmpty)
                FadeTransition(
                  opacity: _part(0.6, 0.95),
                  child: SurfaceCard(
                    child: Column(
                      children: [
                        for (final (label, value) in rows)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(label, style: AppText.detail()),
                                const SizedBox(width: 16),
                                Expanded(child: Text(value, textAlign: TextAlign.right, style: AppText.body(weight: FontWeight.w600))),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              const Spacer(flex: 2),
              FilledButton(onPressed: () => Navigator.of(context).pop(), child: Text(widget.doneLabel)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The colour and the drifting icons for one kind of payment.
class _Theme {
  const _Theme(this.color, this.soft, this.icons);

  final Color color;
  final Color soft;
  final List<IconData> icons;

  static const pending = _Theme(AppColors.amber500, AppColors.amber100, [Icons.schedule_rounded, Icons.notifications_none_rounded]);

  static _Theme of(String? category) => switch (category) {
        'food' => const _Theme(Color(0xFFE38B2C), Color(0xFFFFEBD3),
            [Icons.restaurant_rounded, Icons.local_cafe_rounded, Icons.lunch_dining_rounded, Icons.icecream_rounded]),
        'stay' => const _Theme(AppColors.personal, AppColors.personalBg, [Icons.bed_rounded, Icons.nights_stay_rounded, Icons.home_rounded, Icons.king_bed_rounded]),
        'transport' => const _Theme(Color(0xFF2B7BB9), Color(0xFFDDEDF8),
            [Icons.directions_car_rounded, Icons.train_rounded, Icons.flight_rounded, Icons.two_wheeler_rounded]),
        'other' => _Theme(AppColors.pine500, AppColors.pine100,
            [Icons.shopping_bag_rounded, Icons.card_giftcard_rounded, Icons.local_offer_rounded, Icons.star_rounded]),
        _ => _Theme(AppColors.pine500, AppColors.pine100,
            [Icons.currency_rupee_rounded, Icons.favorite_rounded, Icons.savings_rounded, Icons.auto_awesome_rounded]),
      };
}

/// The circle settles in with soft ripples, the tick draws itself, then the
/// category's icons drift gently out and fade.
class _Burst extends StatelessWidget {
  const _Burst({required this.controller, required this.breath, required this.theme, required this.pending});

  final AnimationController controller;
  final AnimationController breath;
  final _Theme theme;
  final bool pending;

  static const _size = 220.0;
  static const _circle = 92.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _size,
      height: _size,
      child: AnimatedBuilder(
        animation: Listenable.merge([controller, breath]),
        builder: (context, _) {
          final t = controller.value;
          double seg(double a, double b) => ((t - a) / (b - a)).clamp(0.0, 1.0);
          final grow = Curves.easeOutBack.transform(seg(0, 0.3)) * (1 + 0.035 * Curves.easeInOut.transform(breath.value));
          final tick = Curves.easeInOutCubic.transform(seg(0.25, 0.55));
          return Stack(
            alignment: Alignment.center,
            children: [
              // Two slow ripples.
              for (final start in const [0.1, 0.3])
                _ripple(Curves.easeOut.transform(seg(start, start + 0.6))),
              // Icons drifting out on a gentle curve.
              for (var i = 0; i < 8; i++) _particle(i, Curves.easeOutCubic.transform(seg(0.3 + i * 0.02, 1))),
              Transform.scale(
                scale: grow,
                child: Container(
                  width: _circle,
                  height: _circle,
                  decoration: BoxDecoration(
                    color: theme.color,
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: theme.color.withValues(alpha: 0.35), blurRadius: 24, offset: const Offset(0, 8))],
                  ),
                  child: pending
                      ? Opacity(opacity: tick, child: const Icon(Icons.schedule_send_rounded, color: Colors.white, size: 48))
                      : CustomPaint(painter: _TickPainter(tick)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _ripple(double v) {
    if (v <= 0 || v >= 1) return const SizedBox.shrink();
    return Container(
      width: _circle * (1 + v * 1.3),
      height: _circle * (1 + v * 1.3),
      decoration: BoxDecoration(shape: BoxShape.circle, color: theme.soft.withValues(alpha: (1 - v) * 0.9)),
    );
  }

  Widget _particle(int i, double v) {
    if (v <= 0 || v >= 1) return const SizedBox.shrink();
    final angle = -math.pi / 2 + i * (2 * math.pi / 8) + 0.2;
    final r = _circle / 2 + 10 + v * 46;
    // Fade in quickly, drift, and fade away only at the end; rise a little.
    final opacity = (v < 0.15 ? v / 0.15 : v > 0.7 ? (1 - v) / 0.3 : 1.0).clamp(0.0, 1.0);
    return Transform.translate(
      offset: Offset(math.cos(angle) * r, math.sin(angle) * r - v * 14),
      child: Opacity(
        opacity: opacity,
        child: Transform.rotate(
          angle: (i.isEven ? 1 : -1) * v * 0.5,
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(color: theme.soft, shape: BoxShape.circle),
            child: Icon(theme.icons[i % theme.icons.length], size: 16 + (i % 3) * 3, color: theme.color),
          ),
        ),
      ),
    );
  }
}

/// A white tick drawn stroke by stroke as [progress] goes from 0 to 1.
class _TickPainter extends CustomPainter {
  _TickPainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final w = size.width;
    final path = Path()
      ..moveTo(w * 0.28, w * 0.52)
      ..lineTo(w * 0.44, w * 0.67)
      ..lineTo(w * 0.73, w * 0.36);
    final metric = path.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * progress),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.09
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_TickPainter old) => old.progress != progress;
}
