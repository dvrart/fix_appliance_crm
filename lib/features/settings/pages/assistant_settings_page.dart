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
  bool _savedEnabled = true;
  bool _savedWakeEnabled = false;
  String _savedLanguage = SettingsService.assistantLanguageRu;
  String _savedWakeWord = SettingsService.defaultAssistantWakeWord;
  String _savedAliases = SettingsService.defaultAssistantWakeAliases;

  String get _wakeWord {
    final value = _wakeWordCtrl.text.trim();
    return value.isEmpty
        ? SettingsService.defaultAssistantWakeWord
        : value;
  }

  bool get _dirty {
    if (_loading) return false;
    final word = _wakeWord;
    final aliases = _aliasesCtrl.text.trim().isEmpty
        ? SettingsService.defaultAssistantWakeAliases
        : _aliasesCtrl.text.trim();
    return _enabled != _savedEnabled ||
        _wakeEnabled != _savedWakeEnabled ||
        _language != _savedLanguage ||
        word != _savedWakeWord ||
        aliases != _savedAliases;
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
      _savedEnabled = _enabled;
      _savedWakeEnabled = _wakeEnabled;
      _savedLanguage = _language;
      _savedWakeWord = _wakeWordCtrl.text.trim();
      _savedAliases = _aliasesCtrl.text.trim();
      _loading = false;
    });
  }

  Future<bool> _save() async {
    final word = _wakeWord;
    final aliases = _aliasesCtrl.text.trim();
    if (_wakeWordCtrl.text.trim().isEmpty) {
      _wakeWordCtrl.text = word;
    }
    await SettingsService.updateConfigMap({
      'assistantEnabled': _enabled,
      'assistantWakeEnabled': _wakeEnabled,
      'assistantLanguage': _language,
      'assistantWakeWord': word,
      'assistantWakeAliases': aliases.isEmpty
          ? SettingsService.defaultAssistantWakeAliases
          : aliases,
    });
    if (!mounted) return true;
    setState(() {
      _savedEnabled = _enabled;
      _savedWakeEnabled = _wakeEnabled;
      _savedLanguage = _language;
      _savedWakeWord = word;
      _savedAliases = aliases.isEmpty
          ? SettingsService.defaultAssistantWakeAliases
          : aliases;
    });
    return true;
  }

  void _showHowToOpen() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.tr('Как вызывать', 'How to open')),
        content: Text(
          context.tr(
            'Большой микрофон в шапке или слово «$_wakeWord». Кружок — пауза, тап в сторону — закрыть.',
            'Big microphone in the app bar, or say “$_wakeWord”. Tap the circle to pause, tap outside to close.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return SettingsPageScaffold(
        title: context.tr('Ассистент', 'Assistant'),
        body: Center(child: CircularProgressIndicator(color: AppColors.accent)),
      );
    }
    return SettingsPageScaffold(
      title: context.tr('Ассистент', 'Assistant'),
      dirty: _dirty,
      onSave: _save,
      body: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 32),
        children: [
          SettingsTileSection(
            title: context.tr('Ассистент', 'Assistant'),
            tiles: [
              SettingsHubTile(
                title: context.tr('Включить', 'Enable'),
                subtitle: _enabled ? 'Вкл'.tr : 'Выкл'.tr,
                icon: Icons.smart_toy_outlined,
                color: Colors.deepPurple,
                active: _enabled,
                onTap: () => setState(() {
                  _enabled = !_enabled;
                  _wakeEnabled = _enabled;
                }),
              ),
              SettingsHubTile(
                title: context.tr('Слово «$_wakeWord»', 'Wake word'),
                subtitle: _wakeEnabled ? 'Вкл'.tr : 'Выкл'.tr,
                icon: Icons.hearing,
                color: Colors.indigo,
                active: _enabled && _wakeEnabled,
                onTap: _enabled
                    ? () => setState(() => _wakeEnabled = !_wakeEnabled)
                    : () {},
              ),
              SettingsHubTile(
                title: context.tr('Как вызывать', 'How to open'),
                subtitle: 'シ',
                icon: Icons.mic,
                color: Colors.blueGrey,
                onTap: _showHowToOpen,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Column(
              children: [
                TextField(
                  controller: _wakeWordCtrl,
                  enabled: _enabled,
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
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _aliasesCtrl,
                  enabled: _enabled,
                  textCapitalization: TextCapitalization.none,
                  decoration: InputDecoration(
                    labelText: context.tr(
                      'Похожие слова (через запятую)',
                      'Similar words (comma-separated)',
                    ),
                    hintText: SettingsService.defaultAssistantWakeAliases,
                    border: const OutlineInputBorder(),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ),
          ),
          SettingsTileSection(
            title: context.tr('Язык ассистента', 'Assistant language'),
            tiles: [
              SettingsHubTile(
                title: 'Русский',
                subtitle: 'RU',
                icon: Icons.translate,
                color: Colors.teal,
                active: _language == SettingsService.assistantLanguageRu,
                onTap: () => setState(
                  () => _language = SettingsService.assistantLanguageRu,
                ),
              ),
              SettingsHubTile(
                title: 'English',
                subtitle: 'EN',
                icon: Icons.translate,
                color: Colors.indigo,
                active: _language == SettingsService.assistantLanguageEn,
                onTap: () => setState(
                  () => _language = SettingsService.assistantLanguageEn,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(
              context.tr(
                'Пока приложение открыто, скажите «$_wakeWord». Жёлтый — слушает. «конец» / «end» — выключить.',
                'While the app is open, say “$_wakeWord”. Yellow means listening. Say “конец” or “end” to stop.',
              ),
              style: const TextStyle(color: Colors.black54, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
