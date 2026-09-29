import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
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
import 'network_status_service.dart';

/// Регистрирует FCM-токен устройства на сервере, чтобы Cloud Functions
/// могли присылать уведомления о входящих SMS, даже когда приложение свёрнуто.
class NotificationService {
  static bool _initialized = false;
  static bool _listenersAttached = false;
  static bool _nativeEventsBound = false;
  static Future<void>? _initializing;
  static Future<void>? _registering;
  static Timer? _registrationRetry;
  static String? _registeredToken;
  static String? _pendingToken;
  static String? _registeredUser;
  static int _registrationFailures = 0;
  static final registrationState = ValueNotifier<String>('pending');
  static final Set<String> _deliveredEvents = {};
  static final _nativeEvents = StreamController<MethodCall>.broadcast();
  static Stream<MethodCall> get nativeEvents => _nativeEvents.stream;
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
    final peer = from.trim().isNotEmpty ? from.trim() : to.trim();
    if (peer.contains('@')) {
      return _boundedTag('crm_inbox_${peer.toLowerCase()}');
    }
    final phone = last10(peer);
    if (phone.isNotEmpty) return 'crm_inbox_$phone';
    final key = [
      callSid,
      messageId,
      jobId,
      'inbox',
    ].firstWhere((value) => value.trim().isNotEmpty);
    return _boundedTag('crm_${type.isEmpty ? 'sms' : type}_$key');
  }

  static String _boundedTag(String tag) => tag.length <= 50
      ? tag
      : '${tag.substring(0, 16)}_${sha256.convert(utf8.encode(tag)).toString().substring(0, 32)}';

  static String _first(Map<String, String> data, List<String> keys) {
    for (final key in keys) {
      final value = (data[key] ?? '').trim();
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  static String tagFor(Map<String, String> data) {
    final peer = _first(data, ['peer', 'from', 'to']);
    final tag = (data['tag'] ?? '').trim();
    if (!peer.contains('@') && last10(peer).isEmpty && tag.isNotEmpty) {
      return _boundedTag(tag);
    }
    return shadeTag(
      type: (data['type'] ?? 'sms').trim(),
      from: peer,
      callSid: _first(data, ['callSid', 'callId']),
      messageId: (data['messageId'] ?? '').trim(),
      jobId: (data['jobId'] ?? '').trim(),
    );
  }

  static String eventIdFor(Map<String, String> data) {
    final explicit = (data['eventId'] ?? '').trim();
    if (explicit.isNotEmpty) return explicit;
    final type = data['type'] ?? 'sms';
    final source = data['source'] ?? '';
    final callId = _first(data, ['callSid', 'callId', 'sourceCallId']);
    if (type == 'call' && callId.isNotEmpty) return 'call:$callId';
    final messageId = _first(data, [
      'messageId',
      'sourceEmailId',
      'sourceSmsId',
    ]);
    if (messageId.isNotEmpty) {
      final email =
          type == 'email' ||
          type == 'email_offer' ||
          source == 'email' ||
          source == 'website';
      return '${email ? 'email' : 'sms'}:$messageId';
    }
    if (type == 'job' && callId.isNotEmpty) return 'call:$callId';
    if (type == 'job' && (data['jobId'] ?? '').isNotEmpty) {
      return 'job:${data['jobId']}';
    }
    return '';
  }

  static Future<void> initialize() {
    if (_initialized) {
      unawaited(refreshRegistration());
      return Future.value();
    }
    return _initializing ??= _initialize().whenComplete(
      () => _initializing = null,
    );
  }

  static void bindNativeEvents() {
    if (_nativeEventsBound) return;
    _nativeEventsBound = true;
    _deviceChannel.setMethodCallHandler((call) async {
      if (call.method == 'notificationTap' && call.arguments is Map) {
        unawaited(
          NotificationRouter.open(
            normalizeRemoteData(
              Map<String, dynamic>.from(call.arguments as Map),
            ),
          ),
        );
      } else {
        _nativeEvents.add(call);
      }
    });
    if (defaultTargetPlatform == TargetPlatform.android) {
      unawaited(
        _deviceChannel
            .invokeMethod<void>('notificationEventsReady')
            .catchError(
              (Object error) =>
                  debugPrint('NotificationService: native events: $error'),
            ),
      );
    }
  }

  static Future<void> _initialize() async {
    bindNativeEvents();
    if (!_listenersAttached) {
      _listenersAttached = true;
      FirebaseMessaging.onMessage.listen(_onForegroundMessage);
      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        unawaited(NotificationRouter.open(normalizeRemoteData(message.data)));
      });
      FirebaseMessaging.instance.onTokenRefresh.listen(
        (token) {
          unawaited(refreshRegistration(token: token));
        },
        onError: (Object error) =>
            debugPrint('NotificationService: token refresh: $error'),
      );
      AuthService.user.addListener(_onAuthChanged);
      NetworkStatusService.offline.addListener(_onNetworkChanged);
      _onAuthChanged();
    }
    try {
      await LocalNotificationService.initialize();
      await LocalNotificationService.ensureInboxChannels();
      unawaited(_startBackgroundGuard());
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      await FirebaseMessaging.instance
          .setForegroundNotificationPresentationOptions(
            alert: true,
            badge: true,
            sound: true,
          );
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) {
        unawaited(NotificationRouter.open(normalizeRemoteData(initial.data)));
      }
      _initialized = true;
      unawaited(refreshRegistration());
      await _askUnrestrictedBatteryOnce();
    } catch (e) {
      debugPrint('NotificationService: ошибка инициализации: $e');
    }
  }

  static void _onAuthChanged() {
    if (!AuthService.signedIn) {
      _registeredUser = null;
      _registeredToken = null;
      _registrationRetry?.cancel();
      registrationState.value = 'signed_out';
      InboxPushMirror.stop();
      return;
    }
    unawaited(InboxPushMirror.start());
    unawaited(refreshRegistration());
  }

  static void _onNetworkChanged() {
    if (!NetworkStatusService.offline.value) unawaited(refreshRegistration());
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
      return await _deviceChannel.invokeMethod<bool>(
        'requestIgnoreBatteryOptimizations',
      );
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

  /// Показать тестовое уведомление входящего звонка с кнопками
  /// «Ответить» / «Отклонить» (нативная шторка, само гаснет через 15 с).
  static Future<void> testIncomingCall() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _deviceChannel.invokeMethod('testIncomingCallNotification');
    } catch (e) {
      debugPrint('NotificationService: testIncomingCall: $e');
    }
  }

  static Future<bool> areNotificationsEnabled() async {
    if (defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      final enabled = await _deviceChannel.invokeMethod<bool>(
        'areNotificationsEnabled',
      );
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
                const Icon(
                  Icons.notifications_off_outlined,
                  size: 48,
                  color: Color(0xFF14557F),
                ),
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

  /// FCM запрещает ключ `from` в данных и отклоняет всё сообщение целиком,
  /// поэтому сервер присылает номер как `peer`. Приводим к привычному `from`
  /// в одном месте, чтобы остальной код не менялся.
  static Map<String, String> normalizeRemoteData(Map<String, dynamic> raw) {
    final data = <String, String>{
      for (final entry in raw.entries) entry.key: '${entry.value ?? ''}',
    };
    final peer = (data['peer'] ?? '').trim();
    if (peer.isNotEmpty && (data['from'] ?? '').trim().isEmpty) {
      data['from'] = peer;
    }
    return data;
  }

  static Future<void> showRemoteMessage(RemoteMessage message) async {
    final data = normalizeRemoteData(message.data);
    final title = (message.notification?.title ?? data['title'] ?? '')
        .toString();
    final body = (message.notification?.body ?? data['body'] ?? '').toString();
    if (title.trim().isNotEmpty) data['title'] = title;
    if (body.trim().isNotEmpty) data['body'] = body;
    await showRemoteData(data);
  }

  static Future<void> showRemoteData(Map<String, String> raw) async {
    final data = normalizeRemoteData(raw);
    if ((data['title'] ?? '').trim().isEmpty &&
        (data['body'] ?? '').trim().isEmpty) {
      return;
    }
    final eventId = eventIdFor(data);
    if (eventId.isNotEmpty && !_deliveredEvents.add(eventId)) return;
    if (eventId.isNotEmpty) data['eventId'] = eventId;
    if (_deliveredEvents.length > 1000) {
      _deliveredEvents.remove(_deliveredEvents.first);
    }
    try {
      await _displayRemoteData(data);
    } catch (error) {
      _deliveredEvents.remove(eventId);
      rethrow;
    }
  }

  static Future<void> _displayRemoteData(Map<String, String> data) async {
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
      return;
    }

    final isConfirm =
        type == 'visit_confirm' ||
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
        data: data,
      );
      return;
    }

    final isEmail =
        type == 'email' ||
        type == 'email_offer' ||
        type == 'shipment' ||
        (type == 'job' && (data['source'] ?? '') == 'email');
    final isCall =
        type == 'call' ||
        (type == 'job' &&
            !['email', 'website', 'sms'].contains(data['source']));
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
      channelName: isEmail
          ? 'Email'
          : isCall
          ? 'Incoming calls'
          : 'SMS',
      channelDescription: isEmail
          ? 'Incoming client emails'
          : isCall
          ? 'Incoming calls and when the secretary answers'
          : 'Incoming SMS and photos from clients',
      applianceType: (data['applianceType'] ?? '').toString(),
      clientName: (data['clientName'] ?? '').toString(),
      city: (data['city'] ?? '').toString(),
      data: {
        ...data,
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

  static Future<void> refreshRegistration({String? token}) {
    if (token != null && token.isNotEmpty) _pendingToken = token;
    if (!AuthService.signedIn) return Future.value();
    return _registering ??= _registerToken().whenComplete(() {
      _registering = null;
      if (_pendingToken != null && !NetworkStatusService.offline.value) {
        unawaited(refreshRegistration());
      }
    });
  }

  static Future<void> _registerToken() async {
    final suppliedToken = _pendingToken;
    _pendingToken = null;
    final userId = AuthService.user.value?.uid;
    if (userId == null) return;
    _registrationRetry?.cancel();
    try {
      final token =
          suppliedToken ??
          await FirebaseMessaging.instance.getToken().timeout(
            const Duration(seconds: 10),
          );
      if (token == null || token.isEmpty) {
        throw StateError('FCM token unavailable');
      }
      if (_registeredToken == token && _registeredUser == userId) return;
      registrationState.value = 'pending';
      final prefs = await SharedPreferences.getInstance();
      var deviceId = prefs.getString('notification_device_id');
      if (deviceId == null || deviceId.isEmpty) {
        final random = Random.secure();
        deviceId = List.generate(
          16,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        await prefs.setString('notification_device_id', deviceId);
      }
      final headers = await AuthService.headers();
      if (!headers.containsKey('Authorization')) {
        throw StateError('Authentication unavailable');
      }
      if (AuthService.user.value?.uid != userId) return;
      final response = await http
          .post(
            Uri.parse('$kFirebaseFunctionsUrl/registerFcmToken'),
            headers: headers,
            body: json.encode({
              'token': token,
              'platform': defaultTargetPlatform.name,
              'deviceId': deviceId,
              'previousToken': prefs.getString('notification_last_token'),
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200 ||
          json.decode(response.body)['success'] != true) {
        throw StateError('Device registration HTTP ${response.statusCode}');
      }
      if (AuthService.user.value?.uid != userId) return;
      _registeredToken = token;
      _registeredUser = userId;
      _registrationFailures = 0;
      registrationState.value = 'registered';
      await prefs.setString('notification_last_token', token);
      debugPrint('NotificationService: устройство зарегистрировано');
    } catch (e) {
      registrationState.value = 'retrying';
      debugPrint('NotificationService: регистрация будет повторена: $e');
      if (!AuthService.signedIn) return;
      _registrationFailures = min(_registrationFailures + 1, 7);
      final seconds = min(300, 5 * (1 << (_registrationFailures - 1)));
      _registrationRetry = Timer(Duration(seconds: seconds), () {
        unawaited(refreshRegistration());
      });
    }
  }
}
