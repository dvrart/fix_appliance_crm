import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../features/ai/assistant/assistant_session.dart';

/// Смайлик в шапке: белый — ждёт, жёлтый — слушает. Глаза и рот двигаются.
class AnimatedAppLogo extends StatefulWidget {
  final double size;
  final bool interactive;

  const AnimatedAppLogo({
    super.key,
    this.size = 32,
    this.interactive = true,
  });

  @override
  State<AnimatedAppLogo> createState() => _AnimatedAppLogoState();
}

class _AnimatedAppLogoState extends State<AnimatedAppLogo>
    with TickerProviderStateMixin {
  late final AnimationController _life;
  late final AnimationController _blink;

  @override
  void initState() {
    super.initState();
    _life = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
    _blink = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 140),
    );
    _scheduleBlink();
    AssistantSession.instance.addListener(_onSession);
  }

  void _onSession() {
    if (mounted) setState(() {});
  }

  void _scheduleBlink() {
    Future<void>.delayed(
      Duration(milliseconds: 1800 + math.Random().nextInt(2200)),
      () {
        if (!mounted) return;
        _blink.forward(from: 0).then((_) {
          if (!mounted) return;
          _blink.reverse().then((_) {
            if (mounted) _scheduleBlink();
          });
        });
      },
    );
  }

  @override
  void dispose() {
    AssistantSession.instance.removeListener(_onSession);
    _life.dispose();
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = AssistantSession.instance;
    final listening = session.isListening;
    final face = listening ? const Color(0xFFFCC520) : Colors.white;
    final glow = listening ? const Color(0xFFFCC520) : Colors.transparent;

    final child = AnimatedBuilder(
      animation: Listenable.merge([_life, _blink]),
      builder: (context, _) {
        final glance = math.sin(_life.value * math.pi * 2) * (listening ? 1.6 : 0.7);
        final mouth = listening ? (0.18 + session.soundLevel * 0.82) : 0.08;
        return CustomPaint(
          size: Size.square(widget.size),
          painter: _SmileyPainter(
            fill: face,
            glanceX: glance,
            blink: Curves.easeInOut.transform(_blink.value),
            mouthOpen: mouth,
            listening: listening,
          ),
        );
      },
    );

    return GestureDetector(
      onTap: widget.interactive ? session.toggle : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: listening
              ? [
                  BoxShadow(
                    color: glow.withValues(alpha: 0.7),
                    blurRadius: 10,
                    spreadRadius: 1,
                  ),
                ]
              : const [],
        ),
        child: child,
      ),
    );
  }
}

class _SmileyPainter extends CustomPainter {
  final Color fill;
  final double glanceX;
  final double blink;
  final double mouthOpen;
  final bool listening;

  _SmileyPainter({
    required this.fill,
    required this.glanceX,
    required this.blink,
    required this.mouthOpen,
    required this.listening,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final face = Paint()..color = fill;
    canvas.drawCircle(center, radius, face);

    final ink = Paint()
      ..color = const Color(0xFF14557F)
      ..style = PaintingStyle.fill;

    final eyeY = center.dy - radius * 0.14;
    final eyeDx = radius * 0.32;
    final eyeW = radius * 0.16;
    final eyeH = radius * 0.2 * (1 - blink * 0.92);
    _eye(canvas, Offset(center.dx - eyeDx + glanceX, eyeY), eyeW, eyeH, ink);
    _eye(canvas, Offset(center.dx + eyeDx + glanceX, eyeY), eyeW, eyeH, ink);

    final mouthPaint = Paint()
      ..color = const Color(0xFF14557F)
      ..style = mouthOpen > 0.28 ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = math.max(1.4, radius * 0.08)
      ..strokeCap = StrokeCap.round;

    final mouthY = center.dy + radius * 0.28;
    final mouthW = radius * (0.42 + mouthOpen * 0.12);
    final smile = radius * (0.16 + mouthOpen * 0.28);
    final path = Path()
      ..moveTo(center.dx - mouthW, mouthY)
      ..quadraticBezierTo(
        center.dx,
        mouthY + smile,
        center.dx + mouthW,
        mouthY,
      );
    if (mouthOpen > 0.28) {
      path.quadraticBezierTo(
        center.dx,
        mouthY + smile * 0.15,
        center.dx - mouthW,
        mouthY,
      );
      path.close();
    }
    canvas.drawPath(path, mouthPaint);
  }

  void _eye(Canvas canvas, Offset c, double w, double h, Paint paint) {
    canvas.drawOval(
      Rect.fromCenter(center: c, width: w * 2, height: math.max(0.8, h * 2)),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _SmileyPainter old) {
    return old.fill != fill ||
        old.glanceX != glanceX ||
        old.blink != blink ||
        old.mouthOpen != mouthOpen ||
        old.listening != listening;
  }
}
