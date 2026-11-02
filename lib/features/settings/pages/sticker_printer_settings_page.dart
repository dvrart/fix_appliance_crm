import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../services/care_plan_service.dart';
import '../../../services/sticker_printer_service.dart';
import '../../care_plan/sticker_renderer.dart';
import '../widgets/settings_ui.dart';

/// Настройки → Принтер наклеек (Phomemo M250 по Bluetooth LE). Всё
/// сохраняется сразу и только на этом телефоне.
class StickerPrinterSettingsPage extends StatefulWidget {
  const StickerPrinterSettingsPage({super.key});

  @override
  State<StickerPrinterSettingsPage> createState() =>
      _StickerPrinterSettingsPageState();
}

class _StickerPrinterSettingsPageState
    extends State<StickerPrinterSettingsPage> {
  StickerPrinterSettings _s = const StickerPrinterSettings();
  bool _loading = true;
  bool _scanning = false;
  bool _printing = false;
  List<BlePrinter> _found = const [];
  String _status = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final s = await StickerPrinterService.loadSettings();
    if (!mounted) return;
    setState(() {
      _s = s;
      _loading = false;
    });
  }

  Future<void> _update(StickerPrinterSettings next) async {
    setState(() => _s = next);
    await StickerPrinterService.saveSettings(next);
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _status = 'Ищу принтер… Включите его и держите рядом.'.tr;
      _found = const [];
    });
    try {
      final found = await StickerPrinterService.scan();
      if (!mounted) return;
      setState(() {
        _found = found;
        _status = found.isEmpty
            ? 'Ничего не нашлось. Принтер включён? Bluetooth на телефоне включён?'.tr
            : '';
      });
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _pick(BlePrinter printer) async {
    final upper = printer.name.toUpperCase();
    final model = StickerPrinterSettings.models.keys.firstWhere(
      upper.startsWith,
      orElse: () => _s.model,
    );
    await _update(
      _s.copyWith(printerId: printer.id, printerName: printer.name, model: model),
    );
    if (mounted) {
      setState(() {
        _found = const [];
        _status = '${'Выбран'.tr}: ${printer.name}';
      });
    }
  }

  Future<void> _testPrint() async {
    if (_printing) return;
    setState(() {
      _printing = true;
      _status = 'Печатаю тестовую наклейку…'.tr;
    });
    try {
      final content = StickerContent.sample(CarePlanService.passportUrl('test'));
      final (raster, height) = await StickerRenderer.renderRaster(content, _s);
      await StickerPrinterService.printRaster(
        raster: raster,
        heightLines: height,
        settings: _s,
      );
      if (mounted) setState(() => _status = 'Готово. Проверьте наклейку.'.tr);
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: context.tr('Принтер наклеек', 'Sticker printer'),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: AppColors.accent))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                Text(
                  'Phomemo M250 печатает наклейки паспорта техники по Bluetooth. В настройках Android принтер сопрягать не нужно — приложение находит его само.'
                      .tr,
                  style: TextStyle(color: AppColors.inkMuted, height: 1.35),
                ),
                const SizedBox(height: 14),
                Card(
                  child: ListTile(
                    leading: Icon(
                      _s.hasPrinter ? Icons.print : Icons.print_disabled,
                      color: _s.hasPrinter ? Colors.green : Colors.grey,
                    ),
                    title: Text(
                      _s.hasPrinter ? _s.printerName : 'Принтер не выбран'.tr,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text(_s.hasPrinter ? _s.printerId : 'Нажмите «Найти принтер»'.tr),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: _scanning ? null : _scan,
                    icon: _scanning
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.bluetooth_searching),
                    label: Text(_scanning ? 'Ищу…'.tr : 'Найти принтер'.tr),
                  ),
                ),
                for (final printer in _found)
                  ListTile(
                    leading: Icon(
                      printer.looksLikePhomemo ? Icons.print : Icons.bluetooth,
                      color: printer.looksLikePhomemo ? AppColors.primaryOnCard : Colors.grey,
                    ),
                    title: Text(printer.name),
                    subtitle: Text('${printer.id} · ${printer.rssi} dBm'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _pick(printer),
                  ),
                if (_status.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      _status,
                      style: TextStyle(color: AppColors.ink, fontWeight: FontWeight.w600),
                    ),
                  ),
                const SizedBox(height: 20),
                Text('Модель'.tr, style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final model in StickerPrinterSettings.models.keys)
                      ChoiceChip(
                        label: Text(model),
                        selected: _s.model == model,
                        onSelected: (_) => _update(_s.copyWith(model: model)),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text('Размер наклейки, мм'.tr, style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final (w, h) in StickerPrinterSettings.labelSizes)
                      ChoiceChip(
                        label: Text('${w.round()}×${h.round()}'),
                        selected: _s.labelWidthMm == w && _s.labelHeightMm == h,
                        onSelected: (_) => _update(
                          _s.copyWith(labelWidthMm: w, labelHeightMm: h),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  '${'Плотность печати'.tr}: ${_s.density}',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                Slider(
                  value: _s.density.toDouble(),
                  min: 1,
                  max: 8,
                  divisions: 7,
                  label: '${_s.density}',
                  onChanged: (v) => setState(() => _s = _s.copyWith(density: v.round())),
                  onChangeEnd: (v) => _update(_s.copyWith(density: v.round())),
                ),
                Text(
                  '${'Подача после печати'.tr}: ${(_s.feedDots / 8).toStringAsFixed(1)} ${'мм'.tr}',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                Slider(
                  value: _s.feedDots.toDouble(),
                  min: 0,
                  max: 120,
                  divisions: 30,
                  onChanged: (v) => setState(() => _s = _s.copyWith(feedDots: v.round())),
                  onChangeEnd: (v) => _update(_s.copyWith(feedDots: v.round())),
                ),
                Text(
                  'Виниловые водостойкие наклейки бледнее бумажных — если QR плохо читается, прибавьте плотность. Если следующая наклейка печатается со сдвигом, подберите подачу.'
                      .tr,
                  style: TextStyle(color: AppColors.inkMuted, fontSize: 12, height: 1.35),
                ),
                const SizedBox(height: 16),
                Center(
                  child: StickerPreview(
                    content: StickerContent.sample(CarePlanService.passportUrl('test')),
                    settings: _s,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 48,
                  child: OutlinedButton.icon(
                    onPressed: !_s.hasPrinter || _printing ? null : _testPrint,
                    icon: const Icon(Icons.print_outlined),
                    label: Text('Тестовая наклейка'.tr),
                  ),
                ),
              ],
            ),
    );
  }
}
