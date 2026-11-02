import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

import '../../models/home_appliance.dart';
import '../../services/sticker_printer_service.dart';

/// Что печатается на наклейке паспорта. Всё по-английски: наклейку читает
/// клиент, а термоголова кириллицу печатает, но клиенту она ни к чему.
class StickerContent {
  static const String shopName = 'FIX-Appliance.CA';

  final String company;
  final String phone;
  final String title;
  final String model;
  final String serial;
  final String code;
  final String url;

  const StickerContent({
    required this.company,
    required this.phone,
    required this.title,
    this.model = '',
    this.serial = '',
    required this.code,
    required this.url,
  });

  factory StickerContent.forAppliance(
    HomeAppliance appliance, {
    required String company,
    required String phone,
    required String url,
  }) => StickerContent(
    company: _latin(company).isEmpty ? shopName : _latin(company),
    phone: phone.trim(),
    title: appliance.englishType,
    model: _latin(appliance.model),
    serial: _latin(appliance.serialNumber),
    code: appliance.id,
    url: url,
  );

  static StickerContent sample(String url) => StickerContent(
    company: shopName,
    phone: '(000) 000-0000',
    title: 'Test sticker',
    serial: 'SN 0123456789',
    code: 'test',
    url: url,
  );

  static String _latin(String value) =>
      value.replaceAll(RegExp(r'[^\x20-\x7E]'), '').trim();
}

/// Рисует наклейку в точках принтера (203 dpi ≈ 8 точек на мм). Одна и та
/// же отрисовка идёт и в превью, и в растр для печати.
class StickerRenderer {
  static const double dotsPerMm = 8;

  static Size sizeInDots(StickerPrinterSettings s) {
    final maxWidth = s.widthBytes * 8.0;
    return Size(
      math.min((s.labelWidthMm * dotsPerMm).roundToDouble(), maxWidth),
      (s.labelHeightMm * dotsPerMm).roundToDouble(),
    );
  }

  static Future<ui.Image> renderImage(
    StickerContent content,
    StickerPrinterSettings settings,
  ) async {
    final size = sizeInDots(settings);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & size);
    paint(canvas, size, content);
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(size.width.toInt(), size.height.toInt());
    } finally {
      picture.dispose();
    }
  }

  /// Готовый 1-битный растр для [StickerPrinterService.printRaster].
  static Future<(Uint8List, int)> renderRaster(
    StickerContent content,
    StickerPrinterSettings settings,
  ) async {
    final image = await renderImage(content, settings);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) throw StateError('sticker image has no pixels');
      final raster = StickerRaster.fromRgba(
        data.buffer.asUint8List(),
        image.width,
        image.height,
        widthBytes: settings.widthBytes,
      );
      return (raster, image.height);
    } finally {
      image.dispose();
    }
  }

  static void paint(Canvas canvas, Size size, StickerContent content) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final margin = 1.5 * dotsPerMm;
    final gap = 1.5 * dotsPerMm;
    final horizontal = size.width - size.height >= 15 * dotsPerMm;

    if (horizontal) {
      final header = _header(content);
      final painter = _fit(
        header,
        size.width - margin * 2,
        header.sizeMm * dotsPerMm,
        TextAlign.center,
      );
      painter.paint(canvas, Offset((size.width - painter.width) / 2, margin));
      final top = margin + painter.height + dotsPerMm * 0.6;
      painter.dispose();
      final qrSide = size.height - top - margin;
      _drawQr(
        canvas,
        content.url,
        Rect.fromLTWH(margin, top, qrSide, qrSide),
      );
      final x = margin + qrSide + gap;
      _drawLines(
        canvas,
        _lines(content, compact: false),
        Rect.fromLTWH(x, top, size.width - x - margin, qrSide),
        TextAlign.left,
      );
    } else {
      final qrSide = math.min(size.width - margin * 2, size.height * 0.58);
      _drawQr(
        canvas,
        content.url,
        Rect.fromLTWH((size.width - qrSide) / 2, margin * 0.6, qrSide, qrSide),
      );
      final top = margin * 0.6 + qrSide + dotsPerMm * 0.6;
      _drawLines(
        canvas,
        _lines(content, compact: true),
        Rect.fromLTWH(margin, top, size.width - margin * 2, size.height - top - margin * 0.6),
        TextAlign.center,
      );
    }
  }

  static _Line _header(StickerContent c) => _Line(c.company, 5.0, FontWeight.w900);

  static List<_Line> _lines(StickerContent c, {required bool compact}) => [
    if (compact) _header(c),
    _Line(c.title, 2.8, FontWeight.w800),
    if (!compact)
      _Line(
        c.model.isNotEmpty ? 'Model ${c.model}' : c.serial.isNotEmpty ? 'S/N ${c.serial}' : '',
        2.1,
        FontWeight.w500,
      ),
    if (c.phone.isNotEmpty) _Line(c.phone, 2.8, FontWeight.w800),
  ];

  static void _drawQr(Canvas canvas, String data, Rect box) {
    final QrImage image;
    try {
      image = QrImage(
        QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M),
      );
    } catch (_) {
      return;
    }
    const quiet = 2;
    final n = image.moduleCount;
    final module = (box.shortestSide / (n + quiet * 2)).floorToDouble();
    if (module < 1) return;
    final side = module * n;
    final left = (box.left + (box.width - side) / 2).roundToDouble();
    final top = (box.top + (box.height - side) / 2).roundToDouble();
    final ink = Paint()
      ..color = const Color(0xFF000000)
      ..isAntiAlias = false;
    for (var row = 0; row < n; row++) {
      for (var col = 0; col < n; col++) {
        if (!image.isDark(row, col)) continue;
        canvas.drawRect(
          Rect.fromLTWH(left + col * module, top + row * module, module, module),
          ink,
        );
      }
    }
  }

  /// Строки в рамке: размеры шрифта в мм, при нехватке места всё
  /// уменьшается пропорционально, по высоте — по центру.
  static void _drawLines(
    Canvas canvas,
    List<_Line> lines,
    Rect box,
    TextAlign align,
  ) {
    final visible = [
      for (final line in lines)
        if (line.text.trim().isNotEmpty) line,
    ];
    if (visible.isEmpty || box.width <= 0 || box.height <= 0) return;
    final spacing = 0.8 * dotsPerMm;
    final natural = visible.fold<double>(
          0,
          (sum, line) => sum + line.sizeMm * dotsPerMm * 1.18,
        ) +
        spacing * (visible.length - 1);
    final scale = math.min(1.0, box.height / natural);
    final painters = <TextPainter>[];
    var total = 0.0;
    for (final line in visible) {
      final painter = _fit(line, box.width, line.sizeMm * dotsPerMm * scale, align);
      painters.add(painter);
      total += painter.height;
    }
    total += spacing * scale * (visible.length - 1);
    var y = box.top + math.max(0.0, (box.height - total) / 2);
    for (final painter in painters) {
      final dx = align == TextAlign.center
          ? box.left + (box.width - painter.width) / 2
          : box.left;
      painter.paint(canvas, Offset(dx, y));
      y += painter.height + spacing * scale;
      painter.dispose();
    }
  }

  static TextPainter _fit(_Line line, double maxWidth, double fontSize, TextAlign align) {
    var size = fontSize;
    while (true) {
      final painter = TextPainter(
        text: TextSpan(
          text: line.text,
          style: TextStyle(
            color: const Color(0xFF000000),
            fontSize: size,
            fontWeight: line.weight,
            height: 1.1,
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: align,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: maxWidth);
      if (!painter.didExceedMaxLines || size <= fontSize * 0.65) return painter;
      painter.dispose();
      size -= 1;
    }
  }
}

class _Line {
  final String text;
  final double sizeMm;
  final FontWeight weight;

  const _Line(this.text, this.sizeMm, this.weight);
}

/// Превью наклейки в масштабе экрана (та же отрисовка, что уйдёт в принтер).
class StickerPreview extends StatelessWidget {
  final StickerContent content;
  final StickerPrinterSettings settings;
  final double maxWidth;

  const StickerPreview({
    super.key,
    required this.content,
    required this.settings,
    this.maxWidth = 320,
  });

  @override
  Widget build(BuildContext context) {
    final dots = StickerRenderer.sizeInDots(settings);
    final width = math.min(maxWidth, MediaQuery.sizeOf(context).width - 48);
    final height = width * dots.height / dots.width;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.black26),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        height: height,
        child: CustomPaint(painter: _StickerPainter(content, dots)),
      ),
    );
  }
}

class _StickerPainter extends CustomPainter {
  final StickerContent content;
  final Size dots;

  _StickerPainter(this.content, this.dots);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / dots.width);
    StickerRenderer.paint(canvas, dots, content);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _StickerPainter old) =>
      old.content != content || old.dots != dots;
}
