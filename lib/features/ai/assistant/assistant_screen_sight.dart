import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Снимок текущего UI для голосового ассистента.
class AssistantScreenSight {
  static final GlobalKey boundaryKey = GlobalKey();

  static Future<Uint8List?> capture({double pixelRatio = 0.55}) async {
    final context = boundaryKey.currentContext;
    if (context == null) return null;
    final object = context.findRenderObject();
    if (object is! RenderRepaintBoundary) return null;
    if (!object.hasSize || object.size.isEmpty) return null;
    try {
      final image = await object.toImage(pixelRatio: pixelRatio);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data?.buffer.asUint8List();
    } catch (e) {
      debugPrint('AssistantScreenSight: $e');
      return null;
    }
  }
}
