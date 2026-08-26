import 'package:flutter/material.dart';

import '../../../core/l10n/app_locale.dart';
import '../../../core/utils/app_time_picker.dart';
import '../../../services/morning_briefing_service.dart';
import '../../../services/on_the_way_service.dart';
import '../../../services/settings_service.dart';
import '../../../services/twilio_service.dart';
import '../../../shared/widgets/app_bar_save.dart';
import '../../../shared/widgets/email_field.dart';
import '../widgets/company_name_dialog.dart';
import '../widgets/settings_ui.dart';

class CommunicationSettingsPage extends StatefulWidget {
  const CommunicationSettingsPage({super.key});

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
  List<String> _watchedSenders = [];
  String _savedGmailUser = '';
  List<String> _savedWatchers = [];
  bool _gmailSaved = false;
  bool _gmailListening = false;

  @override
  void initState() {
    super.initState();
    _checkPhone();
    _loadSmsHeader();
    _loadFlags();
    _loadGmail();
  }

  @override
  void dispose() {
    _gmailUserCtrl.dispose();
    _gmailPassCtrl.dispose();
    _watchCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkPhone() async {
    final enabled = await TwilioService.isPhoneAccountEnabled();
    if (mounted) setState(() => _phoneAccountEnabled = enabled);
  }

  Future<void> _loadSmsHeader() async {
    final docs = await SettingsService.loadDocumentSettings();
    if (!mounted) return;
    setState(() => _smsHeader = docs.smsHeader);
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
      _savedWatchers = List<String>.from(watched);
    });
  }

  Future<void> _setMorning(bool value) async {
    setState(() => _morning = value);
    await SettingsService.updateConfig('morningBriefingEnabled', value);
    await MorningBriefingService.refresh();
  }

  Future<void> _setOnWayGeo(bool value) async {
    setState(() => _onWayGeo = value);
    await SettingsService.updateConfig('onTheWayPromptEnabled', value);
    if (!value) await OnTheWayService.instance.stop();
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
      appPassword: _gmailPassCtrl.text.trim().isEmpty ? null : _gmailPassCtrl.text.trim(),
    );
    await SettingsService.updateConfigMap({
      'watchedEmailSenders': _watchedSenders,
    });
    if (!mounted) return false;
    _gmailPassCtrl.clear();
    setState(() {
      _savingGmail = false;
      _gmailSaved = true;
      _savedGmailUser = user;
      _savedWatchers = List<String>.from(_watchedSenders);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Gmail сохранён'.tr), backgroundColor: Colors.green),
    );
    return true;
  }

  bool get _gmailDirty {
    if (_gmailPassCtrl.text.trim().isNotEmpty) return true;
    if (_gmailUserCtrl.text.trim() != _savedGmailUser) return true;
    if (_watchedSenders.join('|') != _savedWatchers.join('|')) return true;
    return false;
  }

  void _addWatcher() {
    final email = _watchCtrl.text.trim().toLowerCase();
    if (!email.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Укажите email отправителя'.tr)),
      );
      return;
    }
    if (_watchedSenders.contains(email)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Этот адрес уже в списке'.tr)),
      );
      return;
    }
    setState(() {
      _watchedSenders = [..._watchedSenders, email];
      _watchCtrl.clear();
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
    await SettingsService.updateConfigMap({
      'morningBriefingHour': _morningHour,
      'eveningBriefingHour': _eveningHour,
    });
    await MorningBriefingService.refresh();
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
    await SettingsService.updateConfigMap({
      'onTheWayMeters': meters,
      'onTheWayText': text,
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
            Future<void> persist() async {
              if (selected.isEmpty) selected = ['24h'];
              setState(() {
                _reminderOffsets = List<String>.from(selected);
                _reminderMorningHour = morningHour;
                _reminderSms = true;
              });
              await SettingsService.updateConfigMap({
                'reminderSmsEnabled': true,
                'reminderOffsets': selected,
                'reminderMorningHour': morningHour,
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
                              : _offsetLabel(key).replaceAll(RegExp(r' \(.*\)$'), ''),
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
                          persist();
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
                          await persist();
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
    await SettingsService.updateSmsHeader(saved);
    if (!mounted) return;
    setState(() => _smsHeader = saved);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Связь'.tr,
      dirty: _gmailDirty,
      onSave: _saveGmail,
      actions: [
        AppBarSaveButton(
          dirty: _gmailDirty,
          saving: _savingGmail,
          onPressed: () { _saveGmail(); },
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.only(top: 20, bottom: 40),
        children: [
          SettingsGroup(
            children: [
              SettingsRow(
                title: _phoneAccountEnabled == false
                    ? 'Звонки не работают'.tr
                    : 'Звонки Twilio'.tr,
                subtitle: _phoneAccountEnabled == false
                    ? 'Разрешите приложению свои звонки, чтобы входящие открывались в CRM'.tr
                    : _phoneAccountEnabled == true
                        ? 'Входящие принимаются в приложении'.tr
                        : 'Проверка статуса…'.tr,
                icon: _phoneAccountEnabled == false
                    ? Icons.phone_disabled
                    : Icons.phone_in_talk,
                iconColor:
                    _phoneAccountEnabled == false ? Colors.red : Colors.green,
                trailing: _phoneAccountEnabled == true
                    ? const Icon(Icons.check_circle, color: Colors.green)
                    : _phoneAccountEnabled == null
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                onTap: _checkPhone,
              ),
              SettingsRow(
                title: 'Разрешения звонков Android'.tr,
                subtitle:
                    'Samsung не показывает VoIP рядом с SIM. Ищите FIX APPLIANCE, не «телефон по умолчанию».'.tr,
                icon: Icons.settings_phone,
                iconColor: Colors.blueGrey,
                showDivider: false,
                onTap: () async {
                  await TwilioService.openPhoneAccountSettings();
                  if (!context.mounted) return;
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
                },
              ),
            ],
          ),
          SettingsGroup(
            children: [
              SettingsRow(
                title: 'Шапка SMS'.tr,
                subtitle: _smsHeader.isEmpty
                    ? 'Без шапки — только текст сообщения'.tr
                    : _smsHeader,
                icon: Icons.text_fields,
                iconColor: Colors.indigo,
                onTap: _editSmsHeader,
              ),
              SettingsRow(
                title: 'Заявки утром и вечером'.tr,
                subtitle:
                    '${'Утром'.tr} ${_hh(_morningHour)}, ${'вечером'.tr} ${_hh(_eveningHour)}',
                icon: Icons.wb_sunny_outlined,
                iconColor: Colors.orange,
                trailing: Switch(value: _morning, onChanged: _setMorning),
                onTap: _editBriefingTimes,
              ),
              SettingsRow(
                title: 'SMS «я в пути»'.tr,
                subtitle:
                    '${'После'.tr} ${(_onWayMeters / 1000).toStringAsFixed(_onWayMeters % 1000 == 0 ? 0 : 1)} ${'км'.tr}',
                icon: Icons.near_me,
                iconColor: Colors.teal,
                trailing: Switch(value: _onWayGeo, onChanged: _setOnWayGeo),
                onTap: _editOnWay,
              ),
              SettingsRow(
                title: 'SMS при записи'.tr,
                subtitle: 'После вашего подтверждения заявки. Клиент отвечает 1 / 0 / 5. С почты — письмо на e-mail.'.tr,
                icon: Icons.event_available,
                iconColor: Colors.blue,
                trailing: Switch(
                  value: _bookingSms,
                  onChanged: (value) {
                    setState(() => _bookingSms = value);
                    SettingsService.updateConfig('bookingSmsEnabled', value);
                  },
                ),
              ),
              SettingsRow(
                title: 'Напоминание о визите'.tr,
                subtitle: _reminderSubtitle,
                icon: Icons.notifications_active_outlined,
                iconColor: Colors.indigo,
                trailing: Switch(
                  value: _reminderSms,
                  onChanged: (value) {
                    setState(() => _reminderSms = value);
                    SettingsService.updateConfig('reminderSmsEnabled', value);
                  },
                ),
                onTap: _editReminders,
              ),
              SettingsRow(
                title: 'Авто-отзыв после работы'.tr,
                subtitle: 'SMS со ссылкой на Google после «Завершено»'.tr,
                icon: Icons.star_outline,
                iconColor: Colors.amber.shade800,
                showDivider: false,
                trailing: Switch(
                  value: _autoReview,
                  onChanged: (value) {
                    setState(() => _autoReview = value);
                    SettingsService.updateConfig('autoReviewSmsEnabled', value);
                  },
                ),
              ),
            ],
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: Text(
              'GMAIL'.tr,
              style: TextStyle(
                color: Colors.grey,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.1,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
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
                    labelText: _gmailSaved ? 'Новый пароль приложения'.tr : 'Пароль приложения'.tr,
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
                  'Заявки составляются только с этих адресов.'.tr,
                  style: const TextStyle(color: Colors.black54),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: EmailAutocompleteField(
                        controller: _watchCtrl,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _addWatcher(),
                        decoration: InputDecoration(
                          labelText: 'Добавить адрес отправителя'.tr,
                          prefixIcon: const Icon(Icons.mark_email_unread_outlined),
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
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final email in _watchedSenders)
                        InputChip(
                          label: Text(email),
                          onDeleted: () {
                            setState(() {
                              _watchedSenders = [
                                for (final item in _watchedSenders)
                                  if (item != email) item,
                              ];
                            });
                          },
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
