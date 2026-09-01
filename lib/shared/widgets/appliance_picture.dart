import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';

enum ApplianceKind {
  fridge,
  freezer,
  washer,
  dryer,
  stove,
  cooktop,
  dishwasher,
  microwave,
  other,
}

ApplianceKind applianceKindOf(String type) {
  final t = type.toLowerCase();
  if (t.contains('мороз') || t.contains('freezer')) return ApplianceKind.freezer;
  if (t.contains('холод') || t.contains('fridge') || t.contains('refrigerator')) {
    return ApplianceKind.fridge;
  }
  if (t.contains('посуд') || t.contains('dish')) return ApplianceKind.dishwasher;
  if (t.contains('стирал') || t.contains('washer') || t.contains('washing')) {
    return ApplianceKind.washer;
  }
  if (t.contains('суш') || t.contains('dryer')) return ApplianceKind.dryer;
  if (t.contains('вароч') ||
      t.contains('cooktop') ||
      t.contains('hob') ||
      t.contains('конфорк')) {
    return ApplianceKind.cooktop;
  }
  if (t.contains('плит') || t.contains('духов') || t.contains('stove') || t.contains('oven') || t.contains('range')) {
    return ApplianceKind.stove;
  }
  if (t.contains('микроволн') || t.contains('microwave')) return ApplianceKind.microwave;
  if (t.contains('универсал') ||
      t.contains('universal') ||
      t.contains('other') ||
      t.contains('техник')) {
    return ApplianceKind.other;
  }
  return ApplianceKind.other;
}

/// Мини-фото техники на карточке заявки.
class AppliancePicture extends StatelessWidget {
  final String type;
  final double size;
  final bool onDark;
  final bool fillSlot;

  const AppliancePicture({
    super.key,
    required this.type,
    this.size = 48,
    this.onDark = false,
    this.fillSlot = false,
  });

  static const _photos = {
    ApplianceKind.fridge: 'assets/appliances/fridge.png',
    ApplianceKind.freezer: 'assets/appliances/freezer.png',
    ApplianceKind.washer: 'assets/appliances/washer.png',
    ApplianceKind.dryer: 'assets/appliances/dryer.png',
    ApplianceKind.stove: 'assets/appliances/stove.png',
    ApplianceKind.cooktop: 'assets/appliances/cooktop.png',
    ApplianceKind.dishwasher: 'assets/appliances/dishwasher.png',
    ApplianceKind.microwave: 'assets/appliances/microwave.png',
    ApplianceKind.other: 'assets/appliances/other.png',
  };

  static String assetOf(String type) {
    return _photos[applianceKindOf(type)] ?? _photos[ApplianceKind.other]!;
  }

  @override
  Widget build(BuildContext context) {
    final kind = applianceKindOf(type);
    final color = ApplianceCategories.logoColor(type);
    final radius = BorderRadius.circular(fillSlot ? 8 : size * 0.18);
    final image = SizedBox.expand(
      child: Image.asset(
        _photos[kind] ?? _photos[ApplianceKind.other]!,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        // Без этого коллаж «other.png» разжимается в полный размер ради
        // значка в 48 точек и держит десятки мегабайт.
        cacheWidth: fillSlot ? 320 : (size * 3).ceil(),
        errorBuilder: (context, error, stack) => CustomPaint(
          painter: _AppliancePicturePainter(
            kind: kind,
            color: color,
            onDark: onDark,
          ),
        ),
      ),
    );
    return Tooltip(
      message: trAny(type.isEmpty ? 'Техника' : type),
      child: Container(
        width: fillSlot ? double.infinity : size,
        height: fillSlot ? double.infinity : size,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: onDark ? Colors.white.withValues(alpha: 0.08) : Colors.white,
          borderRadius: radius,
          border: Border.all(
            color: onDark
                ? Colors.white.withValues(alpha: 0.55)
                : color.withValues(alpha: 0.4),
            width: 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: image,
      ),
    );
  }
}

class _AppliancePicturePainter extends CustomPainter {
  final ApplianceKind kind;
  final Color color;
  final bool onDark;

  _AppliancePicturePainter({
    required this.kind,
    required this.color,
    required this.onDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = size.shortestSide * 0.18;
    final bg = onDark ? Colors.white.withValues(alpha: 0.16) : color.withValues(alpha: 0.12);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(size.width * 0.02), Radius.circular(r)),
      Paint()..color = bg,
    );
    switch (kind) {
      case ApplianceKind.fridge:
        _fridge(canvas, size, color);
      case ApplianceKind.freezer:
        _freezer(canvas, size, color);
      case ApplianceKind.washer:
        _washer(canvas, size, color);
      case ApplianceKind.dryer:
        _dryer(canvas, size, color);
      case ApplianceKind.stove:
      case ApplianceKind.cooktop:
        _stove(canvas, size, color);
      case ApplianceKind.dishwasher:
        _dishwasher(canvas, size, color);
      case ApplianceKind.microwave:
        _microwave(canvas, size, color);
      case ApplianceKind.other:
        _other(canvas, size, color);
    }
  }

  void _body(Canvas canvas, Size size, Color color, {double top = 0.14, double bottom = 0.86}) {
    final w = size.width;
    final h = size.height;
    final rect = Rect.fromLTRB(w * 0.22, h * top, w * 0.78, h * bottom);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(w * 0.08)),
      Paint()..color = color,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(w * 0.08)),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.22)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.03,
    );
  }

  void _fridge(Canvas canvas, Size size, Color color) {
    _body(canvas, size, color);
    final w = size.width;
    final h = size.height;
    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.7)
      ..strokeWidth = w * 0.03
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(w * 0.28, h * 0.38), Offset(w * 0.72, h * 0.38), line);
    final handle = Paint()
      ..color = const Color(0xFFFFC107)
      ..strokeWidth = w * 0.045
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(w * 0.7, h * 0.22), Offset(w * 0.7, h * 0.34), handle);
    canvas.drawLine(Offset(w * 0.7, h * 0.46), Offset(w * 0.7, h * 0.72), handle);
  }

  void _freezer(Canvas canvas, Size size, Color color) {
    _body(canvas, size, const Color(0xFF0288D1));
    final w = size.width;
    final h = size.height;
    final flake = Paint()
      ..color = Colors.white
      ..strokeWidth = w * 0.035
      ..strokeCap = StrokeCap.round;
    final c = Offset(w * 0.5, h * 0.5);
    canvas.drawLine(c.translate(0, -h * 0.12), c.translate(0, h * 0.12), flake);
    canvas.drawLine(c.translate(-w * 0.1, -h * 0.06), c.translate(w * 0.1, h * 0.06), flake);
    canvas.drawLine(c.translate(-w * 0.1, h * 0.06), c.translate(w * 0.1, -h * 0.06), flake);
  }

  void _washer(Canvas canvas, Size size, Color color) {
    _body(canvas, size, color, top: 0.16, bottom: 0.88);
    final w = size.width;
    final h = size.height;
    final door = Paint()..color = const Color(0xFFB3E5FC);
    canvas.drawCircle(Offset(w * 0.5, h * 0.56), w * 0.18, door);
    canvas.drawCircle(
      Offset(w * 0.5, h * 0.56),
      w * 0.18,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.04,
    );
    canvas.drawCircle(Offset(w * 0.34, h * 0.26), w * 0.035, Paint()..color = Colors.white);
    canvas.drawCircle(Offset(w * 0.46, h * 0.26), w * 0.035, Paint()..color = const Color(0xFFFFC107));
  }

  void _dryer(Canvas canvas, Size size, Color color) {
    _body(canvas, size, color, top: 0.16, bottom: 0.88);
    final w = size.width;
    final h = size.height;
    canvas.drawCircle(Offset(w * 0.5, h * 0.56), w * 0.18, Paint()..color = const Color(0xFFFFE0B2));
    canvas.drawCircle(
      Offset(w * 0.5, h * 0.56),
      w * 0.12,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.03,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(w * 0.5, h * 0.26), width: w * 0.28, height: h * 0.07),
        Radius.circular(w * 0.04),
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.85),
    );
  }

  void _stove(Canvas canvas, Size size, Color color) {
    _body(canvas, size, color);
    final w = size.width;
    final h = size.height;
    final burner = Paint()
      ..color = const Color(0xFF212121)
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.03;
    canvas.drawCircle(Offset(w * 0.38, h * 0.32), w * 0.07, burner);
    canvas.drawCircle(Offset(w * 0.62, h * 0.32), w * 0.07, burner);
    canvas.drawCircle(Offset(w * 0.38, h * 0.5), w * 0.07, burner);
    canvas.drawCircle(Offset(w * 0.62, h * 0.5), w * 0.07, burner);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(w * 0.32, h * 0.62, w * 0.68, h * 0.8),
        Radius.circular(w * 0.04),
      ),
      Paint()..color = const Color(0xFFFFE082),
    );
  }

  void _dishwasher(Canvas canvas, Size size, Color color) {
    _body(canvas, size, color);
    final w = size.width;
    final h = size.height;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(w * 0.28, h * 0.2, w * 0.72, h * 0.3),
        Radius.circular(w * 0.03),
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.85),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(w * 0.3, h * 0.38, w * 0.7, h * 0.78),
        Radius.circular(w * 0.04),
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.28),
    );
    canvas.drawLine(
      Offset(w * 0.5, h * 0.42),
      Offset(w * 0.5, h * 0.74),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.7)
        ..strokeWidth = w * 0.03,
    );
  }

  void _microwave(Canvas canvas, Size size, Color color) {
    final w = size.width;
    final h = size.height;
    final rect = Rect.fromLTRB(w * 0.16, h * 0.28, w * 0.84, h * 0.74);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(w * 0.07)),
      Paint()..color = color,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(w * 0.22, h * 0.34, w * 0.62, h * 0.68),
        Radius.circular(w * 0.04),
      ),
      Paint()..color = const Color(0xFF263238),
    );
    for (var i = 0; i < 6; i++) {
      canvas.drawCircle(
        Offset(w * 0.72, h * 0.4 + i * h * 0.045),
        w * 0.018,
        Paint()..color = Colors.white,
      );
    }
  }

  void _other(Canvas canvas, Size size, Color color) {
    final w = size.width;
    final h = size.height;
    final fill = Paint()..color = color;
    final glass = Paint()..color = const Color(0xFFB3E5FC);
    final accent = Paint()..color = const Color(0xFFFFC107);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(w * 0.12, h * 0.18, w * 0.42, h * 0.82),
        Radius.circular(w * 0.05),
      ),
      fill,
    );
    canvas.drawLine(
      Offset(w * 0.16, h * 0.38),
      Offset(w * 0.38, h * 0.38),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.8)
        ..strokeWidth = w * 0.02,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(w * 0.46, h * 0.42, w * 0.7, h * 0.82),
        Radius.circular(w * 0.05),
      ),
      fill,
    );
    canvas.drawCircle(Offset(w * 0.58, h * 0.64), w * 0.07, glass);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(w * 0.72, h * 0.28, w * 0.92, h * 0.54),
        Radius.circular(w * 0.04),
      ),
      fill,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(w * 0.76, h * 0.34, w * 0.86, h * 0.48),
        Radius.circular(w * 0.02),
      ),
      Paint()..color = const Color(0xFF263238),
    );
    canvas.drawCircle(Offset(w * 0.82, h * 0.7), w * 0.035, accent);
  }

  @override
  bool shouldRepaint(covariant _AppliancePicturePainter oldDelegate) {
    return oldDelegate.kind != kind ||
        oldDelegate.color != color ||
        oldDelegate.onDark != onDark;
  }
}
