import 'package:flutter/material.dart';

import '../../../services/morning_briefing_service.dart';
import '../../../services/on_the_way_service.dart';
import '../../../services/settings_service.dart';
import '../../../services/twilio_service.dart';
import '../widgets/company_name_dialog.dart';
import '../widgets/settings_ui.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../shared/widgets/email_field.dart';
import 'message_templates_page.dart';

class CommunicationSettingsPage extends StatefulWidget {
  const CommunicationSettingsPage({super.key});

  @override
  State<CommunicationSettingsPage> createState() =>
      _CommunicationSettingsPageState();
}

class _CommunicationSettingsPageState extends State<CommunicationSettingsPage> {
  bool? _phoneAccountEnabled;
  bool _savingGmail = false;
  String _smsHeader = 'fixappliance.ca';
  bool _morning = true;
  bool _onWayGeo = true;
  bool _bookingSms = true;
  bool _reminderSms = true;
  bool _autoReview = true;
  final _gmailUserCtrl = TextEditingController();
  final _gmailPassCtrl = TextEditingController();
  bool _gmailSaved = false;

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
    setState(() {
      _morning = SettingsService.boolFlag(config, 'morningBriefingEnabled');
      _onWayGeo = SettingsService.boolFlag(config, 'onTheWayPromptEnabled');
      _bookingSms = SettingsService.readBookingSmsEnabled(config);
      _reminderSms = SettingsService.readReminderSmsEnabled(config);
      _autoReview = SettingsService.readAutoReviewSmsEnabled(config);
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
    setState(() => _gmailSaved = (gmail['appPassword'] ?? '').toString().isNotEmpty);
  }

  Future<void> _saveGmail() async {
    final user = _gmailUserCtrl.text.trim();
    if (!user.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Укажите Gmail'.tr), backgroundColor: Colors.red),
      );
      return;
    }
    setState(() => _savingGmail = true);
    await SettingsService.saveGmailSettings(
      user: user,
      appPassword: _gmailPassCtrl.text.trim().isEmpty ? null : _gmailPassCtrl.text.trim(),
    );
    if (!mounted) return;
    _gmailPassCtrl.clear();
    setState(() {
      _savingGmail = false;
      _gmailSaved = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Gmail сохранён'.tr), backgroundColor: Colors.green),
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
                    'В 7:00 — сегодняшний день. В 19:00 — завтра и что взять.'.tr,
                icon: Icons.wb_sunny_outlined,
                iconColor: Colors.orange,
                trailing: Switch(value: _morning, onChanged: _setMorning),
              ),
              SettingsRow(
                title: 'SMS «я в пути»'.tr,
                subtitle: 'Спросить после 2 км от клиента'.tr,
                icon: Icons.near_me,
                iconColor: Colors.teal,
                trailing: Switch(value: _onWayGeo, onChanged: _setOnWayGeo),
              ),
              SettingsRow(
                title: 'SMS при записи'.tr,
                subtitle: 'Подтверждение даты и ответ 1 / 2'.tr,
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
                title: 'Напоминание за сутки'.tr,
                subtitle: 'Авто-SMS накануне визита'.tr,
                icon: Icons.notifications_active_outlined,
                iconColor: Colors.indigo,
                trailing: Switch(
                  value: _reminderSms,
                  onChanged: (value) {
                    setState(() => _reminderSms = value);
                    SettingsService.updateConfig('reminderSmsEnabled', value);
                  },
                ),
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
                  'В CRM попадают только письма клиентам из приложения и их ответы. Остальная почта Gmail не загружается. Пароль — «Пароль приложения» Google, не обычный пароль от почты.'.tr,
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
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: _savingGmail ? null : _saveGmail,
                    child: Text(_savingGmail ? 'Сохранение…'.tr : 'Сохранить Gmail'.tr),
                  ),
                ),
              ],
            ),
          ),
          SettingsGroup(
            children: [
              SettingsRow(
                title: 'Шаблоны сообщений'.tr,
                subtitle: 'Все SMS клиенту, всегда English'.tr,
                icon: Icons.sms_outlined,
                iconColor: Colors.blue,
                showDivider: false,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const MessageTemplatesPage()),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
