import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../core/sms_text.dart';
import '../../../services/settings_service.dart';
import '../../../shared/widgets/confirm_action_sheet.dart';
import '../../../shared/widgets/dispose_on_close.dart';
import '../widgets/settings_ui.dart';

class MessageTemplatesPage extends StatefulWidget {
  const MessageTemplatesPage({super.key});

  @override
  State<MessageTemplatesPage> createState() => _MessageTemplatesPageState();
}

class _MessageTemplatesPageState extends State<MessageTemplatesPage> {
  Map<String, String> _templates = {};
  Map<String, String> _titles = {};
  List<Map<String, String>> _customTemplates = [];
  String _reviewUrl = '';
  bool _loading = true;
  bool _guideExpanded = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      SettingsService.loadSmsTemplates(),
      SettingsService.loadSmsTemplateTitles(),
      SettingsService.loadChatCustomTemplates(),
      SettingsService.loadConfig(),
    ]);
    if (!mounted) return;
    final templates = results[0] as Map<String, String>;
    final titles = results[1] as Map<String, String>;
    final custom = results[2] as List<Map<String, String>>;
    final config = results[3] as Map<String, dynamic>;
    setState(() {
      _templates = Map<String, String>.from(templates);
      _titles = Map<String, String>.from(titles);
      _customTemplates = List<Map<String, String>>.from(custom);
      _reviewUrl = SettingsService.readGoogleReviewUrl(config);
      _loading = false;
    });
  }

  String _titleForSpec(
    ({
      String key,
      String section,
      String defaultTitle,
      IconData icon,
      Color color,
    }) spec,
  ) {
    final custom = (_titles[spec.key] ?? '').trim();
    if (custom.isNotEmpty) return custom;
    return spec.defaultTitle.tr;
  }

  bool _isBuiltinModified(
    ({
      String key,
      String section,
      String defaultTitle,
      IconData icon,
      Color color,
    }) spec,
  ) {
    final defaults = SettingsService.defaultSmsTemplates();
    final defBody = (defaults[spec.key] ?? '').trim();
    final curBody = (_templates[spec.key] ?? '').trim();
    final curTitle = (_titles[spec.key] ?? '').trim();
    return curBody != defBody ||
        (curTitle.isNotEmpty &&
            curTitle != spec.defaultTitle &&
            curTitle != spec.defaultTitle.tr);
  }

  Future<void> _openBuiltinEditor(
    ({
      String key,
      String section,
      String defaultTitle,
      IconData icon,
      Color color,
    }) spec,
  ) async {
    final defaults = SettingsService.defaultSmsTemplates();
    final defaultBody = defaults[spec.key] ?? '';
    final defaultTitle = spec.defaultTitle.tr;
    final initialTitle = _titleForSpec(spec);
    final initialBody = _templates[spec.key] ?? defaultBody;

    final result = await Navigator.push<_TemplateEditResult>(
      context,
      MaterialPageRoute(
        builder: (_) => _TemplateEditorPage(
          pageTitle: 'Изменить шаблон'.tr,
          initialTitle: initialTitle,
          initialBody: initialBody,
          defaultTitle: defaultTitle,
          defaultBody: defaultBody,
          canDelete: false,
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (result.action == _TemplateEditAction.save) {
      final nextTemplates = Map<String, String>.from(_templates);
      nextTemplates[spec.key] = result.body;
      final nextTitles = Map<String, String>.from(_titles);
      if (result.title.isEmpty ||
          result.title == spec.defaultTitle ||
          result.title == spec.defaultTitle.tr) {
        nextTitles.remove(spec.key);
      } else {
        nextTitles[spec.key] = result.title;
      }
      await Future.wait([
        SettingsService.saveSmsTemplates(nextTemplates),
        SettingsService.saveSmsTemplateTitles(nextTitles),
      ]);
      if (!mounted) return;
      setState(() {
        _templates = nextTemplates;
        _titles = nextTitles;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Шаблон сохранен'.tr),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> _resetBuiltinTemplate(
    ({
      String key,
      String section,
      String defaultTitle,
      IconData icon,
      Color color,
    }) spec,
  ) async {
    final confirmed = await showConfirmCancelSheet(
      context,
      title: 'Сбросить шаблон?'.tr,
      message:
          '${_titleForSpec(spec)}\n\n${'Вернуть стандартное название и текст этого шаблона?'.tr}',
      confirmLabel: 'Сбросить'.tr,
    );
    if (!confirmed || !mounted) return;
    final defaults = SettingsService.defaultSmsTemplates();
    final nextTemplates = Map<String, String>.from(_templates);
    nextTemplates[spec.key] = defaults[spec.key] ?? '';
    final nextTitles = Map<String, String>.from(_titles)..remove(spec.key);
    await Future.wait([
      SettingsService.saveSmsTemplates(nextTemplates),
      SettingsService.saveSmsTemplateTitles(nextTitles),
    ]);
    if (!mounted) return;
    setState(() {
      _templates = nextTemplates;
      _titles = nextTitles;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Шаблон восстановлен'.tr),
        backgroundColor: Colors.green,
      ),
    );
  }

  Future<void> _addCustomTemplate() async {
    final result = await Navigator.push<_TemplateEditResult>(
      context,
      MaterialPageRoute(
        builder: (_) => _TemplateEditorPage(
          pageTitle: 'Новый шаблон'.tr,
          initialTitle: '',
          initialBody: '',
          canDelete: false,
        ),
      ),
    );
    if (result == null ||
        result.action != _TemplateEditAction.save ||
        result.body.trim().isEmpty ||
        !mounted) {
      return;
    }
    final next = [
      ..._customTemplates,
      {
        'id': DateTime.now().millisecondsSinceEpoch.toString(),
        'title': result.title.trim().isEmpty
            ? result.body.trim()
            : result.title.trim(),
        'body': result.body.trim(),
      },
    ];
    await SettingsService.saveChatCustomTemplates(next);
    if (!mounted) return;
    setState(() => _customTemplates = next);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Шаблон добавлен'.tr),
        backgroundColor: Colors.green,
      ),
    );
  }

  Future<void> _editCustomTemplate(int index) async {
    if (index < 0 || index >= _customTemplates.length) return;
    final item = _customTemplates[index];
    final result = await Navigator.push<_TemplateEditResult>(
      context,
      MaterialPageRoute(
        builder: (_) => _TemplateEditorPage(
          pageTitle: 'Изменить шаблон'.tr,
          initialTitle: item['title'] ?? '',
          initialBody: item['body'] ?? '',
          canDelete: true,
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (result.action == _TemplateEditAction.delete) {
      await _deleteCustomTemplate(index);
    } else if (result.action == _TemplateEditAction.save &&
        result.body.trim().isNotEmpty) {
      final next = [..._customTemplates];
      next[index] = {
        ...item,
        'title': result.title.trim().isEmpty
            ? result.body.trim()
            : result.title.trim(),
        'body': result.body.trim(),
      };
      await SettingsService.saveChatCustomTemplates(next);
      if (!mounted) return;
      setState(() => _customTemplates = next);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Шаблон сохранен'.tr),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> _deleteCustomTemplate(int index) async {
    if (index < 0 || index >= _customTemplates.length) return;
    final item = _customTemplates[index];
    final confirmed = await showConfirmCancelSheet(
      context,
      title: 'Удалить шаблон?'.tr,
      message: item['title'] ?? item['body'] ?? '',
      confirmLabel: 'Удалить'.tr,
    );
    if (!confirmed || !mounted) return;
    final next = [..._customTemplates]..removeAt(index);
    await SettingsService.saveChatCustomTemplates(next);
    if (!mounted) return;
    setState(() => _customTemplates = next);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Шаблон удален'.tr)),
    );
  }

  Future<void> _editReviewUrl() async {
    final ctrl = TextEditingController(text: _reviewUrl);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => DisposeOnClose(
        disposables: [ctrl],
        child: AlertDialog(
          title: Text('Ссылка на Google-отзыв'.tr),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Эта ссылка автоматически подставляется вместо фразы {review} в шаблонах сообщений.'
                    .tr,
                style: TextStyle(fontSize: 13, color: AppColors.inkMuted),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: 'URL отзыва Google'.tr,
                  hintText: 'https://g.page/r/...',
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Отмена'.tr),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Сохранить'.tr),
            ),
          ],
        ),
      ),
    );
    final nextUrl = ctrl.text.trim();
    if (saved != true || !mounted) return;
    await SettingsService.updateConfig('googleReviewUrl', nextUrl);
    if (!mounted) return;
    setState(() => _reviewUrl = nextUrl);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Ссылка сохранена'.tr),
        backgroundColor: Colors.green,
      ),
    );
  }

  Widget _buildPlaceholderGuideCard() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      decoration: BoxDecoration(
        color: AppColors.tint(AppColors.primary, 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => setState(() => _guideExpanded = !_guideExpanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.help_outline_rounded,
                      color: AppColors.primaryOnCard,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Памятка: как пользоваться {name}, {url} и др.'.tr,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                            color: AppColors.primaryOnCard,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Автоподстановка имени, ссылок, даты и сумм в SMS'.tr,
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.inkMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    _guideExpanded ? Icons.expand_less : Icons.expand_more,
                    color: AppColors.primaryOnCard,
                  ),
                ],
              ),
            ),
          ),
          if (_guideExpanded) ...[
            Divider(height: 1, color: AppColors.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
              child: const PlaceholderGuideContent(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: AppColors.ink,
              ),
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _buildBuiltinSection(String sectionName) {
    final specs = SettingsService.builtinSmsSpecs
        .where((s) => s.section == sectionName)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(sectionName.tr),
        SettingsGroup(
          children: [
            for (var i = 0; i < specs.length; i++) ...[
              Builder(
                builder: (context) {
                  final spec = specs[i];
                  final modified = _isBuiltinModified(spec);
                  final title = _titleForSpec(spec);
                  final body = (_templates[spec.key] ?? '').trim();
                  return ListTile(
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: spec.color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(spec.icon, color: spec.color),
                    ),
                    title: Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    subtitle: Text(
                      body.isEmpty ? '—' : body,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (modified)
                          IconButton(
                            tooltip: 'Сбросить по умолчанию'.tr,
                            icon: const Icon(
                              Icons.restart_alt,
                              color: Colors.orange,
                              size: 20,
                            ),
                            onPressed: () => _resetBuiltinTemplate(spec),
                          ),
                        IconButton(
                          tooltip: 'Изменить'.tr,
                          icon: const Icon(
                            Icons.edit_outlined,
                            color: Colors.blueGrey,
                            size: 20,
                          ),
                          onPressed: () => _openBuiltinEditor(spec),
                        ),
                      ],
                    ),
                    onTap: () => _openBuiltinEditor(spec),
                  );
                },
              ),
              if (i < specs.length - 1)
                Divider(height: 1, indent: 64, color: AppColors.border),
            ],
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return SettingsPageScaffold(
        title: 'Шаблоны сообщений'.tr,
        body: Center(child: CircularProgressIndicator(color: AppColors.accent)),
      );
    }

    return SettingsPageScaffold(
      title: 'Шаблоны сообщений'.tr,
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 36),
        children: [
          _buildPlaceholderGuideCard(),
          _buildSectionHeader(
            'Мои шаблоны'.tr,
            trailing: TextButton.icon(
              onPressed: _addCustomTemplate,
              icon: const Icon(Icons.add, size: 20),
              label: Text('Добавить шаблон'.tr),
            ),
          ),
          if (_customTemplates.isEmpty)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(16),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black12,
                    blurRadius: 4,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Center(
                child: Column(
                  children: [
                    Icon(
                      Icons.chat_bubble_outline,
                      size: 32,
                      color: AppColors.inkMuted,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Нет своих шаблонов'.tr,
                      style: TextStyle(color: AppColors.inkMuted),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _addCustomTemplate,
                      icon: const Icon(Icons.add),
                      label: Text('Добавить шаблон'.tr),
                    ),
                  ],
                ),
              ),
            )
          else
            SettingsGroup(
              children: [
                for (var i = 0; i < _customTemplates.length; i++) ...[
                  ListTile(
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.chat_bubble_outline,
                        color: AppColors.primaryOnCard,
                      ),
                    ),
                    title: Text(
                      _customTemplates[i]['title'] ?? '',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    subtitle: Text(
                      _customTemplates[i]['body'] ?? '',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Изменить'.tr,
                          icon: const Icon(
                            Icons.edit_outlined,
                            color: Colors.blueGrey,
                            size: 20,
                          ),
                          onPressed: () => _editCustomTemplate(i),
                        ),
                        IconButton(
                          tooltip: 'Удалить'.tr,
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.red,
                            size: 20,
                          ),
                          onPressed: () => _deleteCustomTemplate(i),
                        ),
                      ],
                    ),
                    onTap: () => _editCustomTemplate(i),
                  ),
                  if (i < _customTemplates.length - 1)
                    Divider(height: 1, indent: 64, color: AppColors.border),
                ],
              ],
            ),
          _buildBuiltinSection('В пути и работа'),
          _buildBuiltinSection('Визиты'),
          _buildBuiltinSection('Документы и оплата'),
          _buildSectionHeader('Ссылка для {review}'.tr),
          SettingsGroup(
            children: [
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.star_outline, color: Colors.amber.shade800),
                ),
                title: Text(
                  'Ссылка на Google-отзыв ({review})'.tr,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                subtitle: Text(
                  _reviewUrl.isEmpty ? 'Не указана'.tr : _reviewUrl,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
                trailing: IconButton(
                  tooltip: 'Изменить'.tr,
                  icon: const Icon(
                    Icons.edit_outlined,
                    color: Colors.blueGrey,
                    size: 20,
                  ),
                  onPressed: _editReviewUrl,
                ),
                onTap: _editReviewUrl,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

enum _TemplateEditAction { save, delete }

class _TemplateEditResult {
  final _TemplateEditAction action;
  final String title;
  final String body;

  const _TemplateEditResult({
    required this.action,
    required this.title,
    required this.body,
  });
}

class _TemplateEditorPage extends StatefulWidget {
  final String pageTitle;
  final String initialTitle;
  final String initialBody;
  final String? defaultTitle;
  final String? defaultBody;
  final bool canDelete;

  const _TemplateEditorPage({
    required this.pageTitle,
    required this.initialTitle,
    required this.initialBody,
    this.defaultTitle,
    this.defaultBody,
    this.canDelete = false,
  });

  @override
  State<_TemplateEditorPage> createState() => _TemplateEditorPageState();
}

class _TemplateEditorPageState extends State<_TemplateEditorPage> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _bodyCtrl;
  final FocusNode _bodyFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.initialTitle);
    _bodyCtrl = TextEditingController(text: widget.initialBody);
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  void _insertPlaceholder(String tag) {
    final text = _bodyCtrl.text;
    final sel = _bodyCtrl.selection;
    final int start;
    final int end;
    if (sel.isValid && sel.start >= 0 && sel.end <= text.length) {
      start = sel.start;
      end = sel.end;
    } else {
      start = text.length;
      end = text.length;
    }
    final nextText = text.replaceRange(start, end, tag);
    _bodyCtrl.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: start + tag.length),
    );
    _bodyFocus.requestFocus();
  }

  void _restoreDefaults() {
    setState(() {
      if (widget.defaultTitle != null) {
        _titleCtrl.text = widget.defaultTitle!;
      }
      if (widget.defaultBody != null) {
        _bodyCtrl.text = widget.defaultBody!;
      }
    });
  }

  void _save() {
    final body = _bodyCtrl.text.trim();
    if (body.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Введите текст шаблона'.tr),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    Navigator.pop(
      context,
      _TemplateEditResult(
        action: _TemplateEditAction.save,
        title: _titleCtrl.text.trim(),
        body: body,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasDefaults = widget.defaultBody != null;
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        title: Text(
          widget.pageTitle,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        actions: [
          if (widget.canDelete)
            IconButton(
              tooltip: 'Удалить'.tr,
              icon: const Icon(Icons.delete_outline),
              onPressed: () => Navigator.pop(
                context,
                const _TemplateEditResult(
                  action: _TemplateEditAction.delete,
                  title: '',
                  body: '',
                ),
              ),
            ),
          TextButton(
            onPressed: _save,
            child: Text(
              'Сохранить'.tr,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 36),
        children: [
          TextField(
            controller: _titleCtrl,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Название шаблона'.tr,
              border: const OutlineInputBorder(),
              filled: true,
              fillColor: AppColors.card,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _bodyCtrl,
            focusNode: _bodyFocus,
            minLines: 5,
            maxLines: 12,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Текст сообщения'.tr,
              alignLabelWithHint: true,
              border: const OutlineInputBorder(),
              filled: true,
              fillColor: AppColors.card,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Нажмите на фразу, чтобы вставить её в текст на место курсора:'.tr,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.ink,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final item in SmsText.placeholderGuide)
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  backgroundColor: AppColors.card,
                  side: BorderSide(
                    color: AppColors.primary.withValues(alpha: 0.35),
                  ),
                  label: Text(
                    item.tag,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      color: AppColors.primaryOnCard,
                    ),
                  ),
                  tooltip: item.title.tr,
                  onPressed: () => _insertPlaceholder(item.tag),
                ),
            ],
          ),
          if (hasDefaults) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _restoreDefaults,
                icon: const Icon(Icons.restart_alt, size: 18),
                label: Text('Вернуть стандартный текст'.tr),
              ),
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.check),
              label: Text('Сохранить шаблон'.tr),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.tint(AppColors.primary, 0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.25),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Памятка: как работают фразы в скобках'.tr,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: AppColors.primaryOnCard,
                  ),
                ),
                const SizedBox(height: 8),
                const PlaceholderGuideContent(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class PlaceholderGuideContent extends StatelessWidget {
  const PlaceholderGuideContent({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '• Пишите специальные слова в фигурных скобках: например {name} или {url}.\n'
                  '• Регистр букв не важен: {url}, {URL} и {Name} работают одинаково.\n'
                  '• Вы можете свободно менять любой шаблон, добавлять или убирать любые фразы — ограничений нет.\n'
                  '• При выборе шаблона в чате или отправке документа программа сама подставит нужные данные:'
              .tr,
          style: TextStyle(
            fontSize: 12.5,
            height: 1.4,
            color: AppColors.ink,
          ),
        ),
        const SizedBox(height: 10),
        for (final item in SmsText.placeholderGuide)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  constraints: const BoxConstraints(minWidth: 78),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: AppColors.primary.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Text(
                    item.tag,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                      color: AppColors.primaryOnCard,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: RichText(
                    text: TextSpan(
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.35,
                        color: AppColors.ink,
                      ),
                      children: [
                        TextSpan(
                          text: '${item.title.tr} — ',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        TextSpan(text: item.description.tr),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
