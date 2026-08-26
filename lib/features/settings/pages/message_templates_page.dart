import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../models/document_settings.dart';
import '../../../services/settings_service.dart';
import '../../../shared/widgets/app_bar_save.dart';
import '../widgets/settings_ui.dart';

/// Все клиентские SMS в одном месте. Тексты всегда английские.
class MessageTemplatesPage extends StatefulWidget {
  const MessageTemplatesPage({super.key});

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
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _onWay.dispose();
    _parts.dispose();
    _done.dispose();
    _book.dispose();
    _day.dispose();
    _cancelSave.dispose();
    _rescheduleAsk.dispose();
    _reviewUrl.dispose();
    _invoiceSms.dispose();
    _estimateSms.dispose();
    _receiptSms.dispose();
    _paySms.dispose();
    super.dispose();
  }

  void _onEdit() {
    if (_loading || _dirty) return;
    setState(() => _dirty = true);
  }

  Future<void> _load() async {
    final templates = await SettingsService.loadSmsTemplates();
    final docs = await SettingsService.loadDocumentSettings();
    final config = await SettingsService.loadConfig();
    if (!mounted) return;
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

  Future<bool> _save() async {
    setState(() => _saving = true);
    await SettingsService.saveSmsTemplates({
      'on_way': _onWay.text.trim(),
      'part_ordered': _parts.text.trim(),
      'job_done': _done.text.trim(),
      'booking_confirm': _book.text.trim(),
      'day_before': _day.text.trim(),
      'cancel_save': _cancelSave.text.trim(),
      'reschedule_ask': _rescheduleAsk.text.trim(),
    });
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
    setState(() {
      _saving = false;
      _dirty = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Шаблоны сохранены'.tr),
        backgroundColor: Colors.green,
      ),
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Шаблоны сообщений'.tr,
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
          ? Center(child: CircularProgressIndicator(color: AppColors.accent))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
              children: [
                Text(
                  'Эти тексты уходят клиенту и всегда на английском, даже если интерфейс русский.'.tr,
                  style: const TextStyle(color: Colors.black54),
                ),
                const SizedBox(height: 8),
                Text(
                  'В SMS ссылку нельзя спрятать за кнопку — она идёт отдельной строкой Pay here.'.tr,
                  style: const TextStyle(color: Colors.black54),
                ),
                const SizedBox(height: 16),
                _field('Booking confirm', _book),
                _field('Day-before reminder', _day),
                _field('After client sends 0 (10% / 25% / move)', _cancelSave),
                _field('After client sends 5 (ask new time)', _rescheduleAsk),
                _field('On my way', _onWay),
                _field('Waiting for part', _parts),
                _field('Job done', _done),
                _field('Google review URL  {review}', _reviewUrl, lines: 1),
                const SizedBox(height: 8),
                Text(
                  '{name} {date} {time} {address} {review} {company} {amount} {url} {items} {total} {due}',
                  style: const TextStyle(color: Colors.black45, fontSize: 12),
                ),
                const SizedBox(height: 16),
                _field('Invoice SMS', _invoiceSms),
                _field('Estimate SMS', _estimateSms),
                _field('Receipt SMS', _receiptSms),
                _field('Payment link SMS', _paySms),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Widget _field(String label, TextEditingController controller, {int lines = 4}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        maxLines: lines,
        decoration: InputDecoration(
          labelText: label,
          alignLabelWithHint: true,
          border: const OutlineInputBorder(),
          filled: true,
          fillColor: Colors.white,
        ),
      ),
    );
  }
}
