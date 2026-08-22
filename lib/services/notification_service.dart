import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../core/api_keys.dart';
import '../core/l10n/app_locale.dart';
import 'local_notification_service.dart';
import 'notification_router.dart';

/// Регистрирует FCM-токен устройства на сервере, чтобы Cloud Functions
/// могли присылать уведомления о входящих SMS, даже когда приложение свёрнуто.
class NotificationService {
  static bool _initialized = false;
  static const _deviceChannel = MethodChannel('fix_appliance/device');

  static String inboxTag({required String type, required String from}) {
    final raw = 'crm_${type}_$from';
    return raw.length <= 50 ? raw : raw.substring(0, 50);
  }

  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    try {
      await LocalNotificationService.initialize();
      await LocalNotificationService.ensureInboxChannels();
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
      final digits = rawPhone.replaceAll(RegExp(r'\D'), '');
      if (digits.length >= 10) {
        final last10 = digits.substring(digits.length - 10);
        add('sms', last10);
        add('sms', '+1$last10');
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
    final type = (message.data['type'] ?? '').toString();
    if (type == 'secretary_lesson') {
      if (defaultTargetPlatform != TargetPlatform.android) return;
      final lessonTitle = message.notification?.title ?? 'Разбор звонка секретаря'.tr;
      final body = message.notification?.body ?? '';
      if (lessonTitle.trim().isEmpty && body.trim().isEmpty) return;
      await LocalNotificationService.showSecretaryLearn(
        title: lessonTitle,
        body: body,
        tag: (message.data['tag'] ?? '').toString(),
      );
      return;
    }
    final title = message.notification?.title ?? '';
    final body = message.notification?.body ?? '';
    if (title.trim().isEmpty && body.trim().isEmpty) return;
    if (defaultTargetPlatform != TargetPlatform.android) return;

    final isConfirm = type == 'visit_confirm' ||
        type == 'estimate_confirm' ||
        title == 'Заявка подтверждена' ||
        title == 'Заявка не подтверждена' ||
        title == 'Клиент подтвердил ремонт' ||
        title == 'Заявка подтверждена'.tr ||
        title == 'Заявка не подтверждена'.tr ||
        title == 'Клиент подтвердил ремонт'.tr;
    if (isConfirm) {
      await LocalNotificationService.showVisitConfirm(
        title: title.isEmpty ? 'Заявка подтверждена'.tr : title,
        body: body,
        tag: (message.data['tag'] ?? '').toString(),
        jobId: (message.data['jobId'] ?? '').toString(),
        from: (message.data['from'] ?? '').toString(),
      );
      return;
    }

    final isEmail = type == 'email' ||
        type == 'email_offer' ||
        type == 'shipment' ||
        (type == 'job' && (message.data['source'] ?? '') == 'email');
    final isCall = type == 'call' ||
        (type == 'job' && (message.data['source'] ?? '') != 'email');
    await LocalNotificationService.showInboxAlert(
      title: title.isEmpty
          ? (isEmail
              ? (type == 'email_offer'
              ? 'Письмо о ремонте'.tr
              : (type == 'job' ? 'Заявка с почты'.tr : 'Новое письмо'.tr))
              : isCall
                  ? (type == 'job' ? 'Заявка с телефона'.tr : 'ИИ взял звонок'.tr)
                  : 'Новое SMS'.tr)
          : title,
      body: body,
      tag: (message.data['tag'] ?? '').toString(),
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
      data: {
        'type': type,
        'jobId': (message.data['jobId'] ?? '').toString(),
        'callSid': (message.data['callSid'] ?? '').toString(),
        'calledAt': (message.data['calledAt'] ?? '').toString(),
        'from': (message.data['from'] ?? '').toString(),
        'source': (message.data['source'] ?? '').toString(),
        'messageId': (message.data['messageId'] ?? '').toString(),
      },
    );
  }

  static Future<void> _saveToken(String? token) async {
    if (token == null || token.isEmpty) return;
    try {
      await http.post(
        Uri.parse('$kFirebaseFunctionsUrl/registerFcmToken'),
        headers: {'Content-Type': 'application/json'},
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
