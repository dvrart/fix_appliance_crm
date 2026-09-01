import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../services/settings_service.dart';
import '../widgets/settings_ui.dart';
import 'secretary_learn_page.dart';

enum _SecretarySection { hub, pickup }

/// Кто берёт трубку. Это не Purish в приложении.
class AiSecretarySettingsPage extends StatefulWidget {
  const AiSecretarySettingsPage({super.key}) : _sectionIndex = 0;

  const AiSecretarySettingsPage._at(this._sectionIndex, {super.key});

  final int _sectionIndex;

  _SecretarySection get _section =>
      _SecretarySection.values[_sectionIndex.clamp(0, 1)];

  @override
  State<AiSecretarySettingsPage> createState() =>
      _AiSecretarySettingsPageState();
}

class _AiSecretarySettingsPageState extends State<AiSecretarySettingsPage> {
  bool _loading = true;
  bool _saving = false;
  bool _enabled = true;
  int _timeout = SettingsService.defaultAiAnswerTimeoutSeconds;
  AiVoiceProfile? _profile;
  String _savedFp = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _open(_SecretarySection section) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AiSecretarySettingsPage._at(section.index),
      ),
    ).then((_) {
      if (mounted && widget._section == _SecretarySection.hub) _load();
    });
  }

  Future<void> _load() async {
    final profile = await SettingsService.loadAiVoiceProfile();
    if (!mounted) return;
    setState(() {
      _profile = profile;
      _enabled = profile.enabled;
      _timeout = profile.timeoutSeconds;
      _loading = false;
      _savedFp = _fp();
    });
  }

  String _fp() => '$_timeout|$_enabled';

  bool get _dirty => !_loading && _fp() != _savedFp;

  Future<bool> _save() async {
    final current = _profile;
    if (current == null) return false;
    setState(() => _saving = true);
    await SettingsService.saveAiVoiceProfile(
      AiVoiceProfile(
        enabled: _enabled,
        timeoutSeconds: _timeout,
        greeting: current.greeting,
        collectName: current.collectName,
        collectAddress: current.collectAddress,
        collectWhen: current.collectWhen,
        collectAppliance: current.collectAppliance,
        collectLocation: current.collectLocation,
        collectPhoto: current.collectPhoto,
        noPrice: current.noPrice,
        serviceArea: current.serviceArea,
        angryCallbackMinutes: current.angryCallbackMinutes,
        extraRules: current.extraRules,
        instructions: current.instructions,
        learnedRules: current.learnedRules,
        learningEnabled: current.learningEnabled,
      ),
    );
    if (!mounted) return false;
    setState(() {
      _saving = false;
      _savedFp = _fp();
    });
    return true;
  }

  Future<void> _setEnabled(bool value) async {
    setState(() => _enabled = value);
    await SettingsService.updateConfig('aiAnswerEnabled', value);
    if (!mounted) return;
    setState(() => _savedFp = _fp());
  }

  String _pickupSubtitle() {
    if (!_enabled) return context.tr('Выключен', 'Off');
    if (_timeout <= 0) {
      return context.tr('Сразу', 'Immediately');
    }
    return '${_timeout}s';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return SettingsPageScaffold(
        title: context.tr('Секретарь на звонках', 'Phone secretary'),
        body: Center(child: CircularProgressIndicator(color: AppColors.accent)),
      );
    }
    switch (widget._section) {
      case _SecretarySection.hub:
        return _buildHub();
      case _SecretarySection.pickup:
        return _buildPickup();
    }
  }

  Widget _buildHub() {
    return SettingsPageScaffold(
      title: context.tr('Секретарь на звонках', 'Phone secretary'),
      dirty: _dirty,
      onSave: _save,
      body: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 32),
        children: [
          SettingsTileSection(
            title: context.tr('Секретарь', 'Secretary'),
            tiles: [
              SettingsHubTile(
                title: context.tr('ИИ берёт трубку', 'AI answers'),
                subtitle: _pickupSubtitle(),
                icon: Icons.support_agent,
                color: Colors.deepPurple,
                active: _enabled,
                onTap: () => _open(_SecretarySection.pickup),
              ),
              SettingsHubTile(
                title: context.tr('Ошибки', 'Errors'),
                subtitle: context.tr('Копировать', 'Copy'),
                icon: Icons.report_outlined,
                color: Colors.red,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const SecretaryLearnPage(),
                    ),
                  );
                },
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(
              context.tr(
                'Как она говорит — только на сервере. Здесь только кто берёт трубку. '
                'Часы — «Расписание → Рабочие дни», район — «Компания → Зона», цены — «Компания → Прайс».',
                'How she talks lives on the server. Here you only choose who picks up. '
                'Hours: Schedule → Working days. Area: Company → Area. Prices: Company → Prices.',
              ),
              style: const TextStyle(color: Colors.black54, fontSize: 13),
            ),
          ),
          if (_saving)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  Widget _buildPickup() {
    return SettingsPageScaffold(
      title: context.tr('ИИ берёт трубку', 'AI answers'),
      dirty: _dirty,
      onSave: _save,
      body: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 32),
        children: [
          SettingsTileSection(
            title: context.tr('Кто отвечает', 'Who answers'),
            tiles: [
              SettingsHubTile(
                title: context.tr('Включить', 'Enable'),
                subtitle: _enabled ? 'Вкл'.tr : 'Выкл'.tr,
                icon: Icons.support_agent,
                color: Colors.deepPurple,
                active: _enabled,
                onTap: () => _setEnabled(!_enabled),
              ),
              SettingsHubTile(
                title: context.tr('Сразу', 'Immediately'),
                subtitle: _timeout <= 0 ? '✓' : '',
                icon: Icons.flash_on,
                color: AppColors.accent,
                active: _timeout <= 0,
                onTap: () => setState(() => _timeout = 0),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: Text(
              context.tr(
                'Задержка, секунд (0 = сразу секретарю)',
                'Delay in seconds (0 = secretary at once)',
              ),
              style: const TextStyle(color: Colors.black54),
            ),
          ),
          Slider(
            min: SettingsService.minAiAnswerTimeoutSeconds.toDouble(),
            max: SettingsService.maxAiAnswerTimeoutSeconds.toDouble(),
            divisions: SettingsService.maxAiAnswerTimeoutSeconds -
                SettingsService.minAiAnswerTimeoutSeconds,
            value: _timeout.toDouble().clamp(
              SettingsService.minAiAnswerTimeoutSeconds.toDouble(),
              SettingsService.maxAiAnswerTimeoutSeconds.toDouble(),
            ),
            label: _timeout <= 0
                ? context.tr('Сразу', 'Now')
                : '$_timeout',
            onChanged: (value) => setState(() => _timeout = value.round()),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
            child: Text(
              _timeout <= 0
                  ? context.tr(
                      'Входящий сразу идёт секретарю. Вам телефон не звонит.',
                      'Inbound goes straight to the secretary.',
                    )
                  : context.tr(
                      'Сначала звонок вам. Не взяли — отвечает секретарь.',
                      'Rings you first. Miss it — secretary answers.',
                    ),
              style: const TextStyle(color: Colors.black54, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
