import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../core/ui_scale.dart';
import '../widgets/settings_ui.dart';

enum _AppearanceSection { hub, scale, font }

class AppearanceSettingsPage extends StatefulWidget {
  const AppearanceSettingsPage({super.key}) : _sectionIndex = 0;

  const AppearanceSettingsPage._at(this._sectionIndex, {super.key});

  final int _sectionIndex;

  _AppearanceSection get _section =>
      _AppearanceSection.values[_sectionIndex.clamp(0, 2)];

  @override
  State<AppearanceSettingsPage> createState() => _AppearanceSettingsPageState();
}

class _AppearanceSettingsPageState extends State<AppearanceSettingsPage> {
  String _scaleLabel(double scale) {
    if ((scale - 0.85).abs() < 0.01) return 'Мельче'.tr;
    if ((scale - 1.0).abs() < 0.01) return 'Обычный'.tr;
    if ((scale - 1.15).abs() < 0.01) return 'Крупнее'.tr;
    if ((scale - 1.3).abs() < 0.01) return 'Крупный'.tr;
    return '${(scale * 100).round()}%';
  }

  void _open(_AppearanceSection section) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AppearanceSettingsPage._at(section.index),
      ),
    );
  }

  bool get _dirty {
    final ui = AppUiSettings.instance;
    switch (widget._section) {
      case _AppearanceSection.hub:
      case _AppearanceSection.scale:
      case _AppearanceSection.font:
        return ui.appearanceDirty;
    }
  }

  Future<bool> _save() async {
    await AppUiSettings.instance.persistAppearance();
    if (mounted) setState(() {});
    return true;
  }

  void _discard() {
    AppUiSettings.instance.restorePersistedAppearance();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppUiSettings.instance,
      builder: (context, _) {
        final ui = AppUiSettings.instance;
        switch (widget._section) {
          case _AppearanceSection.hub:
            return SettingsPageScaffold(
              title: 'Экран и шрифт'.tr,
              dirty: _dirty,
              onSave: _save,
              onDiscard: _discard,
              body: ListView(
                padding: const EdgeInsets.only(top: 12, bottom: 32),
                children: [
                  SettingsTileSection(
                    title: 'Экран'.tr,
                    tiles: [
                      SettingsHubTile(
                        title: 'Масштаб'.tr,
                        subtitle: _scaleLabel(ui.scale),
                        icon: Icons.format_size,
                        color: Colors.orange,
                        onTap: () => _open(_AppearanceSection.scale),
                      ),
                      SettingsHubTile(
                        title: 'Шрифт'.tr,
                        subtitle: (AppUiSettings.fonts[ui.fontFamily] ?? '')
                            .toString()
                            .tr,
                        icon: Icons.text_fields,
                        color: Colors.indigo,
                        onTap: () => _open(_AppearanceSection.font),
                      ),
                      SettingsHubTile(
                        title: 'Сбросить'.tr,
                        subtitle: '100%'.tr,
                        icon: Icons.restart_alt,
                        color: Colors.blueGrey,
                        onTap: ui.previewAppearanceReset,
                      ),
                    ],
                  ),
                ],
              ),
            );
          case _AppearanceSection.scale:
            return SettingsPageScaffold(
              title: 'Масштаб экрана'.tr,
              dirty: _dirty,
              onSave: _save,
              onDiscard: _discard,
              body: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  Text(
                    'Увеличивает нижнюю панель и элементы на всех экранах.'.tr,
                    style: const TextStyle(color: Colors.black54),
                  ),
                  Slider(
                    value: ui.scale,
                    min: AppUiSettings.minScale,
                    max: AppUiSettings.maxScale,
                    divisions: 11,
                    label: _scaleLabel(ui.scale),
                    onChanged: ui.previewScale,
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final preset in AppUiSettings.presets)
                        ChoiceChip(
                          label: Text(_scaleLabel(preset)),
                          selected: (ui.scale - preset).abs() < 0.02,
                          onSelected: (_) => ui.previewScale(preset),
                        ),
                    ],
                  ),
                ],
              ),
            );
          case _AppearanceSection.font:
            return SettingsPageScaffold(
              title: 'Стиль текста'.tr,
              dirty: _dirty,
              onSave: _save,
              onDiscard: _discard,
              body: ListView(
                padding: const EdgeInsets.only(top: 12, bottom: 32),
                children: [
                  SettingsTileSection(
                    title: 'Шрифт'.tr,
                    tiles: [
                      for (final entry in AppUiSettings.fonts.entries)
                        SettingsHubTile(
                          title: entry.value.tr,
                          subtitle: entry.key == ui.fontFamily ? '✓' : '',
                          icon: Icons.font_download_outlined,
                          color: AppColors.primary,
                          active: entry.key == ui.fontFamily,
                          onTap: () => ui.previewFontFamily(entry.key),
                        ),
                    ],
                  ),
                ],
              ),
            );
        }
      },
    );
  }
}
