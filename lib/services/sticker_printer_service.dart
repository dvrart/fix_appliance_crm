import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Один шаг печати: байты для принтера и пауза после них.
class PrinterStep {
  final Uint8List bytes;
  final int delayMs;

  const PrinterStep(this.bytes, {this.delayMs = 0});

  Map<String, Object> toChannel() => {'data': bytes, 'delayMs': delayMs};
}

/// Протокол Phomemo M-серии (M200 / M250 / M221 / M260 / M03 / T02):
/// ESC/POS-растр по BLE. Последовательность — как у открытого драйвера
/// phomymo, где M250 описан как «M-series, 72 байта в строке, по центру»:
/// `ESC @` → нагрев `ESC 7` → плотность `GS |` → растр `GS v 0` → подача
/// `ESC J`. Паузы между шагами — оттуда же: без них принтер теряет начало.
/// Заголовок `GS v 0` — отдельной записью, как у phomymo. Ширина строки —
/// ровно 72 байта: с 76 M250 молча ничего не печатает (phomymo #17).
class PhomemoCommands {
  /// Плотность 1–8 → время нагрева для `ESC 7` (больше — темнее).
  static const List<int> heatTimes = [40, 60, 80, 100, 120, 140, 160, 200];

  static List<PrinterStep> build({
    required Uint8List raster,
    required int widthBytes,
    required int heightLines,
    int density = 6,
    int feedDots = 32,
  }) {
    final level = density.clamp(1, 8);
    final header = <int>[
      0x1d, 0x76, 0x30, 0x00,
      widthBytes & 0xff, (widthBytes >> 8) & 0xff,
      heightLines & 0xff, (heightLines >> 8) & 0xff,
    ];
    return [
      PrinterStep(Uint8List.fromList(const [0x1b, 0x40]), delayMs: 100),
      PrinterStep(
        Uint8List.fromList([0x1b, 0x37, 0x07, heatTimes[level - 1], 0x02]),
        delayMs: 30,
      ),
      PrinterStep(Uint8List.fromList([0x1d, 0x7c, level]), delayMs: 50),
      PrinterStep(Uint8List.fromList(header)),
      PrinterStep(raster, delayMs: 300),
      PrinterStep(
        Uint8List.fromList([0x1b, 0x4a, feedDots.clamp(0, 255)]),
        delayMs: 800,
      ),
    ];
  }
}

/// RGBA-картинка наклейки → 1-битный растр шириной в печатную голову.
/// Старший бит — левая точка, единица — чёрная точка. Наклейка уже головы
/// встаёт по центру (так рулон стоит в M250).
class StickerRaster {
  static Uint8List fromRgba(
    Uint8List rgba,
    int width,
    int height, {
    required int widthBytes,
    int threshold = 150,
    String align = 'center',
  }) {
    final rowBytes = (width + 7) >> 3;
    final usable = math.min(rowBytes, widthBytes);
    final offset = switch (align) {
      'left' => 0,
      'right' => widthBytes - usable,
      _ => (widthBytes - usable) ~/ 2,
    };
    final maxX = math.min(width, usable * 8);
    final out = Uint8List(widthBytes * height);
    for (var y = 0; y < height; y++) {
      final rowOut = y * widthBytes + offset;
      final rowIn = y * width * 4;
      for (var x = 0; x < maxX; x++) {
        final i = rowIn + x * 4;
        final alpha = rgba[i + 3] / 255.0;
        final lum = (0.299 * rgba[i] + 0.587 * rgba[i + 1] + 0.114 * rgba[i + 2]) *
                alpha +
            255 * (1 - alpha);
        if (lum < threshold) out[rowOut + (x >> 3)] |= 0x80 >> (x & 7);
      }
    }
    return out;
  }
}

/// Принтер, найденный при поиске по Bluetooth.
class BlePrinter {
  final String id;
  final String name;
  final int rssi;

  const BlePrinter({required this.id, required this.name, this.rssi = 0});

  /// Похоже на Phomemo по имени — такие показываем первыми.
  bool get looksLikePhomemo {
    final n = name.toUpperCase();
    return n.startsWith('M2') ||
        n.startsWith('M0') ||
        n.startsWith('M1') ||
        n.startsWith('T02') ||
        n.contains('PHOMEMO');
  }
}

/// Настройки принтера наклеек — свои у каждого телефона (SharedPreferences),
/// поэтому в Firestore их нет.
class StickerPrinterSettings {
  /// Ширина печатной строки в байтах по моделям M-серии (данные phomymo).
  static const Map<String, int> models = {
    'M250': 72,
    'M200': 76,
    'M221': 72,
    'M260': 72,
    'M03': 54,
    'T02': 48,
  };

  /// Размеры наклеек, мм. 50×30 — по умолчанию: QR и текст влезают крупно.
  static const List<(double, double)> labelSizes = [
    (50, 30),
    (40, 30),
    (60, 40),
    (50, 50),
    (70, 40),
  ];

  final String printerId;
  final String printerName;
  final String model;
  final double labelWidthMm;
  final double labelHeightMm;
  final int density;
  final int feedDots;

  const StickerPrinterSettings({
    this.printerId = '',
    this.printerName = '',
    this.model = 'M250',
    this.labelWidthMm = 50,
    this.labelHeightMm = 30,
    this.density = 6,
    this.feedDots = 32,
  });

  int get widthBytes => models[model] ?? 72;
  bool get hasPrinter => printerId.isNotEmpty;

  StickerPrinterSettings copyWith({
    String? printerId,
    String? printerName,
    String? model,
    double? labelWidthMm,
    double? labelHeightMm,
    int? density,
    int? feedDots,
  }) => StickerPrinterSettings(
    printerId: printerId ?? this.printerId,
    printerName: printerName ?? this.printerName,
    model: model ?? this.model,
    labelWidthMm: labelWidthMm ?? this.labelWidthMm,
    labelHeightMm: labelHeightMm ?? this.labelHeightMm,
    density: density ?? this.density,
    feedDots: feedDots ?? this.feedDots,
  );
}

class StickerPrinterException implements Exception {
  final String message;
  const StickerPrinterException(this.message);

  @override
  String toString() => message;
}

/// Печать наклеек паспорта на Phomemo M250 по Bluetooth LE.
///
/// Сам BLE — в нативе (`StickerPrinterBle.kt`, канал
/// `fix_appliance/sticker_printer`): сервис `ff00`, запись в `ff02`.
/// Здесь — настройки и сборка байтов.
class StickerPrinterService {
  StickerPrinterService._();

  static const MethodChannel _channel = MethodChannel(
    'fix_appliance/sticker_printer',
  );

  static const _kId = 'sticker_printer_id';
  static const _kName = 'sticker_printer_name';
  static const _kModel = 'sticker_printer_model';
  static const _kWidth = 'sticker_label_w';
  static const _kHeight = 'sticker_label_h';
  static const _kDensity = 'sticker_density';
  static const _kFeed = 'sticker_feed';

  static Future<StickerPrinterSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    const d = StickerPrinterSettings();
    final model = prefs.getString(_kModel) ?? d.model;
    return StickerPrinterSettings(
      printerId: prefs.getString(_kId) ?? '',
      printerName: prefs.getString(_kName) ?? '',
      model: StickerPrinterSettings.models.containsKey(model) ? model : d.model,
      labelWidthMm: prefs.getDouble(_kWidth) ?? d.labelWidthMm,
      labelHeightMm: prefs.getDouble(_kHeight) ?? d.labelHeightMm,
      density: (prefs.getInt(_kDensity) ?? d.density).clamp(1, 8),
      feedDots: (prefs.getInt(_kFeed) ?? d.feedDots).clamp(0, 255),
    );
  }

  static Future<void> saveSettings(StickerPrinterSettings s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kId, s.printerId);
    await prefs.setString(_kName, s.printerName);
    await prefs.setString(_kModel, s.model);
    await prefs.setDouble(_kWidth, s.labelWidthMm);
    await prefs.setDouble(_kHeight, s.labelHeightMm);
    await prefs.setInt(_kDensity, s.density);
    await prefs.setInt(_kFeed, s.feedDots);
  }

  /// Bluetooth-разрешения Android 12+ и геолокация для старых версий
  /// (без неё Android 11 и ниже не отдаёт результаты поиска BLE).
  static Future<void> ensurePermissions() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    final scan = statuses[Permission.bluetoothScan];
    final connect = statuses[Permission.bluetoothConnect];
    if (scan?.isPermanentlyDenied == true || connect?.isPermanentlyDenied == true) {
      throw const StickerPrinterException(
        'Нет доступа к Bluetooth. Разрешите «Устройства поблизости» в настройках приложения.',
      );
    }
  }

  static Future<List<BlePrinter>> scan({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    await ensurePermissions();
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('scan', {
        'timeoutMs': timeout.inMilliseconds,
      });
      final list = <BlePrinter>[
        for (final item in raw ?? const [])
          if (item is Map)
            BlePrinter(
              id: (item['id'] ?? '').toString(),
              name: (item['name'] ?? '').toString(),
              rssi: (item['rssi'] as num?)?.toInt() ?? 0,
            ),
      ];
      list.sort((a, b) {
        if (a.looksLikePhomemo != b.looksLikePhomemo) {
          return a.looksLikePhomemo ? -1 : 1;
        }
        return b.rssi.compareTo(a.rssi);
      });
      return list;
    } on PlatformException catch (e) {
      throw StickerPrinterException(_friendly(e));
    }
  }

  /// Отправить готовый растр на принтер из настроек.
  static Future<void> printRaster({
    required Uint8List raster,
    required int heightLines,
    StickerPrinterSettings? settings,
  }) async {
    final s = settings ?? await loadSettings();
    if (!s.hasPrinter) {
      throw const StickerPrinterException(
        'Принтер не выбран. Настройки → Принтер наклеек.',
      );
    }
    await ensurePermissions();
    final steps = PhomemoCommands.build(
      raster: raster,
      widthBytes: s.widthBytes,
      heightLines: heightLines,
      density: s.density,
      feedDots: s.feedDots,
    );
    try {
      await _channel.invokeMethod<bool>('print', {
        'id': s.printerId,
        'steps': [for (final step in steps) step.toChannel()],
        'chunkSize': 128,
        'chunkDelayMs': 20,
      });
    } on PlatformException catch (e) {
      throw StickerPrinterException(_friendly(e));
    }
  }

  static String _friendly(PlatformException e) {
    switch (e.code) {
      case 'off':
        return 'Включите Bluetooth.';
      case 'permission':
        return 'Нет доступа к Bluetooth. Разрешите «Устройства поблизости».';
      case 'busy':
        return 'Принтер ещё печатает предыдущую наклейку.';
      case 'unavailable':
        return 'На телефоне нет Bluetooth LE.';
      default:
        final text = (e.message ?? '').trim();
        return text.isEmpty ? 'Принтер не ответил.' : text;
    }
  }
}
