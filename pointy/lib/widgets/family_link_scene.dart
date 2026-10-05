import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// The moment two phones are linked: the parent's bigger phone rises in,
/// the child's smaller phone slides into its care, a glowing link draws
/// between them, a shield seals it, and little hearts drift up. Then the
/// child's phone keeps gently bobbing, held.
class FamilyLinkScene extends StatefulWidget {
  const FamilyLinkScene({super.key, required this.parent, required this.child});

  final String parent;
  final String child;

  @override
  State<FamilyLinkScene> createState() => _FamilyLinkSceneState();
}

class _FamilyLinkSceneState extends State<FamilyLinkScene> with TickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800))..forward();
  late final _bob = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200));

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted && AppMotion.loops) _bob.repeat(reverse: true);
    });
    // A soft tap when the link closes.
    Future.delayed(const Duration(milliseconds: 1900), () {
      if (mounted) HapticFeedback.mediumImpact();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    _bob.dispose();
    super.dispose();
  }

  static const _w = 280.0, _h = 230.0;
  static const _warm = Color(0xFFFF8A4C);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _w,
      height: _h,
      child: AnimatedBuilder(
        animation: Listenable.merge([_c, _bob]),
        builder: (context, _) {
          final t = _c.value;
          double seg(double a, double b, [Curve curve = Curves.easeOutCubic]) => curve.transform(((t - a) / (b - a)).clamp(0.0, 1.0));
          final bigIn = seg(0, 0.3);
          final smallIn = seg(0.18, 0.5, Curves.easeOutBack);
          final link = seg(0.45, 0.72, Curves.easeInOutCubic);
          final shield = seg(0.66, 0.86, Curves.easeOutBack);
          final hearts = seg(0.72, 1, Curves.linear);
          final bob = Curves.easeInOut.transform(_bob.value);

          // Where the two phones sit when settled.
          const bigPos = Offset(36, 30);
          const smallPos = Offset(182, 96);
          final small = Offset.lerp(const Offset(_w + 20, 96), smallPos, smallIn)! + Offset(0, -4 * bob);
          final big = bigPos + Offset(0, 40 * (1 - bigIn));

          return Stack(
            clipBehavior: Clip.none,
            children: [
              // A soft glow behind the pair once linked.
              Positioned.fill(
                child: Opacity(
                  opacity: link * 0.9,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(colors: [AppColors.pine100, AppColors.pine100.withValues(alpha: 0)]),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: big.dx,
                top: big.dy,
                child: Opacity(opacity: bigIn, child: _Phone(width: 92, height: 168, color: AppColors.pine700, label: _initials(widget.parent))),
              ),
              // The link: a curve from the parent's screen to the child's,
              // drawn as it goes, with a bright dot running along it.
              Positioned.fill(child: CustomPaint(painter: _LinkPainter(from: big + const Offset(64, 22), to: small + const Offset(30, 6), progress: link))),
              Positioned(
                left: small.dx,
                top: small.dy,
                child: Transform.rotate(
                  angle: -0.08 * (1 - smallIn) + 0.03,
                  child: _Phone(width: 64, height: 116, color: _warm, label: _initials(widget.child)),
                ),
              ),
              // The shield: looked after.
              Positioned(
                left: small.dx + 30,
                top: small.dy - 18,
                child: Transform.scale(
                  scale: shield,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.pine500,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: [BoxShadow(color: AppColors.pine500.withValues(alpha: 0.4), blurRadius: 12)],
                    ),
                    child: const Icon(Icons.verified_user_rounded, color: Colors.white, size: 22),
                  ),
                ),
              ),
              for (var i = 0; i < 6; i++) _heart(i, hearts, small),
            ],
          );
        },
      ),
    );
  }

  Widget _heart(int i, double v, Offset near) {
    final local = ((v - i * 0.08) / 0.6).clamp(0.0, 1.0);
    if (local <= 0 || local >= 1) return const SizedBox.shrink();
    final x = near.dx - 40 + i * 22.0 + math.sin(local * math.pi * 2 + i) * 6;
    final y = near.dy - 10 - local * 70;
    return Positioned(
      left: x,
      top: y,
      child: Opacity(
        opacity: local < 0.2 ? local / 0.2 : (1 - local) / 0.8,
        child: Icon(i.isEven ? Icons.favorite_rounded : Icons.auto_awesome_rounded, size: 14 + (i % 3) * 3.0, color: i.isEven ? _warm : AppColors.amber500),
      ),
    );
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    return (parts.first[0] + (parts.length > 1 ? parts.last[0] : '')).toUpperCase();
  }
}

/// A simple phone: rounded body, a screen with the owner's initials.
class _Phone extends StatelessWidget {
  const _Phone({required this.width, required this.height, required this.color, required this.label});

  final double width, height;
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      padding: EdgeInsets.all(width * 0.07),
      decoration: BoxDecoration(
        color: AppColors.ink,
        borderRadius: BorderRadius.circular(width * 0.2),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 16, offset: const Offset(0, 8))],
      ),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(width * 0.14),
          gradient: LinearGradient(colors: [color, Color.lerp(color, Colors.white, 0.35)!], begin: Alignment.topLeft, end: Alignment.bottomRight),
        ),
        alignment: Alignment.center,
        child: Container(
          width: width * 0.5,
          height: width * 0.5,
          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: Text(label, style: TextStyle(fontSize: width * 0.18, fontWeight: FontWeight.w800, color: color)),
        ),
      ),
    );
  }
}

class _LinkPainter extends CustomPainter {
  _LinkPainter({required this.from, required this.to, required this.progress});

  final Offset from, to;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final mid = Offset((from.dx + to.dx) / 2, math.min(from.dy, to.dy) - 64);
    final path = Path()
      ..moveTo(from.dx, from.dy)
      ..quadraticBezierTo(mid.dx, mid.dy, to.dx, to.dy);
    final metric = path.computeMetrics().first;
    final drawn = metric.extractPath(0, metric.length * progress);
    canvas.drawPath(
        drawn,
        Paint()
          ..color = AppColors.amber500.withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    canvas.drawPath(
        drawn,
        Paint()
          ..color = AppColors.amber500
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round);
    final tip = metric.getTangentForOffset(metric.length * progress)?.position;
    if (tip != null && progress < 1) canvas.drawCircle(tip, 6, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_LinkPainter old) => old.progress != progress || old.from != from || old.to != to;
}

/// A whole screen for the moment a family link is made, on either phone.
class FamilyLinkedScreen extends StatelessWidget {
  const FamilyLinkedScreen({super.key, required this.parent, required this.child, required this.forParent, this.limits});

  final String parent;
  final String child;
  final bool forParent;
  final String? limits;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(),
              FamilyLinkScene(parent: parent, child: child),
              const SizedBox(height: 24),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 700),
                curve: const Interval(0.4, 1, curve: Curves.easeOut),
                builder: (context, v, child) => Opacity(opacity: v, child: Transform.translate(offset: Offset(0, 16 * (1 - v)), child: child)),
                child: Column(
                  children: [
                    Text(forParent ? 'You\'re looking after $child' : '$parent looks after you now', textAlign: TextAlign.center, style: AppText.title()),
                    const SizedBox(height: 8),
                    Text(
                      forParent
                          ? 'You\'ll see their payments, and anything over their limit waits for your OK.'
                          : 'Spend within your limits. For more, ask $parent and they can say yes from their phone.',
                      textAlign: TextAlign.center,
                      style: AppText.body(color: AppColors.slate),
                    ),
                    if (limits != null) ...[const SizedBox(height: 10), Text(limits!, style: AppText.detail(weight: FontWeight.w700))],
                  ],
                ),
              ),
              const Spacer(flex: 2),
              FilledButton(onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst), child: Text(forParent ? 'Done' : 'Let\'s go')),
            ],
          ),
        ),
      ),
    );
  }
}
