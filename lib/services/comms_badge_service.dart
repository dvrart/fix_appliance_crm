import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/utils/formatters.dart';
import '../models/client.dart';
import 'auth_service.dart';
import 'client_service.dart';
import 'sms_service.dart';
import 'twilio_service.dart';

/// Счётчики для нижнего меню: сколько нового на «Связи».
///
/// Раньше про новый звонок, непрочитанное сообщение и недоставку SMS
/// сообщал колокольчик — его удалили (решение FIX), и теперь события
/// видны только там, где их разбирают: на вкладке «Связь» и на её
/// подвкладках. Недоставленное SMS гаснет, когда мастер открывает сам
/// диалог, — отдельной кнопки «убрать» для него больше нет.
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

  /// Исходящие сообщения, которые оператор не доставил.
  static final ValueNotifier<int> failedSms = ValueNotifier<int>(0);

  /// Непрочитанные плюс недоставленные — цифра на подвкладке сообщений,
  /// чтобы она не расходилась с цифрой на самой «Связи».
  static final ValueNotifier<int> messagesTotal = ValueNotifier<int>(0);

  /// Сумма для самой вкладки «Связь».
  static final ValueNotifier<int> total = ValueNotifier<int>(0);

  /// Кто именно звонил и кто именно написал — последний по времени.
  ///
  /// Одной цифры мало: она говорит «что-то пришло», но не говорит, от кого,
  /// и за этим всё равно приходится лезть в список. Имя берём у клиента,
  /// если он заведён; иначе — то, что назвал ИИ или отправитель письма;
  /// в последнюю очередь — номер.
  static final ValueNotifier<String> newCallFrom = ValueNotifier<String>('');
  static final ValueNotifier<String> unreadFrom = ValueNotifier<String>('');

  /// Граница «новизны» для подсветки строк в списке звонков.
  ///
  /// Это **предыдущий** заход в список, а не текущий: пока мастер смотрит
  /// на список, пометка должна оставаться на месте, иначе она исчезает в тот
  /// же миг, когда он её увидел. Сдвигается только при следующем открытии —
  /// тогда вчерашние новости перестают быть новостями, а пришедшее за это
  /// время подсвечивается.
  static final ValueNotifier<DateTime> callsNewSince =
      ValueNotifier<DateTime>(DateTime.now());

  static bool _started = false;
  static int _generation = 0;
  static Timer? _retry;
  static final List<StreamSubscription<dynamic>> _subscriptions = [];
  static List<CallRecord> _calls = const [];
  static List<SmsMessage> _unread = const [];
  static List<SmsMessage> _failed = const [];
  static Map<String, String> _phoneNames = const {};
  static Map<String, String> _emailNames = const {};

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
      callsNewSince.value = _callsSeenAt;
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
          _unread = messages;
          _recountMessages();
        }, onError: _onError),
        SmsService.streamFailedOutbound().listen((messages) {
          if (generation != _generation) return;
          _failed = messages;
          _recountFailed();
        }, onError: _onError),
        // Справочник имён. Без него подпись у иконки показывала бы номер
        // даже тем клиентам, которых мастер давно завёл.
        ClientService.streamAll().listen((clients) {
          if (generation != _generation) return;
          _rebuildNames(clients);
          _recountCalls();
          _recountMessages();
        }, onError: _onError),
      ]);
    } catch (error) {
      _onError(error);
    }
  }

  /// Мастер открыл список звонков — всё, что в нём лежит, он увидел.
  static void markCallsSeen() {
    callsNewSince.value = _callsSeenAt;
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

  static void _rebuildNames(List<Client> clients) {
    final phones = <String, String>{};
    final emails = <String, String>{};
    void addPhone(String phone, String name) {
      final key = ClientService.normalizePhone(phone);
      final cleaned = Client.stripClientWord(name);
      if (key.length >= 7 &&
          cleaned.isNotEmpty &&
          !Client.isPlaceholderName(cleaned)) {
        phones[key] = cleaned;
      }
    }

    for (final client in clients) {
      addPhone(client.phone, client.fullName);
      final email = SmsService.normalizeEmail(client.email ?? '');
      final cleaned = Client.stripClientWord(client.fullName);
      if (email.contains('@') &&
          cleaned.isNotEmpty &&
          !Client.isPlaceholderName(cleaned)) {
        emails[email] = cleaned;
      }
      for (final location in client.locations) {
        for (final contact in location.contacts) {
          addPhone(
            contact.phone,
            contact.name.trim().isNotEmpty ? contact.name : client.fullName,
          );
        }
      }
    }
    _phoneNames = phones;
    _emailNames = emails;
  }

  /// Имя из заявки ИИ: клиент мог позвонить с незнакомого номера, но себя
  /// назвать.
  static String _extractedName(Map<String, dynamic>? data) {
    if (data == null) return '';
    for (final key in const [
      'client_name',
      'clientName',
      'name',
      'caller_name',
    ]) {
      final cleaned = Client.stripClientWord(data[key]?.toString());
      if (cleaned.isNotEmpty && !Client.isPlaceholderName(cleaned)) {
        return cleaned;
      }
    }
    return '';
  }

  static String _callLabel(CallRecord call) {
    final phone = call.fromNumber;
    final known = _phoneNames[ClientService.normalizePhone(phone)];
    if (known != null) return known;
    final extracted = <String, dynamic>{
      ...?call.extractedData,
      if (call.aiReception?['extracted'] is Map)
        ...Map<String, dynamic>.from(call.aiReception!['extracted'] as Map),
    };
    final guessed = _extractedName(extracted);
    if (guessed.isNotEmpty) return guessed;
    return phone.trim().isEmpty ? '' : Formatters.formatPhone(phone);
  }

  static String _messageLabel(SmsMessage message) {
    if (message.isEmail) {
      final email = SmsService.normalizeEmail(message.counterpartEmail);
      final known = _emailNames[email];
      if (known != null) return known;
      final fromName = Client.stripClientWord(message.fromName);
      if (fromName.isNotEmpty && !Client.isPlaceholderName(fromName)) {
        return fromName;
      }
      final guessed = _extractedName(message.extractedData);
      if (guessed.isNotEmpty) return guessed;
      return email;
    }
    final phone = message.from;
    final known = _phoneNames[ClientService.normalizePhone(phone)];
    if (known != null) return known;
    final guessed = _extractedName(message.extractedData);
    if (guessed.isNotEmpty) return guessed;
    return phone.trim().isEmpty ? '' : Formatters.formatPhone(phone);
  }

  static void _recountCalls() {
    final fresh = _calls
        .where((call) => (call.startTime ?? DateTime(0)).isAfter(_callsSeenAt))
        .toList();
    newCalls.value = fresh.length;
    CallRecord? latest;
    for (final call in fresh) {
      final at = call.startTime ?? DateTime(0);
      if (latest == null || at.isAfter(latest.startTime ?? DateTime(0))) {
        latest = call;
      }
    }
    newCallFrom.value = latest == null ? '' : _callLabel(latest);
    _sum();
  }

  static void _recountMessages() {
    unreadMessages.value = _unread.length;
    SmsMessage? latest;
    for (final message in _unread) {
      final at = message.createdAt ?? DateTime(0);
      if (latest == null || at.isAfter(latest.createdAt ?? DateTime(0))) {
        latest = message;
      }
    }
    unreadFrom.value = latest == null ? '' : _messageLabel(latest);
    _sumMessages();
    _sum();
  }

  static void _recountFailed() {
    failedSms.value = _failed.length;
    _sumMessages();
    _sum();
  }

  static void _sumMessages() {
    messagesTotal.value = unreadMessages.value + failedSms.value;
  }

  static void _sum() {
    total.value = newCalls.value + messagesTotal.value;
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
    _unread = const [];
    _failed = const [];
    _phoneNames = const {};
    _emailNames = const {};
    newCalls.value = 0;
    unreadMessages.value = 0;
    failedSms.value = 0;
    messagesTotal.value = 0;
    total.value = 0;
    newCallFrom.value = '';
    unreadFrom.value = '';
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
