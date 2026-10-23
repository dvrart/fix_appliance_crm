import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../core/ui_scale.dart';
import '../../../core/utils/app_time_picker.dart';
import '../widgets/settings_ui.dart';

enum _AppearanceSection { hub, scale, font, night, bars }

class AppearanceSettingsPage extends StatefulWidget {
  const AppearanceSettingsPage({super.key}) : _sectionIndex = 0;

  const AppearanceSettingsPage._at(this._sectionIndex, {super.key});

  final int _sectionIndex;

  _AppearanceSection get _section => _AppearanceSection
      .values[_sectionIndex.clamp(0, _AppearanceSection.values.length - 1)];

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
      // Ночной режим и цвета шапки/низа сохраняются сразу по нажатию: кнопка
      // «Сохранить» для них — лишний шаг, а предпросмотр и есть результат.
      case _AppearanceSection.night:
      case _AppearanceSection.bars:
        return false;
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
                        title: context.tr('Ночной режим', 'Night mode'),
                        subtitle: _nightLabel(ui),
                        icon: Icons.nightlight_round,
                        color: const Color(0xFF3F51B5),
                        active: ui.darkNow,
                        onTap: () => _open(_AppearanceSection.night),
                      ),
                      SettingsHubTile(
                        title: context.tr('Шапка и низ', 'Header & footer'),
                        subtitle: _barColorLabel(ui),
                        icon: Icons.palette_outlined,
                        color: ui.primaryColor,
                        onTap: () => _open(_AppearanceSection.bars),
                      ),
                      SettingsHubTile(
                        title: 'Сбросить'.tr,
                        subtitle: '100%'.tr,
                        icon: Icons.restart_alt,
                        color: Colors.blueGrey,
                        onTap: () {
                          ui.previewAppearanceReset();
                          ui.setPrimary(
                            const Color(AppUiSettings.defaultPrimary),
                          );
                          ui.setFooterRaw(0);
                        },
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
                    style: TextStyle(color: AppColors.inkMuted),
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
          case _AppearanceSection.night:
            return SettingsPageScaffold(
              title: context.tr('Ночной режим', 'Night mode'),
              body: ListView(
                padding: const EdgeInsets.only(top: 16, bottom: 32),
                children: [
                  SettingsGroup(
                    children: [
                      SwitchListTile(
                        value: ui.nightMode,
                        onChanged: ui.setNightMode,
                        secondary: const Icon(
                          Icons.nightlight_round,
                          color: Color(0xFF3F51B5),
                        ),
                        title: Text(
                          context.tr('Включить сейчас', 'Turn on now'),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        subtitle: Text(
                          context.tr(
                            'Тёмный экран, пока не выключите.',
                            'Dark screen until you turn it off.',
                          ),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      const Divider(height: 1, indent: 64),
                      SwitchListTile(
                        value: ui.nightAuto,
                        onChanged: ui.setNightAuto,
                        secondary: const Icon(
                          Icons.schedule,
                          color: Color(0xFF00897B),
                        ),
                        title: Text(
                          context.tr('По расписанию', 'On a schedule'),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        subtitle: Text(
                          context.tr(
                            'Включается и выключается сам в заданные часы.',
                            'Turns itself on and off at the set hours.',
                          ),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                  if (ui.nightAuto)
                    SettingsGroup(
                      children: [
                        SettingsRow(
                          title: context.tr('Темнеет в', 'Dark from'),
                          subtitle: _time(ui.nightFromTime),
                          icon: Icons.bedtime_outlined,
                          iconColor: const Color(0xFF3F51B5),
                          onTap: () => _pickNight(ui, from: true),
                        ),
                        SettingsRow(
                          title: context.tr('Светлеет в', 'Light from'),
                          subtitle: _time(ui.nightToTime),
                          icon: Icons.wb_sunny_outlined,
                          iconColor: Colors.orange,
                          showDivider: false,
                          onTap: () => _pickNight(ui, from: false),
                        ),
                      ],
                    ),
                  _buildNightShadeSection(ui),
                  _buildHeaderFooterSection(ui),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                    child: Text(
                      context.tr(
                        'Тёмными становятся фон экранов, карточки, окна, списки и поля ввода.',
                        'Screen backgrounds, cards, dialogs, lists and input fields go dark.',
                      ),
                      style: TextStyle(fontSize: 13, color: AppColors.inkMuted),
                    ),
                  ),
                ],
              ),
            );
          case _AppearanceSection.bars:
            return SettingsPageScaffold(
              title: context.tr('Шапка и нижняя панель', 'Header & footer'),
              body: ListView(
                padding: const EdgeInsets.only(top: 16, bottom: 32),
                children: [
                  _buildHeaderFooterSection(ui),
                ],
              ),
            );
        }
      },
    );
  }

  Widget _buildNightShadeSection(AppUiSettings ui) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 10),
            child: Text(
              context.tr('Насколько тёмный экран', 'How dark'),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 15,
                color: AppColors.ink,
              ),
            ),
          ),
          Row(
            children: [
              for (var i = 0; i < AppUiSettings.nightShades.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: _buildShadeCard(ui, AppUiSettings.nightShades[i]),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildShadeCard(AppUiSettings ui, NightShadePreset preset) {
    final selected = ui.nightLevel == preset.id;
    return Material(
      color: preset.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => ui.setNightLevel(preset.id, enableNow: true),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? AppColors.accent : preset.border,
              width: selected ? 2.2 : 1.2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 36,
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: preset.card,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: preset.border),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: selected ? AppColors.accent : preset.inkMuted,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Container(
                        height: 6,
                        decoration: BoxDecoration(
                          color: preset.ink.withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                    if (selected) ...[
                      const SizedBox(width: 4),
                      Icon(
                        Icons.check_circle,
                        size: 16,
                        color: AppColors.accent,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                context.tr(preset.labelRu, preset.labelEn),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12.5,
                  height: 1.15,
                  color: preset.ink,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                context.tr(preset.subtitleRu, preset.subtitleEn),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.15,
                  color: preset.inkMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderFooterSection(AppUiSettings ui) {
    final currentPrimary = ui.primaryColor.toARGB32();
    final currentFooter = ui.footerRaw;
    return SettingsGroup(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: ui.primaryColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.border),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      context.tr('Шапка (Header)', 'Header'),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final item in AppUiSettings.barColors)
                    _buildBarColorChip(
                      label: context.tr(item.ru, item.en),
                      color: Color(item.argb),
                      selected: currentPrimary == item.argb,
                      onTap: () => ui.setPrimary(Color(item.argb)),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Divider(height: 1, color: AppColors.border),
              const SizedBox(height: 14),
              Row(
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: ui.footerColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.border),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      context.tr('Нижняя панель (Footer)', 'Footer'),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildBarColorChip(
                    label: context.tr('Как шапка', 'Same as header'),
                    color: ui.primaryColor,
                    selected: currentFooter == 0,
                    onTap: () => ui.setFooterRaw(0),
                  ),
                  for (final item in AppUiSettings.barColors)
                    _buildBarColorChip(
                      label: context.tr(item.ru, item.en),
                      color: Color(item.argb),
                      selected: currentFooter == item.argb,
                      onTap: () => ui.setFooterRaw(item.argb),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBarColorChip({
    required String label,
    required Color color,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected ? AppColors.selectedCard : AppColors.cardMuted,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.border,
              width: selected ? 1.8 : 1.0,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white38, width: 1),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: AppColors.ink,
                ),
              ),
              if (selected) ...[
                const SizedBox(width: 4),
                Icon(Icons.check, size: 14, color: AppColors.ink),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _barColorLabel(AppUiSettings ui) {
    final argb = ui.primaryColor.toARGB32();
    for (final item in AppUiSettings.barColors) {
      if (item.argb == argb) {
        return context.tr(item.ru, item.en);
      }
    }
    return context.tr('Свой', 'Custom');
  }

  static String _time(TimeOfDay time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String _nightLabel(AppUiSettings ui) {
    final shade = ui.nightShade;
    final shadeName = context.tr(shade.labelRu, shade.labelEn);
    if (ui.nightMode) return shadeName;
    if (ui.nightAuto) {
      return '${_time(ui.nightFromTime)} – ${_time(ui.nightToTime)}';
    }
    return context.tr('Выключен', 'Off');
  }

  Future<void> _pickNight(AppUiSettings ui, {required bool from}) async {
    final picked = await showAppTimePicker(
      context: context,
      initialTime: from ? ui.nightFromTime : ui.nightToTime,
      helpText: from
          ? context.tr('Когда темнеет', 'When it gets dark')
          : context.tr('Когда светлеет', 'When it gets light'),
    );
    if (picked == null) return;
    await ui.setNightWindow(from: from ? picked : null, to: from ? null : picked);
  }
}
