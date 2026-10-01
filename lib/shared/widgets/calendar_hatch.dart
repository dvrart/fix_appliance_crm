import 'package:flutter/material.dart';

import '../../core/constants.dart';

enum CalendarHatchStyle { completed, cancelled, rescheduled }

class CalendarHatchPaint extends CustomPainter {
  CalendarHatchPaint({required this.color, required this.style});

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
  bool visitDone = false,
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

const Color kCalendarDoneGreen = Color(0xFF1B8A3A);
const Color kCalendarCancelRed = Color(0xFFD32F2F);

/// Маленькая отметка статуса в углу карточки календаря: зелёная галочка
/// (заявка сделана), красный крест (отменена) или эмодзи статуса. Одна
/// отметка на карточку — крупных водяных знаков поверх карточки нет.
class CalendarStatusBadge extends StatelessWidget {
  const CalendarStatusBadge({
    super.key,
    this.hatch,
    this.emoji,
    this.size = 13,
  });

  final CalendarHatchStyle? hatch;
  final String? emoji;
  final double size;

  static bool has({CalendarHatchStyle? hatch, String? emoji}) {
    return hatch == CalendarHatchStyle.completed ||
        hatch == CalendarHatchStyle.cancelled ||
        (emoji != null && emoji.isNotEmpty);
  }

  @override
  Widget build(BuildContext context) {
    final closed =
        hatch == CalendarHatchStyle.completed ||
        hatch == CalendarHatchStyle.cancelled;
    if (closed) {
      final cancelled = hatch == CalendarHatchStyle.cancelled;
      return Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(
          cancelled ? Icons.close_rounded : Icons.check_rounded,
          size: size * 0.84,
          color: cancelled ? kCalendarCancelRed : kCalendarDoneGreen,
          weight: 900,
        ),
      );
    }
    final mark = emoji;
    if (mark == null || mark.isEmpty) return const SizedBox.shrink();
    return Text(mark, style: TextStyle(fontSize: size * 0.92, height: 1));
  }
}

/// Закрытая заявка (готово / отменено) на карточке приглушается, чтобы
/// открытые работы читались первыми. Штриховки больше нет.
const double kCalendarClosedOpacity = 0.55;

/// Эмодзи статуса. «Завершено» и «Отменено» его не имеют —
/// у них галочка и крест.
String? calendarStatusEmoji(String status) {
  final key = status.trim();
  if (key.isEmpty) return null;
  if (JobStatuses.isCompletedStatus(key) ||
      JobStatuses.isCancelledStatus(key)) {
    return null;
  }
  if (JobStatuses.isDepositStatus(key)) return '\u{1F4B2}';
  if (JobStatuses.isInstallStatus(key)) return '\u{1F50C}';
  switch (key) {
    case JobStatuses.call:
      return '\u{1F9F0}';
    case JobStatuses.inProgress:
      return '\u{1F527}';
    case JobStatuses.rescheduled:
      return '\u{1F504}';
    case JobStatuses.waitingPart:
      return '\u{1F4E6}';
    case JobStatuses.callBack:
      return '\u{1F4DE}';
    case JobStatuses.repeatVisit:
      return '\u{1F501}';
    case JobStatuses.repeat:
      return '\u{1F4C5}';
  }
  final n = key.toLowerCase();
  if (n.contains('звон') || n.contains('call')) return '\u{1F4DE}';
  if (n.contains('запчаст') || n.contains('part')) return '\u{1F4E6}';
  if (n.contains('оплат') || n.contains('деньг') || n.contains('pay')) {
    return '\u{1F4B2}';
  }
  if (n.contains('гарант') || n.contains('warranty')) return '\u{1F6E1}';
  if (n.contains('перенос') || n.contains('reschedul')) return '\u{1F504}';
  return '\u{1F4CC}';
}
