import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../services/settings_service.dart';
import '../widgets/settings_ui.dart';

class AssistantSettingsPage extends StatefulWidget {
  const AssistantSettingsPage({super.key});

  @override
  State<AssistantSettingsPage> createState() => _AssistantSettingsPageState();
}

class _AssistantSettingsPageState extends State<AssistantSettingsPage> {
  final _wakeWordCtrl = TextEditingController();
  final _aliasesCtrl = TextEditingController();
  bool _loading = true;
  bool _enabled = true;
  bool _wakeEnabled = false;
  String _language = SettingsService.assistantLanguageRu;

  String get _wakeWord {
    final value = _wakeWordCtrl.text.trim();
    return value.isEmpty
        ? SettingsService.defaultAssistantWakeWord
        : value;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _wakeWordCtrl.dispose();
    _aliasesCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final config = await SettingsService.loadConfig();
    if (!mounted) return;
    _wakeWordCtrl.text = SettingsService.readAssistantWakeWord(config);
    _aliasesCtrl.text = SettingsService.readAssistantWakeAliasesRaw(config);
    setState(() {
      _enabled = SettingsService.readAssistantEnabled(config);
      _wakeEnabled = SettingsService.readAssistantWakeEnabled(config);
      _language = SettingsService.readAssistantLanguage(config);
      _loading = false;
    });
  }

  Future<void> _setEnabled(bool value) async {
    setState(() {
      _enabled = value;
      _wakeEnabled = value;
    });
    await SettingsService.updateConfig('assistantEnabled', value);
    await SettingsService.updateConfig('assistantWakeEnabled', value);
  }

  Future<void> _setWakeEnabled(bool value) async {
    setState(() => _wakeEnabled = value);
    await SettingsService.updateConfig('assistantWakeEnabled', value);
  }

  Future<void> _setLanguage(String code) async {
    setState(() => _language = code);
    await SettingsService.updateConfig('assistantLanguage', code);
  }

  Future<void> _saveWakePhrases() async {
    final word = _wakeWord;
    final aliases = _aliasesCtrl.text.trim();
    if (_wakeWordCtrl.text.trim().isEmpty) {
      _wakeWordCtrl.text = word;
    }
    await SettingsService.updateConfig('assistantWakeWord', word);
    await SettingsService.updateConfig(
      'assistantWakeAliases',
      aliases.isEmpty
          ? SettingsService.defaultAssistantWakeAliases
          : aliases,
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: context.tr('Ассистент', 'Assistant'),
      body: _loading
          ? Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            )
          : ListView(
              padding: const EdgeInsets.only(top: 20, bottom: 40),
              children: [
                SettingsGroup(
                  children: [
                    SettingsRow(
                      title: context.tr('Ассистент', 'Assistant'),
                      subtitle: _enabled
                          ? context.tr(
                              'Голосовой $_wakeWord в приложении',
                              'Voice $_wakeWord inside the app',
                            )
                          : context.tr('Выключен', 'Off'),
                      icon: Icons.smart_toy_outlined,
                      iconColor: Colors.deepPurple,
                      trailing: Switch(
                        value: _enabled,
                        onChanged: _setEnabled,
                      ),
                    ),
                    SettingsRow(
                      title: context.tr(
                        'Слово «$_wakeWord»',
                        'Wake word “$_wakeWord”',
                      ),
                      subtitle: context.tr(
                        'Пока приложение открыто, скажите «$_wakeWord» по-русски или по-английски. Микрофон держится включённым, без мигания. В фоне Android микрофон не даёт.',
                        'While the app is open, say “$_wakeWord” in Russian or English. The mic stays on instead of blinking. Android will not keep the mic in the background.',
                      ),
                      icon: Icons.hearing,
                      iconColor: Colors.indigo,
                      trailing: Switch(
                        value: _enabled && _wakeEnabled,
                        onChanged: _enabled ? _setWakeEnabled : null,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: TextField(
                        controller: _wakeWordCtrl,
                        textInputAction: TextInputAction.done,
                        textCapitalization: TextCapitalization.none,
                        decoration: InputDecoration(
                          labelText: context.tr(
                            'Как называть ассистента',
                            'Assistant name / wake word',
                          ),
                          hintText: SettingsService.defaultAssistantWakeWord,
                          border: const OutlineInputBorder(),
                          filled: true,
                          fillColor: Colors.white,
                        ),
                        onChanged: (_) => setState(() {}),
                        onEditingComplete: _saveWakePhrases,
                        onTapOutside: (_) => _saveWakePhrases(),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: TextField(
                        controller: _aliasesCtrl,
                        textInputAction: TextInputAction.done,
                        textCapitalization: TextCapitalization.none,
                        decoration: InputDecoration(
                          labelText: context.tr(
                            'Похожие слова (через запятую)',
                            'Similar words (comma-separated)',
                          ),
                          hintText:
                              SettingsService.defaultAssistantWakeAliases,
                          border: const OutlineInputBorder(),
                          filled: true,
                          fillColor: Colors.white,
                        ),
                        onEditingComplete: _saveWakePhrases,
                        onTapOutside: (_) => _saveWakePhrases(),
                      ),
                    ),
                    SettingsRow(
                      title: context.tr('Язык ассистента', 'Assistant language'),
                      subtitle: _language == SettingsService.assistantLanguageEn
                          ? 'English'
                          : context.tr('Русский', 'Russian'),
                      icon: Icons.translate,
                      iconColor: Colors.teal,
                      trailing: FittedBox(
                        child: SegmentedButton<String>(
                          showSelectedIcon: false,
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          segments: const [
                            ButtonSegment(
                              value: SettingsService.assistantLanguageRu,
                              label: Text('RU'),
                            ),
                            ButtonSegment(
                              value: SettingsService.assistantLanguageEn,
                              label: Text('EN'),
                            ),
                          ],
                          selected: {_language},
                          onSelectionChanged: (value) {
                            if (value.isEmpty) return;
                            _setLanguage(value.first);
                          },
                        ),
                      ),
                    ),
                    SettingsRow(
                      title: context.tr('Как вызывать', 'How to open'),
                      subtitle: context.tr(
                        'Большой микрофон в шапке или слово «$_wakeWord». Кружок — пауза, тап в сторону — закрыть.',
                        'Big microphone in the app bar, or say “$_wakeWord”. Tap the circle to pause, tap outside to close.',
                      ),
                      icon: Icons.mic,
                      iconColor: Colors.indigo,
                      trailing: const SizedBox.shrink(),
                      showDivider: false,
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
