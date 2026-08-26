import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/app_commands.dart';
import '../../../core/app_feedback.dart';
import '../../../core/constants.dart';
import '../../../shared/widgets/animated_app_logo.dart';
import 'assistant_controller.dart';
import 'assistant_host.dart';

enum AssistantFaceMood {
  idle,
  listening,
  speaking,
  paused,
  connecting,
  angry,
}

class FacePose {
  final Color color;
  final double frown;
  final double happy;
  final double check;
  final double brows;

  const FacePose({
    required this.color,
    this.frown = 0,
    this.happy = 0,
    this.check = 0,
    this.brows = 0,
  });
}

double _smoothStep(double p, double a, double b) {
  if (p <= a) return 0;
  if (p >= b) return 1;
  final t = (p - a) / (b - a);
  return Curves.easeInOutCubic.transform(t);
}

double _holdThenOut(double p, {required double fadeIn, required double fadeOut}) {
  if (p < fadeIn) return _smoothStep(p, 0, fadeIn);
  if (p < fadeOut) return 1;
  return 1 - _smoothStep(p, fadeOut, 1);
}

FacePose facePoseNow(AssistantFaceMood mood) {
  final idle = assistantFaceColor(mood);
  final reaction = AppCommands.reaction;
  final p = AppCommands.reactionProgress;
  if (reaction == FaceReaction.angry) {
    final t = _holdThenOut(p, fadeIn: 0.24, fadeOut: 0.68);
    return FacePose(
      color: Color.lerp(idle, const Color(0xFFE53935), t)!,
      frown: t,
      brows: t,
    );
  }
  if (reaction == FaceReaction.happy) {
    const green = Color(0xFF22C55E);
    final colorT = p < 0.80
        ? _smoothStep(p, 0, 0.22)
        : 1 - _smoothStep(p, 0.80, 1);
    final happyT = p < 0.40
        ? _smoothStep(p, 0, 0.22)
        : p < 0.66
            ? 1 - _smoothStep(p, 0.40, 0.66)
            : 0.0;
    final checkT = p < 0.40
        ? 0.0
        : p < 0.66
            ? _smoothStep(p, 0.40, 0.66)
            : p < 0.80
                ? 1.0
                : 1 - _smoothStep(p, 0.80, 1);
    return FacePose(
      color: Color.lerp(idle, green, colorT)!,
      happy: happyT,
      check: checkT,
    );
  }
  return FacePose(color: idle);
}

AssistantFaceMood assistantMoodOf(AssistantController controller) {
  if (!controller.isOpen) return AssistantFaceMood.idle;
  if (controller.isConnecting) return AssistantFaceMood.connecting;
  if (controller.isPaused) return AssistantFaceMood.paused;
  if (controller.isSpeaking) return AssistantFaceMood.speaking;
  return AssistantFaceMood.listening;
}

Color assistantDiscColor(AssistantFaceMood mood) {
  return switch (mood) {
    AssistantFaceMood.speaking => AppColors.accent,
    AssistantFaceMood.paused => const Color(0xFFFFE082),
    AssistantFaceMood.connecting => const Color(0xFFFFE082),
    AssistantFaceMood.listening => AppColors.accent,
    AssistantFaceMood.angry => const Color(0xFFE53935),
    AssistantFaceMood.idle => Colors.white,
  };
}

Color assistantFaceColor(AssistantFaceMood mood) => assistantDiscColor(mood);

/// Compact living シ-face in the top center — tap starts listening (yellow).
class AssistantFaceButton extends StatelessWidget {
  final double size;

  const AssistantFaceButton({super.key, this.size = 56});

  @override
  Widget build(BuildContext context) {
    final controller = AssistantHost.controllerOf(context);
    return ListenableBuilder(
      listenable: Listenable.merge([
        AppCommands.faceTick,
        if (controller != null) controller,
      ]),
      builder: (context, _) {
        final mood = controller == null
            ? AssistantFaceMood.idle
            : assistantMoodOf(controller);
        return _tapFace(context, size, mood);
      },
    );
  }

  Widget _tapFace(BuildContext context, double size, AssistantFaceMood mood) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () {
          AppFeedback.pleasant();
          final controller = AssistantHost.controllerOf(context);
          if (controller != null && controller.isOpen) {
            AssistantHost.close(context);
          } else {
            AssistantHost.open(context);
          }
        },
        onLongPress: () => AssistantHost.close(context),
        child: SizedBox(
          width: size,
          height: size,
          child: LivingAssistantFace(size: size, mood: mood),
        ),
      ),
    );
  }
}

class LivingAssistantFace extends StatefulWidget {
  final double size;
  final AssistantFaceMood mood;
  final bool useLogo;

  const LivingAssistantFace({
    super.key,
    required this.size,
    this.mood = AssistantFaceMood.idle,
    this.useLogo = false,
  });

  @override
  State<LivingAssistantFace> createState() => _LivingAssistantFaceState();
}

class _LivingAssistantFaceState extends State<LivingAssistantFace>
    with SingleTickerProviderStateMixin {
  late final AnimationController _life;
  AssistantFaceMood? _lastMood;

  @override
  void initState() {
    super.initState();
    _lastMood = widget.mood;
    _life = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();
  }

  @override
  void didUpdateWidget(LivingAssistantFace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mood != widget.mood && _lastMood != widget.mood) {
      _lastMood = widget.mood;
      AppFeedback.pleasant();
    }
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _life,
      builder: (context, _) {
        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (widget.useLogo)
                ClipOval(
                  child: Image.asset(
                    kAppLogoAsset,
                    width: widget.size,
                    height: widget.size,
                    fit: BoxFit.cover,
                  ),
                ),
              CustomPaint(
                size: Size.square(widget.size),
                painter: ShiFacePainter(
                  t: _life.value * 12,
                  mood: widget.mood,
                  onLogo: widget.useLogo,
                  pose: facePoseNow(widget.mood),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Upright シ: two white dash-eyes looking straight, level smile that
/// opens and slides left ↔ right.
class ShiFacePainter extends CustomPainter {
  final double t;
  final AssistantFaceMood mood;
  final bool onLogo;
  final FacePose pose;

  ShiFacePainter({
    required this.t,
    required this.mood,
    this.onLogo = false,
    this.pose = const FacePose(color: Colors.white),
  });

  Color get color => pose.color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final breathe = math.sin(t * math.pi * 2 / 1.6) * 0.025;
    var scale = 1.0 + breathe;
    if (mood == AssistantFaceMood.speaking) {
      scale += 0.04 + math.sin(t * 14).abs() * 0.03;
    } else if (mood == AssistantFaceMood.listening) {
      scale += 0.02;
    } else if (mood == AssistantFaceMood.paused) {
      scale -= 0.04;
    }
    scale += pose.frown * (0.04 + math.sin(t * 18).abs() * 0.03);
    scale += pose.happy * 0.05;

    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.scale(scale);
    canvas.translate(-c.dx, -c.dy);

    if (pose.check < 0.98) {
      _drawEyes(canvas, size);
      if (pose.brows > 0.02) {
        _drawBrows(canvas, size);
      }
      _drawMouth(canvas, size);
    }
    if (pose.check > 0.02) {
      _drawCheck(canvas, size);
    }
    canvas.restore();
  }

  double get _blink {
    if (mood == AssistantFaceMood.paused) return 0.55;
    final cycle = t % 3.4;
    if (cycle < 0.12) {
      return cycle < 0.06 ? cycle / 0.06 : 1 - (cycle - 0.06) / 0.06;
    }
    return 0;
  }

  double get _mouthOpen {
    if (mood == AssistantFaceMood.speaking) {
      return 0.28 + math.sin(t * 15).abs() * 0.72;
    }
    if (mood == AssistantFaceMood.listening) return 0.16;
    if (mood == AssistantFaceMood.connecting) {
      return 0.08 + math.sin(t * 5).abs() * 0.14;
    }
    return 0;
  }

  void _drawBrows(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final w = s * 0.16;
    final gap = s * (onLogo ? 0.26 : 0.22);
    final y = (onLogo ? size.height * 0.34 : size.height / 2 - s * 0.13) - s * 0.16;
    final cx = size.width / 2;
    final paint = Paint()
      ..color = color.withValues(alpha: pose.brows.clamp(0.0, 1.0))
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = s * 0.07;
    canvas.drawLine(
      Offset(cx - gap / 2 - w / 2, y - s * 0.02),
      Offset(cx - gap / 2 + w / 2, y + s * 0.04),
      paint,
    );
    canvas.drawLine(
      Offset(cx + gap / 2 + w / 2, y - s * 0.02),
      Offset(cx + gap / 2 - w / 2, y + s * 0.04),
      paint,
    );
  }

  void _drawEyes(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final open = (1 - _blink).clamp(0.14, 1.0);
    final w = s * (onLogo ? 0.08 : 0.095);
    final h = s * (onLogo ? 0.16 : 0.26) * open;
    final gap = s * (onLogo ? 0.26 : 0.22);
    final y = onLogo ? size.height * 0.34 : size.height / 2 - s * 0.13;
    final cx = size.width / 2;
    _dash(canvas, Offset(cx - gap / 2, y), w, h);
    _dash(canvas, Offset(cx + gap / 2, y), w, h);
  }

  void _dash(Canvas canvas, Offset center, double w, double h) {
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: w, height: h),
      Radius.circular(w / 2),
    );
    if (onLogo) {
      canvas.drawRRect(
        rect,
        Paint()
          ..color = const Color(0xFF0B1F33)
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * 0.35,
      );
    }
    canvas.drawRRect(
      rect,
      Paint()..color = color.withValues(alpha: (1 - pose.check).clamp(0.0, 1.0)),
    );
  }

  void _drawMouth(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final open = _mouthOpen;
    final mx = size.width / 2;
    final my = onLogo ? size.height * 0.72 : size.height / 2 + s * 0.17;
    final halfW = s * (0.18 + open * 0.05 + pose.happy * 0.04);
    final smileDrop = s * (0.09 + open * 0.16 + pose.happy * 0.07);
    final frownDrop = s * 0.11;
    final drop = smileDrop * (1 - pose.frown) - frownDrop * pose.frown;
    final strokeW = s * (onLogo ? 0.07 : 0.10);
    final faceAlpha = (1 - pose.check).clamp(0.0, 1.0);

    void strokePath(Path path, {bool fill = false}) {
      if (onLogo) {
        canvas.drawPath(
          path,
          Paint()
            ..color = const Color(0xFF0B1F33)
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..strokeWidth = strokeW + s * 0.02,
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: faceAlpha)
          ..style = fill ? PaintingStyle.fill : PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = strokeW,
      );
    }

    if (mood == AssistantFaceMood.paused) {
      strokePath(
        Path()
          ..moveTo(mx - s * 0.14, my)
          ..lineTo(mx + s * 0.14, my),
      );
      return;
    }

    if (open < 0.12 || pose.frown > 0.08 || pose.happy > 0.08) {
      strokePath(
        Path()
          ..moveTo(mx - halfW, my)
          ..quadraticBezierTo(mx, my + drop, mx + halfW, my),
      );
      return;
    }

    final top = my - open * s * 0.03;
    final bottom = my + drop;
    final mouth = Path()
      ..moveTo(mx - halfW, top)
      ..quadraticBezierTo(mx, bottom, mx + halfW, top)
      ..quadraticBezierTo(mx, top + s * 0.025, mx - halfW, top)
      ..close();
    strokePath(mouth, fill: true);
  }

  void _drawCheck(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final cx = size.width / 2;
    final cy = size.height / 2 + s * 0.02;
    final path = Path()
      ..moveTo(cx - s * 0.16, cy + s * 0.02)
      ..lineTo(cx - s * 0.02, cy + s * 0.16)
      ..lineTo(cx + s * 0.20, cy - s * 0.14);
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: pose.check.clamp(0.0, 1.0))
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = s * 0.11,
    );
  }

  @override
  bool shouldRepaint(covariant ShiFacePainter oldDelegate) {
    return oldDelegate.t != t ||
        oldDelegate.mood != mood ||
        oldDelegate.onLogo != onLogo ||
        oldDelegate.pose.color != pose.color ||
        oldDelegate.pose.frown != pose.frown ||
        oldDelegate.pose.happy != pose.happy ||
        oldDelegate.pose.check != pose.check ||
        oldDelegate.pose.brows != pose.brows;
  }
}
