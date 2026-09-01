import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

import '../../models/job.dart';

class VisitLinkNode {
  const VisitLinkNode({
    required this.appointmentId,
    required this.jobId,
    required this.startAt,
    required this.color,
  });

  final String appointmentId;
  final String jobId;
  final DateTime startAt;
  final Color color;
}

/// Все визиты заявок для построения цепочек (даже вне текущей недели).
class VisitLinkCatalog {
  VisitLinkCatalog({
    required this.visibleStart,
    required this.visibleEnd,
    required this.byJob,
  });

  final DateTime visibleStart;
  final DateTime visibleEnd;
  final Map<String, List<VisitLinkNode>> byJob;

  factory VisitLinkCatalog.fromAppointments(
    List<Appointment> appointments, {
    required DateTime visibleStart,
    required int visibleDays,
  }) {
    final byJob = <String, List<VisitLinkNode>>{};
    for (final app in appointments) {
      if (app.id == null) continue;
      final jobId = JobVisit.jobIdFromAppointment(app.id);
      byJob.putIfAbsent(jobId, () => []).add(
            VisitLinkNode(
              appointmentId: app.id.toString(),
              jobId: jobId,
              startAt: app.startTime,
              color: app.color,
            ),
          );
    }
    for (final visits in byJob.values) {
      visits.sort((a, b) {
        final cmp = a.startAt.compareTo(b.startAt);
        if (cmp != 0) return cmp;
        return a.appointmentId.compareTo(b.appointmentId);
      });
    }
    final endDay = visibleStart.add(Duration(days: visibleDays - 1));
    return VisitLinkCatalog(
      visibleStart: visibleStart,
      visibleEnd: DateTime(endDay.year, endDay.month, endDay.day),
      byJob: byJob,
    );
  }

  bool isBeforeVisible(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    return d.isBefore(visibleStart);
  }

  bool isAfterVisible(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    return d.isAfter(visibleEnd);
  }
}

enum VisitLinkEdge { top, bottom }

class VisitLinkSegment {
  const VisitLinkSegment({
    required this.from,
    required this.to,
    required this.fromColor,
    required this.toColor,
    this.fromEdge,
    this.toEdge,
  });

  final Offset from;
  final Offset to;
  final Color fromColor;
  final Color toColor;

  /// С какого края карточки выходит линия (null — край экрана).
  final VisitLinkEdge? fromEdge;

  /// В какой край карточки входит линия (null — край экрана).
  final VisitLinkEdge? toEdge;
}

/// Реестр видимых визитов для цветных связок между днями одной заявки.
class VisitLinkHub extends ChangeNotifier {
  final Map<String, GlobalKey> _keys = {};
  final Map<String, VisitLinkNode> _nodes = {};

  void register({
    required String appointmentId,
    required String jobId,
    required DateTime startAt,
    required Color color,
    required GlobalKey key,
  }) {
    final prev = _nodes[appointmentId];
    final sameKey = identical(_keys[appointmentId], key);
    final sameMeta = prev != null &&
        prev.jobId == jobId &&
        prev.startAt == startAt &&
        prev.color == color;
    _keys[appointmentId] = key;
    _nodes[appointmentId] = VisitLinkNode(
      appointmentId: appointmentId,
      jobId: jobId,
      startAt: startAt,
      color: color,
    );
    if (!sameKey || !sameMeta) {
      notifyListeners();
    }
  }

  void unregister(String appointmentId) {
    if (_keys.remove(appointmentId) == null) return;
    _nodes.remove(appointmentId);
    notifyListeners();
  }

  void bump() => notifyListeners();

  void clear() {
    if (_keys.isEmpty && _nodes.isEmpty) return;
    _keys.clear();
    _nodes.clear();
    notifyListeners();
  }

  Map<String, Rect> visibleRects(GlobalKey overlayKey) {
    final overlayCtx = overlayKey.currentContext;
    final overlayBox = overlayCtx?.findRenderObject() as RenderBox?;
    if (overlayBox == null || !overlayBox.hasSize) return const {};

    final rects = <String, Rect>{};
    for (final entry in _nodes.entries) {
      final key = _keys[entry.key];
      final ctx = key?.currentContext;
      final box = ctx?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) continue;
      if (box.size.width < 2 || box.size.height < 2) continue;

      final topLeft = overlayBox.globalToLocal(box.localToGlobal(Offset.zero));
      final rect = topLeft & box.size;
      if (rect.right < -12 ||
          rect.bottom < -12 ||
          rect.left > overlayBox.size.width + 12 ||
          rect.top > overlayBox.size.height + 12) {
        continue;
      }
      rects[entry.key] = rect;
    }
    return rects;
  }

  List<VisitLinkSegment> segments({
    required GlobalKey overlayKey,
    required VisitLinkCatalog catalog,
    double timeRulerWidth = 52,
  }) {
    final overlayCtx = overlayKey.currentContext;
    final overlayBox = overlayCtx?.findRenderObject() as RenderBox?;
    if (overlayBox == null || !overlayBox.hasSize) return const [];

    final width = overlayBox.size.width;
    final rects = visibleRects(overlayKey);
    final out = <VisitLinkSegment>[];
    const edgePad = 6.0;
    final leftEdge = timeRulerWidth + edgePad;
    final rightEdge = width - edgePad;

    for (final visits in catalog.byJob.values) {
      if (visits.length < 2) continue;

      for (var i = 0; i < visits.length - 1; i++) {
        final a = visits[i];
        final b = visits[i + 1];
        if (JobVisit.isSameDay(a.startAt, b.startAt)) continue;

        final rectA = rects[a.appointmentId];
        final rectB = rects[b.appointmentId];
        final aBefore = catalog.isBeforeVisible(a.startAt);
        final aAfter = catalog.isAfterVisible(a.startAt);
        final bBefore = catalog.isBeforeVisible(b.startAt);
        final bAfter = catalog.isAfterVisible(b.startAt);

        if (rectA != null && rectB != null) {
          out.add(_cardToCard(rectA, rectB, a.color, b.color));
          continue;
        }

        // Хвост вправо — только если следующий визит на другой неделе (не просто за скроллом).
        if (rectA != null && rectB == null && bAfter) {
          final fromEdge = VisitLinkEdge.bottom;
          final from = Offset(rectA.center.dx, rectA.bottom);
          final stubY = from.dy + _edgeStub;
          out.add(
            VisitLinkSegment(
              from: from,
              to: Offset(rightEdge, stubY),
              fromColor: a.color,
              toColor: b.color,
              fromEdge: fromEdge,
            ),
          );
        }

        // Хвост слева — только если предыдущий визит на прошлой неделе.
        if (rectB != null && rectA == null && aBefore) {
          final toEdge = VisitLinkEdge.top;
          final to = Offset(rectB.center.dx, rectB.top);
          final stubY = to.dy - _edgeStub;
          out.add(
            VisitLinkSegment(
              from: Offset(leftEdge, stubY),
              to: to,
              fromColor: a.color,
              toColor: b.color,
              toEdge: toEdge,
            ),
          );
        }
      }
    }

    return out;
  }

  static const double _edgeStub = 14;

  VisitLinkSegment _cardToCard(
    Rect a,
    Rect b,
    Color colorA,
    Color colorB,
  ) {
    final bBelow = b.center.dy >= a.center.dy;
    final fromEdge = bBelow ? VisitLinkEdge.bottom : VisitLinkEdge.top;
    final toEdge = bBelow ? VisitLinkEdge.top : VisitLinkEdge.bottom;
    return VisitLinkSegment(
      from: Offset(
        a.center.dx,
        fromEdge == VisitLinkEdge.bottom ? a.bottom : a.top,
      ),
      to: Offset(
        b.center.dx,
        toEdge == VisitLinkEdge.top ? b.top : b.bottom,
      ),
      fromColor: colorA,
      toColor: colorB,
      fromEdge: fromEdge,
      toEdge: toEdge,
    );
  }
}

class VisitLinkReporter extends StatefulWidget {
  const VisitLinkReporter({
    super.key,
    required this.hub,
    required this.appointmentId,
    required this.jobId,
    required this.startAt,
    required this.color,
    required this.enabled,
    required this.child,
  });

  final VisitLinkHub hub;
  final String appointmentId;
  final String jobId;
  final DateTime startAt;
  final Color color;
  final bool enabled;
  final Widget child;

  @override
  State<VisitLinkReporter> createState() => _VisitLinkReporterState();
}

class _VisitLinkReporterState extends State<VisitLinkReporter> {
  final GlobalKey _key = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void didUpdateWidget(covariant VisitLinkReporter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appointmentId != widget.appointmentId ||
        oldWidget.enabled != widget.enabled) {
      oldWidget.hub.unregister(oldWidget.appointmentId);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    widget.hub.unregister(widget.appointmentId);
    super.dispose();
  }

  void _sync() {
    if (!mounted) return;
    if (!widget.enabled) {
      widget.hub.unregister(widget.appointmentId);
      return;
    }
    widget.hub.register(
      appointmentId: widget.appointmentId,
      jobId: widget.jobId,
      startAt: widget.startAt,
      color: widget.color,
      key: _key,
    );
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: _key,
      child: widget.child,
    );
  }
}

class VisitLinkPainter extends CustomPainter {
  VisitLinkPainter({
    required this.hub,
    required this.overlayKey,
    required this.catalog,
  }) : super(repaint: hub);

  final VisitLinkHub hub;
  final GlobalKey overlayKey;
  final VisitLinkCatalog catalog;

  @override
  void paint(Canvas canvas, Size size) {
    final segments = hub.segments(
      overlayKey: overlayKey,
      catalog: catalog,
    );
    if (segments.isEmpty) return;

    const stub = VisitLinkHub._edgeStub;

    for (final seg in segments) {
      final p0 = seg.from;
      final p1 = seg.to;
      final path = Path()..moveTo(p0.dx, p0.dy);

      Offset? p0Out;
      if (seg.fromEdge != null) {
        p0Out = Offset(
          p0.dx,
          p0.dy + (seg.fromEdge == VisitLinkEdge.bottom ? stub : -stub),
        );
        path.lineTo(p0Out.dx, p0Out.dy);
      } else {
        p0Out = p0;
      }

      Offset? p1In;
      if (seg.toEdge != null) {
        p1In = Offset(
          p1.dx,
          p1.dy + (seg.toEdge == VisitLinkEdge.top ? -stub : stub),
        );
      } else {
        p1In = p1;
      }

      if (seg.fromEdge == null && seg.toEdge == null) {
        path.lineTo(p1.dx, p1.dy);
      } else if (seg.fromEdge != null && seg.toEdge != null) {
        // Карточка → карточка: вертикальный выход/вход, плавная дуга между.
        final dx = p1In.dx - p0Out.dx;
        final dy = p1In.dy - p0Out.dy;
        if (dx.abs() < 8) {
          path.cubicTo(
            p0Out.dx,
            p0Out.dy + dy * 0.45,
            p1In.dx,
            p1In.dy - dy * 0.45,
            p1In.dx,
            p1In.dy,
          );
        } else {
          path.cubicTo(
            p0Out.dx,
            p0Out.dy + dy * 0.12,
            p1In.dx,
            p1In.dy - dy * 0.12,
            p1In.dx,
            p1In.dy,
          );
        }
        path.lineTo(p1.dx, p1.dy);
      } else if (seg.fromEdge != null && seg.toEdge == null) {
        // Хвост вправо: вертикальный выход, затем горизонталь к краю.
        path.lineTo(p1.dx, p1.dy);
      } else {
        // Хвост слева: горизонталь от края, затем вертикально в карточку.
        path.lineTo(p1In.dx, p1In.dy);
        path.lineTo(p1.dx, p1.dy);
      }

      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..shader = LinearGradient(
          colors: [
            seg.fromColor.withValues(alpha: 0.95),
            seg.toColor.withValues(alpha: 0.95),
          ],
        ).createShader(Rect.fromPoints(p0, p1));

      canvas.drawPath(path, paint);

      if (seg.fromEdge != null) {
        canvas.drawCircle(p0, 3.2, Paint()..color = seg.fromColor);
      }
      if (seg.toEdge != null) {
        canvas.drawCircle(p1, 3.2, Paint()..color = seg.toColor);
      }
    }
  }

  @override
  bool shouldRepaint(covariant VisitLinkPainter oldDelegate) {
    return oldDelegate.catalog != catalog;
  }
}

DateTime calendarVisibleStart({
  required DateTime? displayDate,
  required CalendarView? view,
  required int firstDayOfWeek,
}) {
  final anchor = displayDate ?? DateTime.now();
  final day = DateTime(anchor.year, anchor.month, anchor.day);
  if (view == CalendarView.workWeek) {
    final offset = (day.weekday - firstDayOfWeek + 7) % 7;
    return day.subtract(Duration(days: offset));
  }
  final offset = (day.weekday - firstDayOfWeek + 7) % 7;
  return day.subtract(Duration(days: offset));
}

int calendarVisibleDayCount(CalendarView? view) {
  return view == CalendarView.workWeek ? 5 : 7;
}
