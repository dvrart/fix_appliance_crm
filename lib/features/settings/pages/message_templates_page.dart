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
