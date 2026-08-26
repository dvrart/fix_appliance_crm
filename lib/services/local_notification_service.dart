import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import '../core/constants.dart';
import '../core/l10n/app_locale.dart';
import '../core/notification_look.dart';
import '../models/job.dart';
import 'notification_router.dart';

/// Локальные уведомления: утренние заявки и подсказка «я в пути».
class LocalNotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static const _location = 'America/Toronto';

  static const morningChannelId = 'morning_jobs';
  static const onWayChannelId = 'on_the_way';
  static const smsChannelId = 'sms_messages';
  static const emailChannelId = 'email_messages';
  static const callChannelId = 'incoming_calls';
  static const visitConfirmChannelId = 'visit_confirm';
  static const visitSoonChannelId = 'visit_soon';
  static const secretaryLearnChannelId = 'secretary_learn';
  static const morningNotificationId = 7100;
  static const eveningNotificationId = 7110;
  static const onWayNotificationId = 7200;
  static const visitConfirmNotificationId = 7300;
  static const activeCallNotificationId = 7600;
  static const activeCallChannelId = 'active_voice_call';

  static bool _ready = false;

  static Future<void> initialize() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation(_location));

    const android = AndroidInitializationSettings('@drawable/ic_stat_notify');
    const ios = DarwinInitializationSettings();
    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: (response) {
        unawaited(NotificationRouter.handlePayload(response.payload));
      },
    );

    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.requestNotificationsPermission();
    await androidPlugin?.requestExactAlarmsPermission();
    await androidPlugin?.requestFullScreenIntentPermission();
    _ready = true;

    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true) {
      unawaited(
        NotificationRouter.handlePayload(launch?.notificationResponse?.payload),
      );
    }
  }

  static String payload(Map<String, String> data) => json.encode(data);

  static Future<void> ensureInboxChannels() async {
    await initialize();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        callChannelId,
        'Incoming calls',
        description: 'Incoming calls and when the secretary answers',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        smsChannelId,
        'SMS',
        description: 'Incoming SMS and photos from clients',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        emailChannelId,
        'Email',
        description: 'Incoming client emails',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        morningChannelId,
        'Jobs for the day',
        description: '7:00 and 19:00 job list and what to take',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        onWayChannelId,
        'On the way',
        description: 'Prompt to text the next client',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        visitConfirmChannelId,
        'Visit confirmation',
        description: 'Client confirmed, cancelled, or asked to reschedule',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        visitSoonChannelId,
        'Upcoming visit',
        description: 'Alert 1.5 hours before the next job',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        secretaryLearnChannelId,
        'Secretary learning',
        description: 'Phone secretary wants to learn something — confirm first',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        activeCallChannelId,
        'Active call',
        description: 'Ongoing voice call — tap to return',
        importance: Importance.defaultImportance,
        playSound: false,
        enableVibration: false,
      ),
    );
  }

  static int inboxIdForTag(String tag) =>
      7400 + ((tag).hashCode.abs() % 180);

  static Future<void> dismissInboxPayload(Map<String, dynamic> data) async {
    final tags = <String>{};
    final tag = (data['tag'] ?? '').toString().trim();
    if (tag.isNotEmpty) tags.add(tag);
    final type = (data['type'] ?? '').toString().trim();
    final keys = <String>{
      (data['from'] ?? '').toString().trim(),
      (data['to'] ?? '').toString().trim(),
      (data['callSid'] ?? '').toString().trim(),
      (data['callId'] ?? '').toString().trim(),
      (data['jobId'] ?? '').toString().trim(),
      'inbox',
    };
    for (final from in keys) {
      if (type.isEmpty || from.isEmpty) continue;
      final raw = 'crm_${type}_$from';
      tags.add(raw.length <= 50 ? raw : raw.substring(0, 50));
    }
    await cancelTags(tags);
  }

  static Future<void> cancelTags(Iterable<String> tags) async {
    await initialize();
    final want = {
      for (final tag in tags)
        if (tag.trim().isNotEmpty) tag.trim(),
    };
    if (want.isEmpty) return;
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    for (final tag in want) {
      await _plugin.cancel(inboxIdForTag(tag), tag: tag);
      await android?.cancel(0, tag: tag);
      await android?.cancel(inboxIdForTag(tag), tag: tag);
    }
    try {
      final active = await android?.getActiveNotifications() ?? const [];
      for (final item in active) {
        final tag = (item.tag ?? '').trim();
        final payload = item.payload ?? '';
        final hit = want.contains(tag) ||
            want.any((value) => value.isNotEmpty && payload.contains(value));
        if (!hit) continue;
        await _plugin.cancel(item.id ?? 0, tag: item.tag);
      }
    } catch (e) {
      debugPrint('LocalNotificationService: cancel active: $e');
    }
  }

  static tz.TZDateTime nextAtHour(int hour, {int minute = 0}) {
    final now = tz.TZDateTime.now(tz.local);
    var when = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour.clamp(0, 23),
      minute.clamp(0, 59),
    );
    if (!now.isBefore(when)) {
      when = when.add(const Duration(days: 1));
    }
    return when;
  }

  static tz.TZDateTime nextSevenAm() => nextAtHour(7);

  static tz.TZDateTime nextSevenPm() => nextAtHour(19);

  static int _ymd(tz.TZDateTime when) =>
      when.year * 10000 + when.month * 100 + when.day;

  static int morningIdFor(tz.TZDateTime when) => 181000000 + _ymd(when);

  static int eveningIdFor(tz.TZDateTime when) => 182000000 + _ymd(when);

  static int visitAlertId(String jobId, String visitId) {
    var hash = 2166136261;
    for (final unit in '$jobId|$visitId'.codeUnits) {
      hash ^= unit;
      hash = (hash * 16777619) & 0x7fffffff;
    }
    return 810000 + (hash % 90000);
  }

  static Future<void> _cancelIfPending(int id) async {
    final pending = await _plugin.pendingNotificationRequests();
    if (pending.any((item) => item.id == id)) {
      await _plugin.cancel(id);
    }
  }

  static Future<void> _scheduleZoned({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime when,
    required NotificationDetails details,
    required String payloadValue,
  }) async {
    try {
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        when,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: payloadValue,
      );
    } catch (e) {
      debugPrint('LocalNotificationService: exact alarm failed: $e');
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        when,
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: payloadValue,
      );
    }
  }

  static Future<void> cancelMorning({int hour = 7}) async {
    await initialize();
    await _cancelIfPending(morningIdFor(nextAtHour(hour)));
    await _cancelIfPending(morningNotificationId);
  }

  static Future<void> cancelEvening({int hour = 19}) async {
    await initialize();
    await _cancelIfPending(eveningIdFor(nextAtHour(hour)));
    await _cancelIfPending(eveningNotificationId);
  }

  static Future<void> scheduleMorning({
    required String title,
    required String body,
    int hour = 7,
  }) async {
    await initialize();
    if (body.trim().isEmpty) {
      await cancelMorning(hour: hour);
      return;
    }
    final when = nextAtHour(hour);
    final id = morningIdFor(when);
    await _cancelIfPending(id);
    await _cancelIfPending(morningNotificationId);
    await _scheduleZoned(
      id: id,
      title: title,
      body: body,
      when: when,
      details: _headsUpDetails(
        channelId: morningChannelId,
        channelName: 'Заявки на день'.tr,
        channelDescription: 'В 7:00 список заявок и что взять с собой'.tr,
        title: title,
        body: body,
      ),
      payloadValue: payload({'type': 'morning'}),
    );
  }

  static Future<void> scheduleEvening({
    required String title,
    required String body,
    int hour = 19,
  }) async {
    await initialize();
    if (body.trim().isEmpty) {
      await cancelEvening(hour: hour);
      return;
    }
    final when = nextAtHour(hour);
    final id = eveningIdFor(when);
    await _cancelIfPending(id);
    await _cancelIfPending(eveningNotificationId);
    await _scheduleZoned(
      id: id,
      title: title,
      body: body,
      when: when,
      details: _headsUpDetails(
        channelId: morningChannelId,
        channelName: 'Заявки на день'.tr,
        channelDescription: 'Вечером в 19:00 заявки на завтра и что взять'.tr,
        title: title,
        body: body,
      ),
      payloadValue: payload({'type': 'evening'}),
    );
  }

  static Future<void> showSecretaryLearn({
    required String title,
    required String body,
    String? tag,
  }) async {
    await initialize();
    await _plugin.show(
      (tag != null && tag.isNotEmpty) ? 0 : 7400,
      title,
      body,
      _headsUpDetails(
        channelId: secretaryLearnChannelId,
        channelName: 'Разбор секретаря'.tr,
        channelDescription:
            'Полный отчёт ошибки секретаря — вы пишете, как действовать дальше'.tr,
        title: title,
        body: body,
        tag: tag,
      ),
      payload: payload({'type': 'secretary_lesson'}),
    );
  }

  static Future<void> showVisitConfirm({
    required String title,
    required String body,
    String? tag,
    String? jobId,
    String? from,
  }) async {
    await initialize();
    await _plugin.show(
      (tag != null && tag.isNotEmpty) ? 0 : visitConfirmNotificationId,
      title,
      body,
      _headsUpDetails(
        channelId: visitConfirmChannelId,
        channelName: 'Подтверждение визита'.tr,
        channelDescription: 'Клиент подтвердил или не подтвердил визит'.tr,
        title: title,
        body: body,
        tag: tag,
      ),
      payload: payload({
        'type': 'visit_confirm',
        if (jobId != null && jobId.isNotEmpty) 'jobId': jobId,
        if (from != null && from.isNotEmpty) 'from': from,
      }),
    );
  }

  static Future<void> showOnTheWay({
    required String title,
    required String body,
    String? jobId,
  }) async {
    await initialize();
    await _plugin.show(
      onWayNotificationId,
      title,
      body,
      _headsUpDetails(
        channelId: onWayChannelId,
        channelName: 'Я в пути'.tr,
        channelDescription: 'Предложение отправить SMS следующему клиенту'.tr,
        title: title,
        body: body,
      ),
      payload: payload({
        'type': 'on_the_way',
        if (jobId != null && jobId.isNotEmpty) 'jobId': jobId,
      }),
    );
  }

  static Future<void> showLeaveStatus({
    required String title,
    required String body,
    String? jobId,
  }) async {
    await initialize();
    await _plugin.show(
      onWayNotificationId + 1,
      title,
      body,
      _headsUpDetails(
        channelId: onWayChannelId,
        channelName: 'Я в пути'.tr,
        channelDescription: 'Спросить статус заявки после отъезда'.tr,
        title: title,
        body: body,
      ),
      payload: payload({
        'type': 'leave_status',
        if (jobId != null && jobId.isNotEmpty) 'jobId': jobId,
      }),
    );
  }

  static Future<void> showInboxAlert({
    required String title,
    required String body,
    String? tag,
    String channelId = smsChannelId,
    String channelName = 'SMS',
    String channelDescription = 'Incoming SMS and photos from clients',
    Map<String, String> data = const {},
  }) async {
    await initialize();
    final id = (tag != null && tag.isNotEmpty) ? 0 : inboxIdForTag(tag ?? title);
    await _plugin.show(
      id,
      title,
      body,
      _headsUpDetails(
        channelId: channelId,
        channelName: channelName,
        channelDescription: channelDescription,
        title: title,
        body: body,
        tag: tag,
      ),
      payload: payload({
        ...data,
        if (tag != null && tag.isNotEmpty) 'tag': tag,
      }),
    );
  }

  static Future<void> showActiveCall({String phone = ''}) async {
    await initialize();
    await ensureInboxChannels();
    final who = phone.trim();
    await _plugin.show(
      activeCallNotificationId,
      'Разговор'.tr,
      who.isEmpty
          ? 'Нажмите, чтобы вернуться. Можно положить трубку.'.tr
          : who,
      NotificationDetails(
        android: AndroidNotificationDetails(
          activeCallChannelId,
          'Active call',
          channelDescription: 'Ongoing voice call — tap to return',
          icon: '@drawable/ic_stat_notify',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          playSound: false,
          enableVibration: false,
          autoCancel: false,
          ongoing: true,
          color: NotificationLook.instance.color,
          visibility: NotificationVisibility.public,
          category: AndroidNotificationCategory.call,
          ticker: 'Разговор'.tr,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: false,
          presentSound: false,
        ),
      ),
      payload: payload({'type': 'active_call'}),
    );
  }

  static Future<void> cancelActiveCall() async {
    await initialize();
    await _plugin.cancel(activeCallNotificationId);
  }

  static Future<void> showPreview() async {
    await showInboxAlert(
      title: 'Fix Appliance',
      body: 'Так выглядит уведомление. Можно смахнуть.'.tr,
      tag: 'look_preview',
    );
  }

  static NotificationDetails _headsUpDetails({
    required String channelId,
    required String channelName,
    required String channelDescription,
    required String title,
    required String body,
    bool ongoing = false,
    bool sticky = false,
    String? tag,
  }) {
    final look = NotificationLook.instance;
    final keep = sticky || ongoing;
    final visibility = switch (look.lockVisibility) {
      'private' => NotificationVisibility.private,
      'secret' => NotificationVisibility.secret,
      _ => NotificationVisibility.public,
    };
    return NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        channelName,
        channelDescription: channelDescription,
        icon: '@drawable/ic_stat_notify',
        importance: Importance.max,
        priority: Priority.max,
        playSound: true,
        enableVibration: true,
        autoCancel: !keep,
        ongoing: keep,
        timeoutAfter: null,
        color: look.color,
        colorized: look.colorized && !keep,
        visibility: visibility,
        category: keep && channelId == callChannelId
            ? AndroidNotificationCategory.call
            : AndroidNotificationCategory.message,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        ticker: title,
        tag: tag,
        styleInformation:
            look.largeText ? BigTextStyleInformation(body) : null,
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.timeSensitive,
      ),
    );
  }

  static Future<void> scheduleVisitAlerts(List<Job> jobs) async {
    await initialize();
    await ensureInboxChannels();
    final prefs = await SharedPreferences.getInstance();
    final old = prefs.getStringList('visit_alert_ids') ?? const [];

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    var activeIds = <int>{};
    try {
      final active = await android?.getActiveNotifications() ?? const [];
      activeIds = {
        for (final item in active)
          if (item.id != null) item.id!,
      };
    } catch (e) {
      debugPrint('LocalNotificationService: active notifications: $e');
    }

    final now = tz.TZDateTime.now(tz.local);
    final ids = <String>[];
    var n = 0;
    final keepIds = <int>{};
    for (final job in jobs) {
      if (job.isDeleted || JobStatuses.isClosed(job.status)) continue;
      for (final visit in job.coalescedVisits) {
        if (!visit.isActiveSlot) continue;
        final start = tz.TZDateTime.from(visit.startAt, tz.local);
        if (!start.isAfter(now)) continue;
        n += 1;
        if (n > 48) break;
        final id = visitAlertId(job.id, visit.id);
        keepIds.add(id);
        final when = start.subtract(const Duration(minutes: 90));
        final key =
            'visit_alert_shown_${job.id}_${visit.id}_${start.millisecondsSinceEpoch}';
        if (prefs.getBool(key) == true) {
          ids.add('$id');
          continue;
        }
        final title = 'Через 1.5 часа заявка'.tr;
        final who = job.contactName.trim().isEmpty
            ? 'Клиент'.tr
            : job.contactName.trim();
        final body =
            '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')} — $who, ${trAny(job.applianceType)}';
        final details = _headsUpDetails(
          channelId: visitSoonChannelId,
          channelName: 'Скоро заявка'.tr,
          channelDescription: 'Напоминание за 1.5 часа до визита'.tr,
          title: title,
          body: body,
        );
        final visitPayload = payload({
          'type': 'visit_soon',
          'jobId': job.id,
        });
        if (!when.isAfter(now)) {
          if (!activeIds.contains(id)) {
            await _plugin.show(
              id,
              title,
              body,
              details,
              payload: visitPayload,
            );
          }
          await prefs.setBool(key, true);
        } else {
          await _scheduleZoned(
            id: id,
            title: title,
            body: body,
            when: when,
            details: details,
            payloadValue: visitPayload,
          );
        }
        ids.add('$id');
      }
      if (n > 48) break;
    }
    for (final raw in old) {
      final id = int.tryParse(raw);
      if (id != null && !keepIds.contains(id)) {
        await _plugin.cancel(id);
      }
    }
    await prefs.setStringList('visit_alert_ids', ids);
  }
}
