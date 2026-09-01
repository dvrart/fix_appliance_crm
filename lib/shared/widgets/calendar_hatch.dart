import 'package:flutter/material.dart';

import '../../core/constants.dart';

enum CalendarHatchStyle { completed, cancelled, rescheduled }

class CalendarHatchPaint extends CustomPainter {
  CalendarHatchPaint({
    required this.color,
    required this.style,
  });

  final Color color;
  final CalendarHatchStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    final fill = Paint()..color = color.withValues(alpha: 0.88);
    canvas.drawRect(Offset.zero & size, fill);

    final stripe = Paint()
      ..strokeWidth = style == CalendarHatchStyle.cancelled ? 3.2 : 2.4
      ..strokeCap = StrokeCap.butt
      ..color = style == CalendarHatchStyle.cancelled
          ? Colors.black.withValues(alpha: 0.28)
          : Colors.white.withValues(alpha: 0.42);

    final gap = style == CalendarHatchStyle.rescheduled ? 10.0 : 7.0;
    final slant = style == CalendarHatchStyle.cancelled ? -1.0 : 1.0;
    final extra = size.height;
    for (double x = -extra; x < size.width + extra; x += gap) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + extra * slant, 0),
        stripe,
      );
    }

    if (style == CalendarHatchStyle.cancelled) {
      final cross = Paint()
        ..color = Colors.white.withValues(alpha: 0.55)
        ..strokeWidth = 1.6;
      canvas.drawLine(Offset.zero, Offset(size.width, size.height), cross);
      canvas.drawLine(Offset(size.width, 0), Offset(0, size.height), cross);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(CalendarHatchPaint oldDelegate) {
    return oldDelegate.color != color || oldDelegate.style != style;
  }
}

class HatchedCalendarCard extends StatelessWidget {
  const HatchedCalendarCard({
    super.key,
    required this.color,
    required this.borderRadius,
    required this.child,
    this.hatch,
  });

  final Color color;
  final BorderRadius borderRadius;
  final Widget child;
  final CalendarHatchStyle? hatch;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: hatch != null
                ? CustomPaint(
                    painter: CalendarHatchPaint(color: color, style: hatch!),
                  )
                : ColoredBox(color: color),
          ),
          child,
        ],
      ),
    );
  }
}

CalendarHatchStyle? calendarHatchFor({
  required String status,
  required bool visitDone,
}) {
  if (JobStatuses.isCancelledStatus(status)) {
    return CalendarHatchStyle.cancelled;
  }
  if (status == JobStatuses.rescheduled) {
    return CalendarHatchStyle.rescheduled;
  }
  if (status == JobStatuses.waitingPart) {
    return null;
  }
  if (visitDone || JobStatuses.isCompletedStatus(status)) {
    return CalendarHatchStyle.completed;
  }
  return null;
}

IconData? calendarHatchIcon(CalendarHatchStyle? hatch) {
  switch (hatch) {
    case CalendarHatchStyle.completed:
      return Icons.check;
    case CalendarHatchStyle.cancelled:
      return Icons.close;
    case CalendarHatchStyle.rescheduled:
      return Icons.update;
    case null:
      return null;
  }
}
