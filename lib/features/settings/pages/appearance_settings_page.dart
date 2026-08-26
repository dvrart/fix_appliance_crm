import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../core/ui_scale.dart';
import '../widgets/settings_ui.dart';

class AppearanceSettingsPage extends StatelessWidget {
  const AppearanceSettingsPage({super.key});

  String _scaleLabel(double scale) {
    if ((scale - 0.85).abs() < 0.01) return 'Мельче'.tr;
    if ((scale - 1.0).abs() < 0.01) return 'Обычный'.tr;
    if ((scale - 1.15).abs() < 0.01) return 'Крупнее'.tr;
    if ((scale - 1.3).abs() < 0.01) return 'Крупный'.tr;
    return '${(scale * 100).round()}%';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppUiSettings.instance,
      builder: (context, _) {
        final ui = AppUiSettings.instance;
        return SettingsPageScaffold(
          title: 'Экран и шрифт'.tr,
          actions: [
            TextButton(
              onPressed: ui.reset,
              child: Text(
                'Сбросить'.tr,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
          body: ListView(
            padding: const EdgeInsets.only(top: 20, bottom: 40),
            children: [
              _sectionTitle('Масштаб экрана'.tr),
              SettingsGroup(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Text(
                      'Увеличивает нижнюю панель и элементы на всех экранах.'.tr,
                      style: const TextStyle(color: Colors.black54),
                    ),
                  ),
                  Slider(
                    value: ui.scale,
                    min: AppUiSettings.minScale,
                    max: AppUiSettings.maxScale,
                    divisions: 11,
                    label: _scaleLabel(ui.scale),
                    onChanged: ui.setScale,
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final preset in AppUiSettings.presets)
                          ChoiceChip(
                            label: Text(_scaleLabel(preset)),
                            selected: (ui.scale - preset).abs() < 0.02,
                            onSelected: (_) => ui.setScale(preset),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              _sectionTitle('Стиль текста'.tr),
              SettingsGroup(
                children: [
                  RadioGroup<String>(
                    groupValue: ui.fontFamily,
                    onChanged: (value) {
                      if (value != null) ui.setFontFamily(value);
                    },
                    child: Column(
                      children: [
                        for (final entry in AppUiSettings.fonts.entries)
                          RadioListTile<String>(
                            title: Text(
                              entry.value.tr,
                              style: AppUiSettings.previewStyle(
                                entry.key,
                                base: Theme.of(context).textTheme,
                              ),
                            ),
                            value: entry.key,
                            activeColor: AppColors.primary,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 16, 8),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: AppColors.primary,
          fontSize: 13,
        ),
      ),
    );
  }
}
