import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'sms_service.dart';
import 'twilio_service.dart';

/// Счётчики для нижнего меню: сколько нового на «Связи».
///
/// Раньше про новый звонок и непрочитанное сообщение сообщал колокольчик, и
/// он же считал заявки и сбои — цифра на нём значила «что-то произошло» и
/// поэтому не значила ничего. Теперь событие видно там, где его разбирают:
/// на вкладке «Связь» и на её подвкладках, а колокольчик остался счётчиком
/// решений.
///
/// Подписки живут в одном месте и ровно в одном экземпляре: и нижняя
/// панель, и подвкладки читают эти [ValueNotifier]. У notifier'а всегда
/// есть текущее значение, поэтому виджет, построенный позже, не ждёт
/// следующего снимка Firestore.
class CommsBadgeService {
  static const _callsSeenKey = 'comms_calls_seen_at';

  /// Входящие звонки, которых не было, когда мастер последний раз
  /// смотрел список.
  static final ValueNotifier<int> newCalls = ValueNotifier<int>(0);

  /// Непрочитанные входящие SMS и письма.
  static final ValueNotifier<int> unreadMessages = ValueNotifier<int>(0);

  /// Сумма для самой вкладки «Связь».
  static final ValueNotifier<int> total = ValueNotifier<int>(0);

  static bool _started = false;
  static int _generation = 0;
  static Timer? _retry;
  static final List<StreamSubscription<dynamic>> _subscriptions = [];
  static List<CallRecord> _calls = const [];

  /// Когда список звонков смотрели в последний раз.
  ///
  /// Поле `reviewed` для этого не годится: у звонков, на которые мастер
  /// ответил сам, оно остаётся false навсегда, и бейдж после обновления
  /// показал бы всю историю. Отметка живёт на устройстве и по умолчанию
  /// равна моменту первого запуска — старые звонки «новыми» не станут.
  static DateTime _callsSeenAt = DateTime.now();

  static Future<void> start() async {
    if (_started || !AuthService.signedIn) return;
    _started = true;
    _retry?.cancel();
    final generation = ++_generation;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!_started || generation != _generation) return;
      final stored = prefs.getString(_callsSeenKey);
      final parsed = stored == null ? null : DateTime.tryParse(stored);
      _callsSeenAt = parsed ?? DateTime.now();
      if (parsed == null) {
        await prefs.setString(_callsSeenKey, _callsSeenAt.toIso8601String());
      }
      if (!_started || generation != _generation) return;
      _subscriptions.addAll([
        TwilioService.streamNewIncomingCalls().listen((calls) {
          if (generation != _generation) return;
          _calls = calls;
          _recountCalls();
        }, onError: _onError),
        SmsService.streamUnreadInbound().listen((messages) {
          if (generation != _generation) return;
          unreadMessages.value = messages.length;
          _sum();
        }, onError: _onError),
      ]);
    } catch (error) {
      _onError(error);
    }
  }

  /// Мастер открыл список звонков — всё, что в нём лежит, он увидел.
  static void markCallsSeen() {
    _callsSeenAt = DateTime.now();
    _recountCalls();
    unawaited(
      SharedPreferences.getInstance().then(
        (prefs) => prefs.setString(
          _callsSeenKey,
          _callsSeenAt.toIso8601String(),
        ),
      ),
    );
  }

  static void _recountCalls() {
    newCalls.value = _calls
        .where((call) => (call.startTime ?? DateTime(0)).isAfter(_callsSeenAt))
        .length;
    _sum();
  }

  static void _sum() {
    total.value = newCalls.value + unreadMessages.value;
  }

  static void stop() {
    _generation++;
    _started = false;
    _retry?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _calls = const [];
    newCalls.value = 0;
    unreadMessages.value = 0;
    total.value = 0;
  }

  /// Сеть моргнула — цифры не выдумываем, но и не бросаем насовсем:
  /// пустой бейдж при живых звонках обманывает так же, как и лишний.
  static void _onError(Object error) {
    debugPrint('CommsBadgeService: $error');
    stop();
    if (AuthService.signedIn) {
      _retry = Timer(const Duration(seconds: 15), () => unawaited(start()));
    }
  }
}
