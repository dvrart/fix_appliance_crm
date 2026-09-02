import 'dart:async';
import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../core/api_keys.dart';
import '../core/l10n/app_locale.dart';
import 'inbox_push_mirror.dart';
import 'local_notification_service.dart';
import 'notification_router.dart';
import 'auth_service.dart';

/// Регистрирует FCM-токен устройства на сервере, чтобы Cloud Functions
/// могли присылать уведомления о входящих SMS, даже когда приложение свёрнуто.
class NotificationService {
  static bool _initialized = false;
  static const _deviceChannel = MethodChannel('fix_appliance/device');

  static String inboxTag({required String type, required String from}) {
    return shadeTag(type: type, from: from);
  }

  static String last10(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 10) return '';
    return digits.substring(digits.length - 10);
  }

  /// Один тег на телефон / почту: звонок и заявка с одного номера
  /// не висят в шторке двумя карточками.
  static String shadeTag({
    String type = 'sms',
    String from = '',
    String to = '',
    String callSid = '',
    String messageId = '',
    String jobId = '',
  }) {
    final phone = last10(from.isNotEmpty ? from : to);
    if (phone.isNotEmpty) {
      final tag = 'crm_inbox_$phone';
      return tag.length <= 50 ? tag : tag.substring(0, 50);
    }
    final email = from.contains('@')
        ? from.trim().toLowerCase()
        : (to.contains('@') ? to.trim().toLowerCase() : '');
    if (email.isNotEmpty) {
      final tag = 'crm_inbox_$email';
      return tag.length <= 50 ? tag : tag.substring(0, 50);
    }
    final key = from.isNotEmpty
        ? from
        : (to.isNotEmpty
            ? to
            : (callSid.isNotEmpty
                ? callSid
                : (messageId.isNotEmpty
                    ? messageId
                    : (jobId.isNotEmpty ? jobId : 'inbox'))));
    final raw = 'crm_${type.isEmpty ? 'sms' : type}_$key';
    return raw.length <= 50 ? raw : raw.substring(0, 50);
  }

  static String tagFor(Map<String, String> data) {
    return shadeTag(
      type: (data['type'] ?? 'sms').trim(),
      from: (data['from'] ?? '').trim(),
      to: (data['to'] ?? '').trim(),
      callSid: (data['callSid'] ?? data['callId'] ?? '').trim(),
      messageId: (data['messageId'] ?? '').trim(),
      jobId: (data['jobId'] ?? '').trim(),
    );
  }

  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    try {
      await LocalNotificationService.initialize();
      await LocalNotificationService.ensureInboxChannels();
      unawaited(_startBackgroundGuard());
      unawaited(InboxPushMirror.start());
      _deviceChannel.setMethodCallHandler((call) async {
        if (call.method == 'notificationTap') {
          final raw = call.arguments;
          if (raw is Map) {
            await NotificationRouter.open({
              for (final entry in raw.entries)
                '${entry.key}': '${entry.value ?? ''}',
            });
          }
        }
      });
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
      await _saveToken(await FirebaseMessaging.instance.getToken());
      FirebaseMessaging.instance.onTokenRefresh.listen(_saveToken);
      FirebaseMessaging.onMessage.listen(_onForegroundMessage);
      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        NotificationRouter.open(message.data);
      });
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) {
        await NotificationRouter.open(initial.data);
      }
      await _askUnrestrictedBatteryOnce();
      debugPrint('NotificationService: FCM-токен зарегистрирован');
    } catch (e) {
      debugPrint('NotificationService: ошибка инициализации: $e');
    }
  }

  static Future<void> openSoundSettings() async {
    try {
      await _deviceChannel.invokeMethod('openNotificationSettings');
    } catch (e) {
      debugPrint('NotificationService: openSoundSettings: $e');
    }
  }

  static Future<bool?> openBatterySettings() async {
    if (defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      return await _deviceChannel
          .invokeMethod<bool>('requestIgnoreBatteryOptimizations');
    } catch (e) {
      debugPrint('NotificationService: openBatterySettings: $e');
      return null;
    }
  }

  static Future<void> _startBackgroundGuard() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _deviceChannel.invokeMethod('startBackgroundGuard');
    } catch (e) {
      debugPrint('NotificationService: background guard: $e');
    }
  }

  static Future<bool> areNotificationsEnabled() async {
    if (defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      final enabled =
          await _deviceChannel.invokeMethod<bool>('areNotificationsEnabled');
      return enabled ?? true;
    } catch (e) {
      debugPrint('NotificationService: areNotificationsEnabled: $e');
      return true;
    }
  }

  /// Один раз подсказать включить уведомления, если система их блокирует.
  static Future<void> promptIfDisabled(BuildContext context) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('asked_enable_notifications') == true) return;
    final enabled = await areNotificationsEnabled();
    if (enabled || !context.mounted) return;
    await prefs.setBool('asked_enable_notifications', true);
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const SizedBox(height: 16),
                const Icon(Icons.notifications_off_outlined, size: 48, color: Color(0xFF14557F)),
                const SizedBox(height: 12),
                Text(
                  'Включите уведомления'.tr,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF14557F),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Без разрешения вы не увидите SMS, звонки и новые заявки, когда приложение закрыто.'
                      .tr,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade700,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () async {
                      Navigator.pop(sheetContext);
                      await openSoundSettings();
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF14557F),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: Text('Открыть настройки'.tr),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.pop(sheetContext),
                  child: Text('Позже'.tr),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static Future<void> dismissConversation({
    String? phone,
    String? email,
  }) async {
    final tags = <String>{};
    void add(String type, String from) {
      final value = from.trim();
      if (value.isEmpty) return;
      tags.add(inboxTag(type: type, from: value));
    }

    final rawPhone = (phone ?? '').trim();
    if (rawPhone.isNotEmpty) {
      add('sms', rawPhone);
      add('call', rawPhone);
      add('job', rawPhone);
      final digits = last10(rawPhone);
      if (digits.isNotEmpty) {
        tags.add(shadeTag(from: rawPhone));
        add('sms', digits);
        add('sms', '+1$digits');
        add('call', '+1$digits');
        add('job', '+1$digits');
        add('sms', '+$digits');
      }
    }
    final rawEmail = (email ?? '').trim().toLowerCase();
    if (rawEmail.contains('@')) {
      add('email', rawEmail);
      add('email', (email ?? '').trim());
    }

    await LocalNotificationService.cancelTags(tags);
  }

  static Future<void> _onForegroundMessage(RemoteMessage message) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await showRemoteMessage(message);
  }

  static Future<void> showRemoteMessage(RemoteMessage message) async {
    final data = <String, String>{
      for (final entry in message.data.entries)
        entry.key: '${entry.value ?? ''}',
    };
    final title = (message.notification?.title ?? data['title'] ?? '').toString();
    final body = (message.notification?.body ?? data['body'] ?? '').toString();
    if (title.trim().isNotEmpty) data['title'] = title;
    if (body.trim().isNotEmpty) data['body'] = body;
    await showRemoteData(data);
  }

  static Future<void> showRemoteData(Map<String, String> data) async {
    final type = (data['type'] ?? '').toString();
    final title = (data['title'] ?? '').toString();
    final body = (data['body'] ?? '').toString();
    if (title.trim().isEmpty && body.trim().isEmpty) return;
    final tag = tagFor(data);
    unawaited(InboxPushMirror.markShown(tag));
    final from = (data['from'] ?? '').toString();
    final messageId = (data['messageId'] ?? '').toString();
    final callId = (data['callSid'] ?? data['callId'] ?? '').toString();
    final jobId = (data['jobId'] ?? '').toString();
    if (type == 'email' || type == 'email_offer') {
      if (messageId.isNotEmpty) {
        unawaited(InboxPushMirror.markShown('email:$messageId'));
      }
    } else if (type == 'sms' && messageId.isNotEmpty) {
      unawaited(InboxPushMirror.markShown('sms:$messageId'));
    } else if (type == 'call' && callId.isNotEmpty) {
      unawaited(InboxPushMirror.markShown('call:$callId'));
    } else if (type == 'job' && jobId.isNotEmpty) {
      unawaited(InboxPushMirror.markShown('job:$jobId'));
    }
    if (from.isNotEmpty) {
      unawaited(InboxPushMirror.markShown(inboxTag(type: type, from: from)));
    }

    if (type == 'secretary_lesson') {
      await LocalNotificationService.showSecretaryLearn(
        title: title.isEmpty ? 'Разбор звонка секретаря' : title,
        body: body,
        tag: tag,
      );
      return;
    }

    final isConfirm = type == 'visit_confirm' ||
        type == 'estimate_confirm' ||
        title == 'Заявка подтверждена' ||
        title == 'Заявка не подтверждена' ||
        title == 'Клиент подтвердил ремонт';
    if (isConfirm) {
      await LocalNotificationService.showVisitConfirm(
        title: title.isEmpty ? 'Заявка подтверждена' : title,
        body: body,
        tag: tag,
        jobId: (data['jobId'] ?? '').toString(),
        from: (data['from'] ?? '').toString(),
      );
      return;
    }

    final isEmail = type == 'email' ||
        type == 'email_offer' ||
        type == 'shipment' ||
        (type == 'job' && (data['source'] ?? '') == 'email');
    final isCall = type == 'call' ||
        (type == 'job' && (data['source'] ?? '') != 'email');
    await LocalNotificationService.showInboxAlert(
      title: title.isEmpty
          ? (isEmail
              ? (type == 'email_offer'
                  ? 'Письмо о ремонте'
                  : (type == 'job' ? 'Заявка с почты' : 'Новое письмо'))
              : isCall
                  ? (type == 'job' ? 'Заявка с телефона' : 'ИИ взял звонок')
                  : 'Новое SMS')
          : title,
      body: body,
      tag: tag,
      channelId: isEmail
          ? LocalNotificationService.emailChannelId
          : isCall
              ? LocalNotificationService.callChannelId
              : LocalNotificationService.smsChannelId,
      channelName: isEmail ? 'Email' : isCall ? 'Incoming calls' : 'SMS',
      channelDescription: isEmail
          ? 'Incoming client emails'
          : isCall
              ? 'Incoming calls and when the secretary answers'
              : 'Incoming SMS and photos from clients',
      applianceType: (data['applianceType'] ?? '').toString(),
      clientName: (data['clientName'] ?? '').toString(),
      city: (data['city'] ?? '').toString(),
      data: {
        'type': type,
        'jobId': (data['jobId'] ?? '').toString(),
        'callSid': (data['callSid'] ?? data['callId'] ?? '').toString(),
        'calledAt': (data['calledAt'] ?? '').toString(),
        'from': (data['from'] ?? '').toString(),
        'source': (data['source'] ?? '').toString(),
        'messageId': (data['messageId'] ?? '').toString(),
        'tag': tag,
        'applianceType': (data['applianceType'] ?? '').toString(),
        'clientName': (data['clientName'] ?? '').toString(),
        'city': (data['city'] ?? '').toString(),
      },
    );
  }

  static Future<void> _askUnrestrictedBatteryOnce() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('asked_ignore_battery_v2') == true) return;
    await prefs.setBool('asked_ignore_battery_v2', true);
    try {
      await _deviceChannel.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (e) {
      debugPrint('NotificationService: battery: $e');
    }
  }

  static Future<void> _saveToken(String? token) async {
    if (token == null || token.isEmpty) return;
    try {
      await http.post(
        Uri.parse('$kFirebaseFunctionsUrl/registerFcmToken'),
        headers: await AuthService.headers(),
        body: json.encode({
          'token': token,
          'platform': defaultTargetPlatform.name,
        }),
      );
    } catch (e) {
      debugPrint('NotificationService: не удалось сохранить токен: $e');
    }
  }
}
