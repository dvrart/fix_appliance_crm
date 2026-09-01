import 'package:flutter/material.dart';

import '../../../core/l10n/app_locale.dart';
import '../../../core/utils/app_time_picker.dart';
import '../../../services/morning_briefing_service.dart';
import '../../../services/notification_service.dart';
import '../../../services/on_the_way_service.dart';
import '../../../services/settings_service.dart';
import '../../../services/twilio_service.dart';
import '../../../shared/widgets/email_field.dart';
import '../widgets/company_name_dialog.dart';
import '../widgets/settings_ui.dart';

enum _CommSection { hub, calls, sms, alerts, gmail }

/// Связь: сначала плитки, внутри — свои экраны (звонки / SMS / уведомления / Gmail).
class CommunicationSettingsPage extends StatefulWidget {
  const CommunicationSettingsPage({super.key}) : _sectionIndex = 0;

  const CommunicationSettingsPage.calls({super.key}) : _sectionIndex = 1;

  const CommunicationSettingsPage.sms({super.key}) : _sectionIndex = 2;

  const CommunicationSettingsPage.alerts({super.key}) : _sectionIndex = 3;

  const CommunicationSettingsPage.gmail({super.key}) : _sectionIndex = 4;

  const CommunicationSettingsPage._at(this._sectionIndex, {super.key});

  final int _sectionIndex;

  _CommSection get _section => _CommSection.values[_sectionIndex.clamp(0, 4)];

  @override
  State<CommunicationSettingsPage> createState() =>
      _CommunicationSettingsPageState();
}

class _CommunicationSettingsPageState extends State<CommunicationSettingsPage> {
  bool? _phoneAccountEnabled;
  bool _savingGmail = false;
  String _smsHeader = 'fix-appliance.ca';
  bool _morning = true;
  bool _onWayGeo = true;
  bool _bookingSms = true;
  bool _reminderSms = true;
  bool _autoReview = true;
  List<String> _reminderOffsets = const ['24h'];
  int _morningHour = 7;
  int _eveningHour = 19;
  int _reminderMorningHour = 8;
  int _onWayMeters = 2000;
  String _onWayText = '';
  final _gmailUserCtrl = TextEditingController();
  final _gmailPassCtrl = TextEditingController();
  final _watchCtrl = TextEditingController();
  final _watchNameCtrl = TextEditingController();
  List<WatchedEmailSender> _watchedSenders = [];
  String _savedGmailUser = '';
  List<WatchedEmailSender> _savedWatchers = [];
  bool _gmailSaved = false;
  bool _gmailListening = false;
  bool _notificationsEnabled = true;
  String _gmailUserHint = '';
  String _savedSmsHeader = 'fix-appliance.ca';
  bool _savedMorning = true;
  bool _savedOnWayGeo = true;
  bool _savedBookingSms = true;
  bool _savedReminderSms = true;
  bool _savedAutoReview = true;
  List<String> _savedReminderOffsets = const ['24h'];
  int _savedMorningHour = 7;
  int _savedEveningHour = 19;
  int _savedReminderMorningHour = 8;
  int _savedOnWayMeters = 2000;
  String _savedOnWayText = '';

  @override
  void initState() {
    super.initState();
    switch (widget._section) {
      case _CommSection.hub:
        _checkPhone();
        _loadSmsHeader();
        _loadFlags();
        _loadGmailHint();
        _loadNotificationAccess();
        break;
      case _CommSection.calls:
        _checkPhone();
        break;
      case _CommSection.sms:
        _loadSmsHeader();
        _loadFlags();
        break;
      case _CommSection.alerts:
        _loadFlags();
        _loadNotificationAccess();
        break;
      case _CommSection.gmail:
        _loadFlags();
        _loadGmail();
        break;
    }
  }

  Future<void> _loadGmailHint() async {
    final gmail = await SettingsService.loadGmailSettings();
    if (!mounted) return;
    setState(() {
      _gmailUserHint = (gmail['user'] ?? '').toString().trim();
      _gmailSaved = (gmail['appPassword'] ?? '').toString().isNotEmpty;
    });
  }

  Future<void> _loadNotificationAccess() async {
    final enabled = await NotificationService.areNotificationsEnabled();
    if (mounted) setState(() => _notificationsEnabled = enabled);
  }

  @override
  void dispose() {
    _gmailUserCtrl.dispose();
    _gmailPassCtrl.dispose();
    _watchCtrl.dispose();
    _watchNameCtrl.dispose();
    super.dispose();
  }

  void _open(_CommSection section) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CommunicationSettingsPage._at(section.index),
      ),
    ).then((_) {
      if (!mounted || widget._section != _CommSection.hub) return;
      _checkPhone();
      _loadSmsHeader();
      _loadFlags();
      _loadGmailHint();
      _loadNotificationAccess();
    });
  }

  Future<void> _checkPhone() async {
    final enabled = await TwilioService.isPhoneAccountEnabled();
    if (mounted) setState(() => _phoneAccountEnabled = enabled);
  }

  Future<void> _loadSmsHeader() async {
    final docs = await SettingsService.loadDocumentSettings();
    if (!mounted) return;
    setState(() {
      _smsHeader = docs.smsHeader;
      _savedSmsHeader = docs.smsHeader;
    });
  }

  Future<void> _loadFlags() async {
    final config = await SettingsService.loadConfig();
    if (!mounted) return;
    final watched = SettingsService.readWatchedEmailSenders(config);
    if (!mounted) return;
    setState(() {
      _morning = SettingsService.boolFlag(config, 'morningBriefingEnabled');
      _onWayGeo = SettingsService.boolFlag(config, 'onTheWayPromptEnabled');
      _bookingSms = SettingsService.readBookingSmsEnabled(config);
      _reminderSms = SettingsService.readReminderSmsEnabled(config);
      _autoReview = SettingsService.readAutoReviewSmsEnabled(config);
      _reminderOffsets = SettingsService.readReminderOffsets(config);
      _morningHour = SettingsService.readMorningBriefingHour(config);
      _eveningHour = SettingsService.readEveningBriefingHour(config);
      _reminderMorningHour = SettingsService.readReminderMorningHour(config);
      _onWayMeters = SettingsService.readOnTheWayMeters(config);
      _onWayText = SettingsService.readOnTheWayText(config);
      _watchedSenders = watched;
      _savedWatchers = List<WatchedEmailSender>.from(watched);
      _savedMorning = _morning;
      _savedOnWayGeo = _onWayGeo;
      _savedBookingSms = _bookingSms;
      _savedReminderSms = _reminderSms;
      _savedAutoReview = _autoReview;
      _savedReminderOffsets = List<String>.from(_reminderOffsets);
      _savedMorningHour = _morningHour;
      _savedEveningHour = _eveningHour;
      _savedReminderMorningHour = _reminderMorningHour;
      _savedOnWayMeters = _onWayMeters;
      _savedOnWayText = _onWayText;
    });
  }

  String _offsetsKey(List<String> items) {
    final copy = [...items]..sort();
    return copy.join(',');
  }

  bool get _smsDirty =>
      _smsHeader != _savedSmsHeader ||
      _bookingSms != _savedBookingSms ||
      _reminderSms != _savedReminderSms ||
      _autoReview != _savedAutoReview ||
      _onWayMeters != _savedOnWayMeters ||
      _onWayText != _savedOnWayText ||
      _reminderMorningHour != _savedReminderMorningHour ||
      _offsetsKey(_reminderOffsets) != _offsetsKey(_savedReminderOffsets);

  bool get _alertsDirty =>
      _morning != _savedMorning ||
      _onWayGeo != _savedOnWayGeo ||
      _morningHour != _savedMorningHour ||
      _eveningHour != _savedEveningHour;

  void _setMorning(bool value) {
    setState(() => _morning = value);
  }

  void _setOnWayGeo(bool value) {
    setState(() => _onWayGeo = value);
  }

  Future<bool> _saveSms() async {
    if (_smsHeader != _savedSmsHeader) {
      await SettingsService.updateSmsHeader(_smsHeader);
    }
    await SettingsService.updateConfigMap({
      'bookingSmsEnabled': _bookingSms,
      'reminderSmsEnabled': _reminderSms,
      'autoReviewSmsEnabled': _autoReview,
      'reminderOffsets': _reminderOffsets,
      'reminderMorningHour': _reminderMorningHour,
      'onTheWayMeters': _onWayMeters,
      'onTheWayText': _onWayText,
    });
    if (!mounted) return true;
    setState(() {
      _savedSmsHeader = _smsHeader;
      _savedBookingSms = _bookingSms;
      _savedReminderSms = _reminderSms;
      _savedAutoReview = _autoReview;
      _savedReminderOffsets = List<String>.from(_reminderOffsets);
      _savedReminderMorningHour = _reminderMorningHour;
      _savedOnWayMeters = _onWayMeters;
      _savedOnWayText = _onWayText;
    });
    return true;
  }

  Future<bool> _saveAlerts() async {
    await SettingsService.updateConfigMap({
      'morningBriefingEnabled': _morning,
      'onTheWayPromptEnabled': _onWayGeo,
      'morningBriefingHour': _morningHour,
      'eveningBriefingHour': _eveningHour,
    });
    await MorningBriefingService.refresh();
    if (!_onWayGeo) await OnTheWayService.instance.stop();
    if (!mounted) return true;
    setState(() {
      _savedMorning = _morning;
      _savedOnWayGeo = _onWayGeo;
      _savedMorningHour = _morningHour;
      _savedEveningHour = _eveningHour;
    });
    return true;
  }

  Future<void> _loadGmail() async {
    final gmail = await SettingsService.loadGmailSettings();
    final docs = await SettingsService.loadDocumentSettings();
    if (!mounted) return;
    final savedUser = (gmail['user'] ?? '').toString();
    _gmailUserCtrl.text = savedUser.isNotEmpty ? savedUser : docs.companyEmail;
    setState(() {
      _gmailSaved = (gmail['appPassword'] ?? '').toString().isNotEmpty;
      _savedGmailUser = _gmailUserCtrl.text.trim();
    });
    if (_gmailListening) return;
    _gmailListening = true;
    for (final controller in [_gmailUserCtrl, _gmailPassCtrl]) {
      controller.addListener(() {
        if (mounted) setState(() {});
      });
    }
  }

  Future<bool> _saveGmail() async {
    final user = _gmailUserCtrl.text.trim();
    if (!user.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Укажите Gmail'.tr), backgroundColor: Colors.red),
      );
      return false;
    }
    setState(() => _savingGmail = true);
    await SettingsService.saveGmailSettings(
      user: user,
      appPassword:
          _gmailPassCtrl.text.trim().isEmpty ? null : _gmailPassCtrl.text.trim(),
    );
    await SettingsService.updateConfigMap({
      'watchedEmailSenders':
          SettingsService.serializeWatchedEmailSenders(_watchedSenders),
    });
    if (!mounted) return false;
    _gmailPassCtrl.clear();
    setState(() {
      _savingGmail = false;
      _gmailSaved = true;
      _savedGmailUser = user;
      _savedWatchers = List<WatchedEmailSender>.from(_watchedSenders);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Gmail сохранён'.tr), backgroundColor: Colors.green),
    );
    return true;
  }

  String _watchKey(List<WatchedEmailSender> list) =>
      list.map((s) => '${s.email}|${s.name.trim()}').join(';');

  bool get _gmailDirty {
    if (_gmailPassCtrl.text.trim().isNotEmpty) return true;
    if (_gmailUserCtrl.text.trim() != _savedGmailUser) return true;
    if (_watchKey(_watchedSenders) != _watchKey(_savedWatchers)) return true;
    return false;
  }

  void _addWatcher() {
    final email = _watchCtrl.text.trim().toLowerCase();
    final name = _watchNameCtrl.text.trim();
    if (!email.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Укажите email отправителя'.tr)),
      );
      return;
    }
    if (_watchedSenders.any((s) => s.email == email)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Этот адрес уже в списке'.tr)),
      );
      return;
    }
    setState(() {
      _watchedSenders = [
        ..._watchedSenders,
        WatchedEmailSender(email: email, name: name),
      ];
      _watchCtrl.clear();
      _watchNameCtrl.clear();
    });
  }

  void _setWatcherName(String email, String name) {
    setState(() {
      _watchedSenders = [
        for (final s in _watchedSenders)
          if (s.email == email)
            WatchedEmailSender(email: s.email, name: name)
          else
            s,
      ];
    });
  }

  String _hh(int hour) => '${hour.toString().padLeft(2, '0')}:00';

  String _offsetLabel(String key) {
    switch (key) {
      case '48h':
        return 'За 2 дня'.tr;
      case '24h':
        return 'За сутки'.tr;
      case 'morning':
        return '${'Утром в день визита'.tr} (${_hh(_reminderMorningHour)})';
      case '2h':
        return 'За 2 часа'.tr;
      default:
        return key;
    }
  }

  String get _reminderSubtitle {
    if (!_reminderSms) return 'Авто-SMS клиенту перед визитом'.tr;
    if (_reminderOffsets.isEmpty) return 'Выберите, когда отправлять'.tr;
    return _reminderOffsets.map(_offsetLabel).join(', ');
  }

  Future<void> _editBriefingTimes() async {
    final morning = await showAppTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _morningHour, minute: 0),
      helpText: 'Утреннее уведомление'.tr,
    );
    if (morning == null || !mounted) return;
    final evening = await showAppTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _eveningHour, minute: 0),
      helpText: 'Вечернее уведомление'.tr,
    );
    if (evening == null || !mounted) return;
    setState(() {
      _morningHour = morning.hour;
      _eveningHour = evening.hour;
    });
  }

  Future<void> _editOnWay() async {
    final kmCtrl = TextEditingController(
      text: (_onWayMeters / 1000).toStringAsFixed(
        _onWayMeters % 1000 == 0 ? 0 : 1,
      ),
    );
    final textCtrl = TextEditingController(text: _onWayText);
    final saved = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (context) => AlertDialog(
        title: Text('SMS «я в пути»'.tr),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: kmCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Расстояние, км'.tr,
                helperText: 'Спросить после этого отъезда от клиента'.tr,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: textCtrl,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: 'Текст SMS'.tr,
                hintText: 'Hi, this is your technician. I am on the way.'.tr,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Отмена'.tr),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Сохранить'.tr),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    final km = double.tryParse(kmCtrl.text.replaceAll(',', '.').trim()) ?? 2;
    final meters = (km * 1000).round().clamp(200, 20000);
    final text = textCtrl.text.trim();
    setState(() {
      _onWayMeters = meters;
      _onWayText = text;
    });
  }

  Future<void> _editReminders() async {
    var selected = List<String>.from(_reminderOffsets);
    var morningHour = _reminderMorningHour;
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheet) {
            void applyDraft() {
              if (selected.isEmpty) selected = ['24h'];
              setState(() {
                _reminderOffsets = List<String>.from(selected);
                _reminderMorningHour = morningHour;
                _reminderSms = true;
              });
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Когда слать напоминание'.tr,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Можно выбрать несколько раз. Клиенту уходит English SMS.'.tr,
                      style: TextStyle(color: Colors.grey.shade700),
                    ),
                    const SizedBox(height: 8),
                    for (final key in SettingsService.reminderOffsetKeys)
                      CheckboxListTile(
                        value: selected.contains(key),
                        title: Text(
                          key == 'morning'
                              ? 'Утром в день визита'.tr
                              : _offsetLabel(key)
                                  .replaceAll(RegExp(r' \(.*\)$'), ''),
                        ),
                        controlAffinity: ListTileControlAffinity.leading,
                        onChanged: (on) {
                          setSheet(() {
                            if (on == true) {
                              if (!selected.contains(key)) selected.add(key);
                            } else {
                              selected.remove(key);
                            }
                          });
                          applyDraft();
                        },
                      ),
                    if (selected.contains('morning'))
                      ListTile(
                        title: Text('Время утреннего SMS'.tr),
                        subtitle: Text(_hh(morningHour)),
                        trailing: const Icon(Icons.schedule),
                        onTap: () async {
                          final picked = await showAppTimePicker(
                            context: context,
                            initialTime: TimeOfDay(hour: morningHour, minute: 0),
                            helpText: 'Утреннее SMS'.tr,
                          );
                          if (picked == null) return;
                          setSheet(() => morningHour = picked.hour);
                          applyDraft();
                        },
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _editSmsHeader() async {
    final saved = await showSmsHeaderDialog(
      context: context,
      initialValue: _smsHeader,
    );
    if (saved == null || !mounted) return;
    setState(() => _smsHeader = saved);
  }

  Future<void> _openAndroidPhoneHelp() async {
    await TwilioService.openPhoneAccountSettings();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Где искать'.tr),
        content: Text(
          'Приложение не стоит в списке «Телефон / Сообщения» — это не замена звонилке Samsung.\n\n'
          'Если открылся список учёток: ищите FIX APPLIANCE и включите.\n\n'
          'Если списка нет — так и задумано. Звонки идут через приложение, не через SIM. Первый входящий может спросить разрешение на звонки — нажмите Разрешить.'.tr,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    Future.delayed(const Duration(seconds: 1), _checkPhone);
  }

  @override
  Widget build(BuildContext context) {
    switch (widget._section) {
      case _CommSection.hub:
        return _buildHub();
      case _CommSection.calls:
        return _buildCalls();
      case _CommSection.sms:
        return _buildSms();
      case _CommSection.alerts:
        return _buildAlerts();
      case _CommSection.gmail:
        return _buildGmail();
    }
  }

  Widget _buildHub() {
    final phoneOk = _phoneAccountEnabled == true;
    final phoneBad = _phoneAccountEnabled == false;
    return SettingsPageScaffold(
      title: 'Связь'.tr,
      body: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 32),
        children: [
          SettingsTileSection(
            title: 'Связь'.tr,
            tiles: [
              SettingsHubTile(
                title: 'Звонки'.tr,
                subtitle: phoneBad
                    ? 'Не работают'.tr
                    : phoneOk
                        ? 'Twilio'.tr
                        : '…',
                icon: phoneBad ? Icons.phone_disabled : Icons.phone_in_talk,
                color: phoneBad ? Colors.red : Colors.green,
                active: phoneOk,
                onTap: () => _open(_CommSection.calls),
              ),
              SettingsHubTile(
                title: 'SMS'.tr,
                subtitle: _smsHeader.isEmpty ? 'Клиентам'.tr : _smsHeader,
                icon: Icons.sms_outlined,
                color: Colors.indigo,
                onTap: () => _open(_CommSection.sms),
              ),
              SettingsHubTile(
                title: 'Уведомления'.tr,
                subtitle: _notificationsEnabled ? 'Вкл'.tr : 'Выкл'.tr,
                icon: Icons.notifications_outlined,
                color: _notificationsEnabled ? Colors.teal : Colors.red,
                active: _notificationsEnabled,
                onTap: () => _open(_CommSection.alerts),
              ),
              SettingsHubTile(
                title: 'Gmail'.tr,
                subtitle: _gmailUserHint.isEmpty
                    ? (_gmailSaved ? 'Сохранён'.tr : 'Настроить'.tr)
                    : _gmailUserHint,
                icon: Icons.mail_outline,
                color: const Color(0xFFEA4335),
                onTap: () => _open(_CommSection.gmail),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCalls() {
    return SettingsPageScaffold(
      title: 'Звонки'.tr,
      body: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 32),
        children: [
          SettingsTileSection(
            title: 'Звонки'.tr,
            tiles: [
              SettingsHubTile(
                title: _phoneAccountEnabled == false
                    ? 'Не работают'.tr
                    : 'Twilio'.tr,
                subtitle: _phoneAccountEnabled == false
                    ? 'Включить'.tr
                    : _phoneAccountEnabled == true
                        ? 'Вкл'.tr
                        : '…',
                icon: _phoneAccountEnabled == false
                    ? Icons.phone_disabled
                    : Icons.phone_in_talk,
                color: _phoneAccountEnabled == false ? Colors.red : Colors.green,
                active: _phoneAccountEnabled == true,
                onTap: _checkPhone,
              ),
              SettingsHubTile(
                title: 'Android'.tr,
                subtitle: 'Разрешения'.tr,
                icon: Icons.settings_phone,
                color: Colors.blueGrey,
                onTap: _openAndroidPhoneHelp,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSms() {
    return SettingsPageScaffold(
      title: 'SMS'.tr,
      dirty: _smsDirty,
      onSave: _saveSms,
      body: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 32),
        children: [
          SettingsTileSection(
            title: 'SMS клиентам'.tr,
            tiles: [
              SettingsHubTile(
                title: 'Шапка SMS'.tr,
                subtitle: _smsHeader.isEmpty ? 'Нет'.tr : _smsHeader,
                icon: Icons.text_fields,
                color: Colors.indigo,
                onTap: _editSmsHeader,
              ),
              SettingsHubTile(
                title: 'Я в пути'.tr,
                subtitle:
                    '${(_onWayMeters / 1000).toStringAsFixed(_onWayMeters % 1000 == 0 ? 0 : 1)} ${'км'.tr}',
                icon: Icons.near_me,
                color: Colors.teal,
                active: _onWayGeo,
                onTap: _editOnWay,
              ),
              SettingsHubTile(
                title: 'При записи'.tr,
                subtitle: _bookingSms ? 'Вкл'.tr : 'Выкл'.tr,
                icon: Icons.event_available,
                color: Colors.blue,
                active: _bookingSms,
                onTap: () => setState(() => _bookingSms = !_bookingSms),
              ),
              SettingsHubTile(
                title: 'Напоминание'.tr,
                subtitle: _reminderSms ? _reminderSubtitle : 'Выкл'.tr,
                icon: Icons.notifications_active_outlined,
                color: Colors.indigo,
                active: _reminderSms,
                onTap: _editReminders,
              ),
              SettingsHubTile(
                title: 'Отзыв'.tr,
                subtitle: _autoReview ? 'Спросить'.tr : 'Выкл'.tr,
                icon: Icons.star_outline,
                color: Colors.amber.shade800,
                active: _autoReview,
                onTap: () => setState(() => _autoReview = !_autoReview),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAlerts() {
    return SettingsPageScaffold(
      title: 'Уведомления'.tr,
      dirty: _alertsDirty,
      onSave: _saveAlerts,
      body: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 32),
        children: [
          SettingsTileSection(
            title: 'Уведомления'.tr,
            tiles: [
              SettingsHubTile(
                title: 'Утро / вечер'.tr,
                subtitle: _morning
                    ? '${_hh(_morningHour)} · ${_hh(_eveningHour)}'
                    : 'Выкл'.tr,
                icon: Icons.wb_sunny_outlined,
                color: Colors.orange,
                active: _morning,
                onTap: _editBriefingTimes,
              ),
              SettingsHubTile(
                title: 'Шторка'.tr,
                subtitle: _notificationsEnabled ? 'Вкл'.tr : 'Выкл'.tr,
                icon: Icons.notifications_outlined,
                color: _notificationsEnabled ? Colors.green : Colors.red,
                active: _notificationsEnabled,
                onTap: () async {
                  await NotificationService.openSoundSettings();
                  await _loadNotificationAccess();
                },
              ),
              SettingsHubTile(
                title: 'Батарея'.tr,
                subtitle: 'Чтобы SMS приходили, когда приложение закрыто'.tr,
                icon: Icons.battery_charging_full_outlined,
                color: Colors.deepOrange,
                onTap: () async {
                  await NotificationService.openBatterySettings();
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Разрешите работу в фоне. На Samsung: «Без ограничений» и добавьте в «Никогда не спящие».'
                            .tr,
                      ),
                    ),
                  );
                },
              ),
              SettingsHubTile(
                title: 'Я в пути'.tr,
                subtitle: _onWayGeo ? 'Вкл'.tr : 'Выкл'.tr,
                icon: Icons.near_me,
                color: Colors.teal,
                active: _onWayGeo,
                onTap: () => _setOnWayGeo(!_onWayGeo),
              ),
              SettingsHubTile(
                title: 'Брифинг'.tr,
                subtitle: _morning ? 'Вкл'.tr : 'Выкл'.tr,
                icon: Icons.toggle_on,
                color: Colors.orange,
                active: _morning,
                onTap: () => _setMorning(!_morning),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGmail() {
    return SettingsPageScaffold(
      title: 'Gmail'.tr,
      dirty: _gmailDirty,
      onSave: _saveGmail,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          Text(
            'Проверяются только письма с адресов из списка ниже. Из них составляется заявка. Ответы клиентов на ваши письма попадают в переписку. Пароль — «Пароль приложения» Google, не обычный пароль от почты.'.tr,
            style: const TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 12),
          EmailAutocompleteField(
            controller: _gmailUserCtrl,
            decoration: InputDecoration(
              labelText: 'Gmail'.tr,
              prefixIcon: const Icon(Icons.email, color: Color(0xFFEA4335)),
              border: const OutlineInputBorder(),
              filled: true,
              fillColor: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _gmailPassCtrl,
            obscureText: true,
            decoration: InputDecoration(
              labelText: _gmailSaved
                  ? 'Новый пароль приложения'.tr
                  : 'Пароль приложения'.tr,
              hintText: _gmailSaved ? 'Оставьте пустым, чтобы не менять'.tr : null,
              prefixIcon: const Icon(Icons.password),
              border: const OutlineInputBorder(),
              filled: true,
              fillColor: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Отслеживание писем'.tr,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Заявки составляются только с этих адресов. Имя переписки — как нить показывается в чате.'.tr,
            style: const TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 5,
                child: EmailAutocompleteField(
                  controller: _watchCtrl,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: 'Адрес отправителя'.tr,
                    prefixIcon: const Icon(Icons.mark_email_unread_outlined),
                    border: const OutlineInputBorder(),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 4,
                child: TextField(
                  controller: _watchNameCtrl,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _addWatcher(),
                  decoration: InputDecoration(
                    labelText: 'Имя переписки'.tr,
                    hintText: 'Например Jobber'.tr,
                    border: const OutlineInputBorder(),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 56,
                child: IconButton.filled(
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0xFFFCC520),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _addWatcher,
                  icon: const Icon(Icons.add),
                ),
              ),
            ],
          ),
          if (_watchedSenders.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final sender in _watchedSenders)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.black12),
                ),
                child: Row(
                  key: ValueKey('watch-${sender.email}'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 5,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          sender.email,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 4,
                      child: TextFormField(
                        initialValue: sender.name,
                        onChanged: (value) =>
                            _setWatcherName(sender.email, value),
                        decoration: InputDecoration(
                          labelText: 'Имя переписки'.tr,
                          isDense: true,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Удалить'.tr,
                      onPressed: () {
                        setState(() {
                          _watchedSenders = [
                            for (final item in _watchedSenders)
                              if (item.email != sender.email) item,
                          ];
                        });
                      },
                      icon: const Icon(Icons.close, color: Colors.red),
                    ),
                  ],
                ),
              ),
          ],
          if (_savingGmail)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}
