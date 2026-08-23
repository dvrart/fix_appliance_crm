import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../services/settings_service.dart';
import '../../../shared/widgets/app_bar_save.dart';
import '../widgets/settings_ui.dart';
import 'service_area_settings_page.dart';

/// Правила телефонного секретаря (звонок через Twilio, если трубку не взяли).
/// Это не голосовой ассистент в приложении.
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
  int _angryMinutes = AiVoiceProfile.defaultAngryCallbackMinutes;
  bool _collectName = true;
  bool _collectAddress = true;
  bool _collectWhen = true;
  bool _collectAppliance = true;
  bool _collectLocation = false;
  bool _collectPhoto = false;
  bool _noPrice = true;
  String _serviceArea = '';
  String _extraRules = '';
  List<String> _learnedRules = const [];
  final _greetingCtrl = TextEditingController();
  String _savedFp = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _greetingCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final profile = await SettingsService.loadAiVoiceProfile();
    if (!mounted) return;
    _greetingCtrl.text = profile.greeting;
    setState(() {
      _enabled = profile.enabled;
      _timeout = profile.timeoutSeconds;
      _angryMinutes = profile.angryCallbackMinutes;
      _collectName = profile.collectName;
      _collectAddress = profile.collectAddress;
      _collectWhen = profile.collectWhen;
      _collectAppliance = profile.collectAppliance;
      _collectLocation = profile.collectLocation;
      _collectPhoto = profile.collectPhoto;
      _noPrice = profile.noPrice;
      _serviceArea = profile.serviceArea;
      _extraRules = profile.extraRules;
      _learnedRules = profile.learnedRules;
      _loading = false;
      _savedFp = _fp();
    });
  }

  AiVoiceProfile _draft() {
    return AiVoiceProfile(
      enabled: _enabled,
      timeoutSeconds: _timeout,
      greeting: _greetingCtrl.text,
      collectName: _collectName,
      collectAddress: _collectAddress,
      collectWhen: _collectWhen,
      collectAppliance: _collectAppliance,
      collectLocation: _collectLocation,
      collectPhoto: _collectPhoto,
      noPrice: _noPrice,
      serviceArea: _serviceArea,
      angryCallbackMinutes: _angryMinutes,
      extraRules: _extraRules,
      instructions: '',
      learnedRules: _learnedRules,
      learningEnabled: true,
    );
  }

  String _fp() {
    return [
      _timeout,
      _angryMinutes,
      _greetingCtrl.text,
      _collectName,
      _collectAddress,
      _collectWhen,
      _collectAppliance,
      _collectLocation,
      _collectPhoto,
      _noPrice,
    ].join('|');
  }

  bool get _dirty => !_loading && _fp() != _savedFp;

  Future<void> _save() async {
    setState(() => _saving = true);
    await SettingsService.saveAiVoiceProfile(_draft());
    if (!mounted) return;
    setState(() {
      _saving = false;
      _savedFp = _fp();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.tr(
            'Правила секретаря сохранены',
            'Secretary rules saved',
          ),
        ),
        backgroundColor: Colors.green,
      ),
    );
  }

  Future<void> _setEnabled(bool value) async {
    setState(() => _enabled = value);
    await SettingsService.updateConfig('aiAnswerEnabled', value);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: context.tr('Секретарь на звонках', 'Phone secretary'),
      actions: [
        AppBarSaveButton(
          dirty: _dirty,
          saving: _saving,
          onPressed: _save,
        ),
      ],
      body: _loading
          ? Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            )
          : ListView(
              padding: const EdgeInsets.only(top: 20, bottom: 40),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Text(
                    context.tr(
                      'Это секретарь на входящем звонке, если вы не берёте трубку. Он понимает любой язык, но говорит только по-английски. Правила разговора идут с сервера — приветствие и галочки ниже на живой звонок не отправляются. Включён/выключен, задержка и зона с карты — да.',
                      'This is the secretary on an incoming call if you do not pick up. It understands any language, but it speaks English only. Live-call rules come from the server — the greeting and checkboxes below are not sent on the call. On/off, pickup delay, and the map area still apply.',
                    ),
                    style: const TextStyle(color: Colors.black54),
                  ),
                ),
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
                          Text(
                            _timeout <= 0
                                ? context.tr(
                                    'Через сколько секунд отвечать: сразу',
                                    'Answer after: immediately',
                                  )
                                : context.tr(
                                    'Через сколько секунд отвечать: $_timeout',
                                    'Answer after $_timeout seconds',
                                  ),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: () {
                                setState(() => _timeout = 0);
                              },
                              style: FilledButton.styleFrom(
                                backgroundColor: _timeout <= 0
                                    ? AppColors.accent
                                    : const Color(0xFF14557F),
                                foregroundColor: _timeout <= 0
                                    ? Colors.black
                                    : Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                              icon: const Icon(Icons.flash_on),
                              label: Text(
                                context.tr(
                                  'Сразу берёт трубку',
                                  'Answer immediately',
                                ),
                                style: const TextStyle(fontWeight: FontWeight.w800),
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
                _sectionTitle(
                  context.tr('Приветствие', 'Greeting'),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: TextField(
                    controller: _greetingCtrl,
                    maxLines: 3,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: context.tr(
                        'Hi, you\'ve reached FIX Appliance. How can I help?',
                        'Hi, you\'ve reached FIX Appliance. How can I help?',
                      ),
                      border: const OutlineInputBorder(),
                      filled: true,
                      fillColor: Colors.white,
                    ),
                  ),
                ),
                _sectionTitle(
                  context.tr('Что обязательно узнать', 'What to collect'),
                ),
                SettingsGroup(
                  children: [
                    _check(
                      context.tr('Имя (достаточно имени)', 'Name (first name is enough)'),
                      _collectName,
                      (v) => setState(() => _collectName = v),
                    ),
                    _check(
                      context.tr('Адрес (улица и город)', 'Address (street and city)'),
                      _collectAddress,
                      (v) => setState(() => _collectAddress = v),
                    ),
                    _check(
                      context.tr(
                        'Удобный день и время визита',
                        'Preferred day and time',
                      ),
                      _collectWhen,
                      (v) => setState(() => _collectWhen = v),
                    ),
                    _check(
                      context.tr(
                        'Что сломалось, вид техники и бренд',
                        'What broke, appliance type, and brand',
                      ),
                      _collectAppliance,
                      (v) => setState(() => _collectAppliance = v),
                    ),
                    _check(
                      context.tr(
                        'Где стоит техника',
                        'Where the appliance is in the home',
                      ),
                      _collectLocation,
                      (v) => setState(() => _collectLocation = v),
                    ),
                    _check(
                      context.tr(
                        'Попросить фото или текст шильдика в конце',
                        'Ask for a model-sticker photo or text at the end',
                      ),
                      _collectPhoto,
                      (v) => setState(() => _collectPhoto = v),
                      showDivider: false,
                    ),
                  ],
                ),
                SettingsGroup(
                  children: [
                    SettingsRow(
                      title: context.tr(
                        'Не обещать цену и точное время',
                        'Do not promise a price or exact time',
                      ),
                      subtitle: context.tr(
                        'Мастер перезвонит подтвердить',
                        'A technician will call back to confirm',
                      ),
                      icon: Icons.price_change_outlined,
                      iconColor: Colors.orange,
                      trailing: Switch(
                        value: _noPrice,
                        onChanged: (v) => setState(() => _noPrice = v),
                      ),
                    ),
                    SettingsRow(
                      title: context.tr(
                        'Если клиент злой',
                        'If the caller is angry',
                      ),
                      subtitle: context.tr(
                        'Пообещать, что сотрудник свяжется через $_angryMinutes мин, и закончить разговор',
                        'Promise a callback in $_angryMinutes min and end the call',
                      ),
                      icon: Icons.support,
                      iconColor: Colors.redAccent,
                      showDivider: false,
                      trailing: DropdownButtonHideUnderline(
                        child: DropdownButton<int>(
                          value: _angryMinutes,
                          items: const [
                            DropdownMenuItem(value: 15, child: Text('15')),
                            DropdownMenuItem(value: 30, child: Text('30')),
                            DropdownMenuItem(value: 45, child: Text('45')),
                            DropdownMenuItem(value: 60, child: Text('60')),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            setState(() => _angryMinutes = value);
                          },
                        ),
                      ),
                    ),
                  ],
                ),
                _sectionTitle(
                  context.tr('Зона обслуживания', 'Service area'),
                ),
                SettingsGroup(
                  children: [
                    SettingsRow(
                      title: context.tr(
                        'Секретарь берёт зону с карты',
                        'Secretary uses the map area',
                      ),
                      subtitle: _serviceArea.isEmpty
                          ? context.tr(
                              'Не отмечена на карте. Откройте зону обслуживания и нарисуйте район.',
                              'Not marked on the map. Open Service area and draw the region.',
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
              ],
            ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: Colors.grey,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.1,
        ),
      ),
    );
  }

  Widget _check(
    String title,
    bool value,
    ValueChanged<bool> onChanged, {
    bool showDivider = true,
  }) {
    return Column(
      children: [
        CheckboxListTile(
          value: value,
          onChanged: (next) => onChanged(next ?? false),
          title: Text(title, style: const TextStyle(fontSize: 15)),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        ),
        if (showDivider)
          const Divider(height: 1, indent: 16, color: Colors.black12),
      ],
    );
  }
}
