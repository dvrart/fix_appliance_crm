import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../models/document_settings.dart';
import '../../../services/settings_service.dart';
import '../widgets/settings_ui.dart';

enum _TplSection {
  hub,
  booking,
  reminder,
  cancel,
  reschedule,
  onWay,
  parts,
  done,
  review,
  invoice,
  estimate,
  receipt,
  pay,
}

class MessageTemplatesPage extends StatefulWidget {
  const MessageTemplatesPage({super.key}) : _sectionIndex = 0;

  const MessageTemplatesPage._at(this._sectionIndex, {super.key});

  final int _sectionIndex;

  _TplSection get _section =>
      _TplSection.values[_sectionIndex.clamp(0, _TplSection.values.length - 1)];

  @override
  State<MessageTemplatesPage> createState() => _MessageTemplatesPageState();
}

class _MessageTemplatesPageState extends State<MessageTemplatesPage> {
  final _onWay = TextEditingController();
  final _parts = TextEditingController();
  final _done = TextEditingController();
  final _book = TextEditingController();
  final _day = TextEditingController();
  final _cancelSave = TextEditingController();
  final _rescheduleAsk = TextEditingController();
  final _reviewUrl = TextEditingController();
  final _invoiceSms = TextEditingController();
  final _estimateSms = TextEditingController();
  final _receiptSms = TextEditingController();
  final _paySms = TextEditingController();
  List<Map<String, String>> _customTemplates = [];
  bool _loading = true;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [
      _onWay,
      _parts,
      _done,
      _book,
      _day,
      _cancelSave,
      _rescheduleAsk,
      _reviewUrl,
      _invoiceSms,
      _estimateSms,
      _receiptSms,
      _paySms,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _open(_TplSection section) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MessageTemplatesPage._at(section.index),
      ),
    ).then((_) {
      if (mounted && widget._section == _TplSection.hub) _load();
    });
  }

  void _onEdit() {
    if (_loading || _dirty) return;
    setState(() => _dirty = true);
  }

  Future<void> _load() async {
    final templates = await SettingsService.loadSmsTemplates();
    final docs = await SettingsService.loadDocumentSettings();
    final config = await SettingsService.loadConfig();
    final custom = await SettingsService.loadChatCustomTemplates();
    if (!mounted) return;
    _customTemplates = custom;
    _onWay.text = templates['on_way'] ?? '';
    _parts.text = templates['part_ordered'] ?? '';
    _done.text = templates['job_done'] ?? '';
    _book.text = templates['booking_confirm'] ?? '';
    _day.text = templates['day_before'] ?? '';
    _cancelSave.text = templates['cancel_save'] ?? '';
    _rescheduleAsk.text = templates['reschedule_ask'] ?? '';
    _reviewUrl.text = SettingsService.readGoogleReviewUrl(config);
    _invoiceSms.text = docs.invoiceSms;
    _estimateSms.text = docs.estimateSms;
    _receiptSms.text = docs.receiptSms;
    _paySms.text = docs.paySms;
    for (final controller in [
      _onWay,
      _parts,
      _done,
      _book,
      _day,
      _cancelSave,
      _rescheduleAsk,
      _reviewUrl,
      _invoiceSms,
      _estimateSms,
      _receiptSms,
      _paySms,
    ]) {
      controller.addListener(_onEdit);
    }
    setState(() {
      _loading = false;
      _dirty = false;
    });
  }

  Future<void> _addCustomTemplate() async {
    final titleCtrl = TextEditingController();
    final bodyCtrl = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Новый шаблон'.tr),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleCtrl,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: 'Название'.tr,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: bodyCtrl,
                  minLines: 3,
                  maxLines: 8,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: 'Текст'.tr,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Отмена'.tr),
            ),
            ElevatedButton(
              onPressed: () {
                if (bodyCtrl.text.trim().isEmpty) return;
                Navigator.pop(context, true);
              },
              child: Text('Сохранить'.tr),
            ),
          ],
        );
      },
    );
    titleCtrl.dispose();
    bodyCtrl.dispose();
    if (saved != true || !mounted) return;
    final next = [
      ..._customTemplates,
      {
        'id': DateTime.now().millisecondsSinceEpoch.toString(),
        'title': titleCtrl.text.trim().isEmpty
            ? bodyCtrl.text.trim()
            : titleCtrl.text.trim(),
        'body': bodyCtrl.text.trim(),
      },
    ];
    await SettingsService.saveChatCustomTemplates(next);
    if (!mounted) return;
    setState(() => _customTemplates = next);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Шаблон добавлен'.tr)),
    );
  }

  Future<void> _editCustomTemplate(int index) async {
    if (index < 0 || index >= _customTemplates.length) return;
    final item = _customTemplates[index];
    final titleCtrl = TextEditingController(text: item['title'] ?? '');
    final bodyCtrl = TextEditingController(text: item['body'] ?? '');
    final action = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Изменить шаблон'.tr),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleCtrl,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: 'Название'.tr,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: bodyCtrl,
                  minLines: 3,
                  maxLines: 8,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: 'Текст'.tr,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'delete'),
              child: Text('Удалить'.tr, style: const TextStyle(color: Colors.red)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'cancel'),
              child: Text('Отмена'.tr),
            ),
            ElevatedButton(
              onPressed: () {
                if (bodyCtrl.text.trim().isEmpty) return;
                Navigator.pop(context, 'save');
              },
              child: Text('Сохранить'.tr),
            ),
          ],
        );
      },
    );
    final updatedTitle = titleCtrl.text.trim();
    final updatedBody = bodyCtrl.text.trim();
    titleCtrl.dispose();
    bodyCtrl.dispose();
    if (!mounted) return;
    if (action == 'delete') {
      await _deleteCustomTemplate(index);
    } else if (action == 'save' && updatedBody.isNotEmpty) {
      final next = [..._customTemplates];
      next[index] = {
        ...item,
        'title': updatedTitle.isEmpty ? updatedBody : updatedTitle,
        'body': updatedBody,
      };
      await SettingsService.saveChatCustomTemplates(next);
      if (!mounted) return;
      setState(() => _customTemplates = next);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Шаблон сохранен'.tr)),
      );
    }
  }

  Future<void> _deleteCustomTemplate(int index) async {
    if (index < 0 || index >= _customTemplates.length) return;
    final item = _customTemplates[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Удалить шаблон?'.tr),
        content: Text(item['title'] ?? item['body'] ?? ''),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Отмена'.tr),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: Text('Удалить'.tr),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final next = [..._customTemplates]..removeAt(index);
    await SettingsService.saveChatCustomTemplates(next);
    if (!mounted) return;
    setState(() => _customTemplates = next);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Шаблон удален'.tr)),
    );
  }

  /// Проверка обязательных подстановок в SMS-шаблонах.
  static List<String> _validateTemplates(Map<String, String> templates) {
    final errors = <String>[];
    final requiredPlaceholders = ['{name}'];
    final requiredKeys = [
      'booking_confirm',
      'day_before',
      'job_done',
      'on_way',
      'cancel_save',
      'reschedule_ask',
    ];
    for (final key in requiredKeys) {
      final text = (templates[key] ?? '').trim();
      for (final ph in requiredPlaceholders) {
        if (!text.contains(ph)) {
          errors.add('$key: отсутствует $ph');
        }
      }
    }
    return errors;
  }

  Future<bool> _save() async {
    final templates = <String, String>{
      'on_way': _onWay.text.trim(),
      'part_ordered': _parts.text.trim(),
      'job_done': _done.text.trim(),
      'booking_confirm': _book.text.trim(),
      'day_before': _day.text.trim(),
      'cancel_save': _cancelSave.text.trim(),
      'reschedule_ask': _rescheduleAsk.text.trim(),
    };
    final validationErrors = _validateTemplates(templates);
    if (validationErrors.isNotEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Проверьте шаблоны: ${validationErrors.join(', ')}'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return false;
    }
    await SettingsService.saveSmsTemplates(templates);
    await SettingsService.updateConfig('googleReviewUrl', _reviewUrl.text.trim());
    final current = await SettingsService.loadDocumentSettings();
    await SettingsService.saveDocumentSettings(
      current.copyWith(
        invoiceSms: _invoiceSms.text.trim().isEmpty
            ? DocumentSettings.defaults.invoiceSms
            : _invoiceSms.text.trim(),
        estimateSms: _estimateSms.text.trim().isEmpty
            ? DocumentSettings.defaults.estimateSms
            : _estimateSms.text.trim(),
        receiptSms: _receiptSms.text.trim().isEmpty
            ? DocumentSettings.defaults.receiptSms
            : _receiptSms.text.trim(),
        paySms: _paySms.text.trim().isEmpty
            ? DocumentSettings.kDefaultPaySms
            : _paySms.text.trim(),
      ),
    );
    if (!mounted) return false;
    setState(() => _dirty = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Шаблоны сохранены'.tr),
        backgroundColor: Colors.green,
      ),
    );
    return true;
  }

  String _preview(TextEditingController c) {
    final t = c.text.trim();
    if (t.isEmpty) return '—';
    return t.length > 24 ? '${t.substring(0, 24)}…' : t;
  }

  TextEditingController? _controllerFor(_TplSection section) {
    switch (section) {
      case _TplSection.booking:
        return _book;
      case _TplSection.reminder:
        return _day;
      case _TplSection.cancel:
        return _cancelSave;
      case _TplSection.reschedule:
        return _rescheduleAsk;
      case _TplSection.onWay:
        return _onWay;
      case _TplSection.parts:
        return _parts;
      case _TplSection.done:
        return _done;
      case _TplSection.review:
        return _reviewUrl;
      case _TplSection.invoice:
        return _invoiceSms;
      case _TplSection.estimate:
        return _estimateSms;
      case _TplSection.receipt:
        return _receiptSms;
      case _TplSection.pay:
        return _paySms;
      case _TplSection.hub:
        return null;
    }
  }

  String _titleFor(_TplSection section) {
    switch (section) {
      case _TplSection.booking:
        return 'Booking confirm';
      case _TplSection.reminder:
        return 'Day-before';
      case _TplSection.cancel:
        return 'Cancel (0)';
      case _TplSection.reschedule:
        return 'Reschedule (5)';
      case _TplSection.onWay:
        return 'On my way';
      case _TplSection.parts:
        return 'Waiting for part';
      case _TplSection.done:
        return 'Job done';
      case _TplSection.review:
        return 'Google review URL';
      case _TplSection.invoice:
        return 'Invoice SMS';
      case _TplSection.estimate:
        return 'Estimate SMS';
      case _TplSection.receipt:
        return 'Receipt SMS';
      case _TplSection.pay:
        return 'Payment link SMS';
      case _TplSection.hub:
        return 'Шаблоны сообщений'.tr;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return SettingsPageScaffold(
        title: 'Шаблоны сообщений'.tr,
        body: Center(child: CircularProgressIndicator(color: AppColors.accent)),
      );
    }
    if (widget._section == _TplSection.hub) {
      return SettingsPageScaffold(
        title: 'Шаблоны сообщений'.tr,
        dirty: _dirty,
        onSave: _save,
        body: ListView(
          padding: const EdgeInsets.only(top: 12, bottom: 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'English SMS to clients. {name} {date} {time} {address} {review} {url}'.tr,
                style: const TextStyle(color: Colors.black54, fontSize: 12),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Мои шаблоны'.tr,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _addCustomTemplate,
                    icon: const Icon(Icons.add, size: 20),
                    label: Text('Добавить шаблон'.tr),
                  ),
                ],
              ),
            ),
            if (_customTemplates.isEmpty)
              Container(
                margin: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: const [
                    BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2)),
                  ],
                ),
                child: Center(
                  child: Column(
                    children: [
                      Icon(Icons.chat_bubble_outline, size: 36, color: Colors.grey.shade400),
                      const SizedBox(height: 8),
                      Text(
                        'Нет своих шаблонов'.tr,
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                      const SizedBox(height: 10),
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
                        child: Icon(Icons.chat_bubble_outline, color: AppColors.primary),
                      ),
                      title: Text(
                        _customTemplates[i]['title'] ?? '',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                      subtitle: Text(
                        _customTemplates[i]['body'] ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Изменить'.tr,
                            icon: const Icon(Icons.edit_outlined, color: Colors.blueGrey, size: 20),
                            onPressed: () => _editCustomTemplate(i),
                          ),
                          IconButton(
                            tooltip: 'Удалить'.tr,
                            icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                            onPressed: () => _deleteCustomTemplate(i),
                          ),
                        ],
                      ),
                      onTap: () => _editCustomTemplate(i),
                    ),
                    if (i < _customTemplates.length - 1)
                      const Divider(height: 1, indent: 64, color: Colors.black12),
                  ],
                ],
              ),
            const SizedBox(height: 8),
            SettingsTileSection(
              title: 'Визиты'.tr,
              tiles: [
                _tile(_TplSection.booking, Icons.event_available, Colors.blue),
                _tile(_TplSection.reminder, Icons.notifications, Colors.indigo),
                _tile(_TplSection.cancel, Icons.cancel_outlined, Colors.red),
                _tile(_TplSection.reschedule, Icons.event_repeat, Colors.orange),
              ],
            ),
            SettingsTileSection(
              title: 'В пути'.tr,
              tiles: [
                _tile(_TplSection.onWay, Icons.near_me, Colors.teal),
                _tile(_TplSection.parts, Icons.local_shipping_outlined, Colors.brown),
                _tile(_TplSection.done, Icons.check_circle_outline, Colors.green),
                _tile(_TplSection.review, Icons.star_outline, Colors.amber),
              ],
            ),
            SettingsTileSection(
              title: 'Документы'.tr,
              tiles: [
                _tile(_TplSection.invoice, Icons.receipt_long, AppColors.primary),
                _tile(_TplSection.estimate, Icons.description, Colors.teal),
                _tile(_TplSection.receipt, Icons.receipt, Colors.blueGrey),
                _tile(_TplSection.pay, Icons.link, const Color(0xFF635BFF)),
              ],
            ),
          ],
        ),
      );
    }
    final ctrl = _controllerFor(widget._section)!;
    final lines = widget._section == _TplSection.review ? 2 : 6;
    return SettingsPageScaffold(
      title: _titleFor(widget._section),
      dirty: _dirty,
      onSave: _save,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: ctrl,
            maxLines: lines,
            decoration: InputDecoration(
              labelText: _titleFor(widget._section),
              border: const OutlineInputBorder(),
              filled: true,
              fillColor: Colors.white,
              alignLabelWithHint: true,
            ),
          ),
        ],
      ),
    );
  }

  SettingsHubTile _tile(_TplSection section, IconData icon, Color color) {
    final ctrl = _controllerFor(section)!;
    return SettingsHubTile(
      title: _titleFor(section),
      subtitle: _preview(ctrl),
      icon: icon,
      color: color,
      onTap: () => _open(section),
    );
  }
}
