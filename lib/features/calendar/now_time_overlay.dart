import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

/// Следит за вертикальной прокруткой сетки часов внутри SfCalendar, чтобы
/// линия «сейчас» и метка на шкале ехали вместе с ней.
class NowLineController extends ChangeNotifier {
  ScrollableState? _scrollable;

  final ValueNotifier<List<DateTime>> visibleDates =
      ValueNotifier<List<DateTime>>(const []);

  void onScroll(ScrollNotification notification) {
    if (notification.metrics.axis == Axis.vertical) {
      final ctx = notification.context;
      final found = ctx == null ? null : Scrollable.maybeOf(ctx);
      if (found != null) _scrollable = found;
    }
    notifyListeners();
  }

  void bump() => notifyListeners();

  bool _usable(ScrollableState? state, RenderBox overlay) {
    if (state == null || !state.mounted) return false;
    if (state.widget.axisDirection != AxisDirection.down) return false;
    final box = state.context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    // У календаря три страницы (прошлая/текущая/следующая) — нужна видимая.
    final left = overlay.globalToLocal(box.localToGlobal(Offset.zero)).dx;
    return left > -2 && left < overlay.size.width / 2;
  }

  ScrollableState? _find(BuildContext root, RenderBox overlay) {
    ScrollableState? hit;
    void visit(Element element) {
      if (hit != null) return;
      if (element is StatefulElement && element.state is ScrollableState) {
        final state = element.state as ScrollableState;
        if (_usable(state, overlay)) {
          hit = state;
          return;
        }
      }
      element.visitChildElements(visit);
    }

    root.visitChildElements(visit);
    return hit;
  }

  ScrollableState? resolve(BuildContext root, RenderBox overlay) {
    if (!_usable(_scrollable, overlay)) _scrollable = _find(root, overlay);
    return _scrollable;
  }

  @override
  void dispose() {
    visibleDates.dispose();
    super.dispose();
  }
}

/// Красная линия текущего времени через все дни и жирная метка «сейчас»
/// на шкале часов слева.
class NowTimeOverlay extends StatefulWidget {
  const NowTimeOverlay({
    super.key,
    required this.controller,
    required this.overlayKey,
    required this.slotHeight,
    this.rulerWidth = 52,
  });

  final NowLineController controller;
  final GlobalKey overlayKey;
  final double slotHeight;
  final double rulerWidth;

  static const Color color = Color(0xFFE53935);

  @override
  State<NowTimeOverlay> createState() => _NowTimeOverlayState();
}

class _NowTimeOverlayState extends State<NowTimeOverlay> {
  final ValueNotifier<int> _tick = ValueNotifier<int>(0);
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _tick.value++);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.bump();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _NowTimePainter(
          controller: widget.controller,
          overlayKey: widget.overlayKey,
          slotHeight: widget.slotHeight,
          rulerWidth: widget.rulerWidth,
          repaint: Listenable.merge([
            widget.controller,
            widget.controller.visibleDates,
            _tick,
          ]),
        ),
      ),
    );
  }
}

class _NowTimePainter extends CustomPainter {
  _NowTimePainter({
    required this.controller,
    required this.overlayKey,
    required this.slotHeight,
    required this.rulerWidth,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final NowLineController controller;
  final GlobalKey overlayKey;
  final double slotHeight;
  final double rulerWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final now = DateTime.now();
    final dates = controller.visibleDates.value;
    final index = dates.indexWhere(
      (d) => d.year == now.year && d.month == now.month && d.day == now.day,
    );
    if (index < 0) return;

    final root = overlayKey.currentContext;
    final overlay = root?.findRenderObject();
    if (root == null || overlay is! RenderBox || !overlay.hasSize) return;
    final scrollable = controller.resolve(root, overlay);
    final box = scrollable?.context.findRenderObject();
    if (scrollable == null || box is! RenderBox) return;

    final viewport =
        overlay.globalToLocal(box.localToGlobal(Offset.zero)) & box.size;
    final minutes = now.hour * 60 + now.minute + now.second / 60;
    final y =
        viewport.top -
        scrollable.position.pixels +
        minutes / 60 * slotHeight;
    if (y < viewport.top - 10 || y > viewport.bottom + 10) return;

    canvas.save();
    canvas.clipRect(viewport);

    final gridLeft = viewport.left + rulerWidth;
    final dayWidth = (viewport.right - gridLeft) / dates.length;
    final todayLeft = gridLeft + dayWidth * index;

    canvas.drawLine(
      Offset(gridLeft, y),
      Offset(viewport.right, y),
      Paint()
        ..color = NowTimeOverlay.color.withValues(alpha: 0.45)
        ..strokeWidth = 1,
    );
    canvas.drawLine(
      Offset(todayLeft, y),
      Offset(todayLeft + dayWidth, y),
      Paint()
        ..color = NowTimeOverlay.color
        ..strokeWidth = 2,
    );
    canvas.drawCircle(
      Offset(todayLeft, y),
      4.5,
      Paint()..color = NowTimeOverlay.color,
    );

    final text = TextPainter(
      text: TextSpan(
        text: DateFormat('HH:mm').format(now),
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          fontSize: 12.5,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final pill = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(viewport.left + rulerWidth / 2, y),
        width: (text.width + 10).clamp(0, rulerWidth - 2),
        height: text.height + 4,
      ),
      const Radius.circular(6),
    );
    canvas.drawRRect(pill, Paint()..color = NowTimeOverlay.color);
    text.paint(
      canvas,
      Offset(pill.center.dx - text.width / 2, y - text.height / 2),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _NowTimePainter oldDelegate) =>
      oldDelegate.slotHeight != slotHeight ||
      oldDelegate.rulerWidth != rulerWidth ||
      oldDelegate.controller != controller;
}
