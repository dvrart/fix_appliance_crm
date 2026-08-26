import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../services/settings_service.dart';
import '../../../shared/widgets/app_bar_save.dart';
import '../widgets/settings_ui.dart';
import 'secretary_learn_page.dart';
import 'service_area_settings_page.dart';

/// Кто берёт трубку и чат, чтобы настроить секретаря. Это не Purish в приложении.
class AiSecretarySettingsPage extends StatefulWidget {
  const AiSecretarySettingsPage({super.key});

  @override
  State<AiSecretarySettingsPage> createState() =>
      _AiSecretarySettingsPageState();
}

class _AiSecretarySettingsPageState extends State<AiSecretarySettingsPage> {
  bool _loading = true;
  bool _saving = false;
  bool _enabled = true;
  int _timeout = SettingsService.defaultAiAnswerTimeoutSeconds;
  String _serviceArea = '';
  AiVoiceProfile? _profile;
  String _savedFp = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profile = await SettingsService.loadAiVoiceProfile();
    if (!mounted) return;
    setState(() {
      _profile = profile;
      _enabled = profile.enabled;
      _timeout = profile.timeoutSeconds;
      _serviceArea = profile.serviceArea;
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

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: context.tr('Секретарь на звонках', 'Phone secretary'),
      dirty: _dirty,
      onSave: _save,
      actions: [
        AppBarSaveButton(
          dirty: _dirty,
          saving: _saving,
          onPressed: () { _save(); },
        ),
      ],
      body: _loading
          ? Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            )
          : ListView(
              padding: const EdgeInsets.only(top: 20, bottom: 24),
              children: [
                SettingsGroup(
                  children: [
                    SettingsRow(
                      title: context.tr('ИИ берёт трубку', 'AI answers the phone'),
                      subtitle: _enabled
                          ? (_timeout <= 0
                              ? context.tr(
                                  'Секретарь берёт трубку сразу, вам не звонит',
                                  'The secretary answers at once. Your phone does not ring.',
                                )
                              : context.tr(
                                  'Если не ответить за $_timeout секунд, секретарь сам примет заказ',
                                  'If you do not pick up within $_timeout seconds, the secretary takes the request',
                                ))
                          : context.tr('Выключен', 'Off'),
                      icon: Icons.support_agent,
                      iconColor: Colors.deepPurple,
                      trailing: Switch(
                        value: _enabled,
                        onChanged: _setEnabled,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: () => setState(() => _timeout = 0),
                              style: FilledButton.styleFrom(
                                backgroundColor: _timeout <= 0
                                    ? AppColors.accent
                                    : const Color(0xFF14557F),
                                foregroundColor:
                                    _timeout <= 0 ? Colors.black : Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                              ),
                              icon: const Icon(Icons.flash_on),
                              label: Text(
                                context.tr(
                                  'Сразу берёт трубку',
                                  'Answer immediately',
                                ),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ),
                          Slider(
                            min: SettingsService.minAiAnswerTimeoutSeconds
                                .toDouble(),
                            max: SettingsService.maxAiAnswerTimeoutSeconds
                                .toDouble(),
                            divisions: SettingsService.maxAiAnswerTimeoutSeconds -
                                SettingsService.minAiAnswerTimeoutSeconds,
                            value: _timeout.toDouble(),
                            label: _timeout <= 0
                                ? context.tr('Сразу', 'Now')
                                : '$_timeout',
                            onChanged: (value) {
                              setState(() => _timeout = value.round());
                            },
                          ),
                          Text(
                            _timeout <= 0
                                ? context.tr(
                                    'Входящий сразу идёт секретарю. Вам телефон не звонит.',
                                    'The inbound call goes straight to the secretary. Your phone does not ring.',
                                  )
                                : context.tr(
                                    'Сначала звонок идёт вам. Если трубку не взять, отвечает секретарь.',
                                    'The call rings you first. If you miss it, the secretary answers.',
                                  ),
                            style: const TextStyle(
                              color: Colors.black54,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                SettingsGroup(
                  children: [
                    SettingsRow(
                      title: context.tr(
                        'Зона обслуживания',
                        'Service area',
                      ),
                      subtitle: _serviceArea.isEmpty
                          ? context.tr(
                              'Не отмечена на карте',
                              'Not marked on the map',
                            )
                          : _serviceArea,
                      icon: Icons.map_outlined,
                      iconColor: Colors.orange,
                      showDivider: false,
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const ServiceAreaSettingsPage(),
                          ),
                        );
                        if (!mounted) return;
                        final config = await SettingsService.loadConfig();
                        if (!mounted) return;
                        setState(() {
                          _serviceArea =
                              SettingsService.describeServiceArea(config);
                        });
                      },
                    ),
                  ],
                ),
                SettingsGroup(
                  children: [
                    SettingsRow(
                      title: context.tr(
                        'Ошибки секретаря',
                        'Secretary errors',
                      ),
                      subtitle: context.tr(
                        'Если на звонке ошиблась — скопируйте карточку и пришлите в чат. Скрипт из приложения не меняется.',
                        'If a call went wrong, copy the card and send it in chat. The script is not edited in the app.',
                      ),
                      icon: Icons.report_outlined,
                      iconColor: Colors.red,
                      showDivider: false,
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
                      'Как отвечает — на сервере. Часы и календарь берутся из «Календарь», район — из «Зона». Здесь только кто берёт трубку.',
                      'How she answers lives on the server. Hours come from Calendar, the area from Zone. This page only chooses who picks up.',
                    ),
                    style: const TextStyle(
                      color: Colors.black54,
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
