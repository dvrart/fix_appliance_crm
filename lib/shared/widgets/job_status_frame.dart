import 'package:flutter/material.dart';

import '../../services/status_service.dart';
import 'calendar_hatch.dart';

/// Карточка заявки: широкая цветная рамка. Полоски только на ободке
/// (готово / отменено / перенос), внутри белый фон.
class JobStatusFrame extends StatelessWidget {
  final String status;
  final bool visitDone;
  final Widget child;
  final BorderRadius borderRadius;
  final double borderWidth;
  final VoidCallback? onTap;
  final Color? fillColor;

  const JobStatusFrame({
    super.key,
    required this.status,
    required this.child,
    this.visitDone = false,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.borderWidth = 8,
    this.onTap,
    this.fillColor,
  });

  @override
  Widget build(BuildContext context) {
    final color = StatusService.colorOf(status);
    final hatch = calendarHatchFor(status: status, visitDone: visitDone);
    final paper = fillColor ?? Colors.white;
    return Material(
      color: paper,
      elevation: 1,
      borderRadius: borderRadius,
      child: InkWell(
        onTap: onTap,
        borderRadius: borderRadius,
        child: CustomPaint(
          painter: _StatusBorderPaint(
            color: color,
            hatch: hatch,
            borderWidth: borderWidth,
            radius: borderRadius.topLeft.x,
          ),
          child: Padding(
            padding: EdgeInsets.all(borderWidth),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _StatusBorderPaint extends CustomPainter {
  _StatusBorderPaint({
    required this.color,
    required this.hatch,
    required this.borderWidth,
    required this.radius,
  });

  final Color color;
  final CalendarHatchStyle? hatch;
  final double borderWidth;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final outer = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final inset = borderWidth;
    final innerRadius = (radius - inset).clamp(0, radius);
    final inner = RRect.fromLTRBR(
      inset,
      inset,
      size.width - inset,
      size.height - inset,
      Radius.circular(innerRadius.toDouble()),
    );
    final ring = Path()
      ..addRRect(outer)
      ..addRRect(inner)
      ..fillType = PathFillType.evenOdd;

    canvas.save();
    canvas.clipPath(ring);
    canvas.drawRect(Offset.zero & size, Paint()..color = color);

    if (hatch != null) {
      final stripe = Paint()
        ..strokeWidth = 3.4
        ..strokeCap = StrokeCap.butt
        ..color = Colors.white.withValues(alpha: 0.55);
      const gap = 9.0;
      final extra = size.height;
      final slant = hatch == CalendarHatchStyle.cancelled ? -1.0 : 1.0;
      for (double x = -extra; x < size.width + extra; x += gap) {
        canvas.drawLine(
          Offset(x, size.height),
          Offset(x + extra * slant, 0),
          stripe,
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StatusBorderPaint oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.hatch != hatch ||
        oldDelegate.borderWidth != borderWidth ||
        oldDelegate.radius != radius;
  }
}
