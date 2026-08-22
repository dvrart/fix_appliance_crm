import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:twilio_voice/twilio_voice.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../core/api_keys.dart';
import 'firestore_service.dart';

/// Идентификатор мастера, под которым приложение регистрируется в Twilio
/// Voice и на который Twilio-номер направляет входящие звонки.
/// Должен совпадать с TWILIO_MASTER_IDENTITY в functions/.env.
const String kTwilioMasterIdentity = 'master';

/// Запись о звонке (заполняется и обновляется преимущественно на сервере —
/// Firebase Functions пишут статус, запись разговора, транскрипцию и
/// извлечённые ИИ данные прямо в Firestore).
class CallRecord {
  final String id;
  final String callSid;
  final String fromNumber;
  final String toNumber;
  final String direction; // 'inbound' | 'outbound'
  final DateTime? startTime;
  final DateTime? endTime;
  final int? durationSeconds;
  final String? recordingUrl;
  final String? storageUrl;
  final String? transcription;
  final String? transcriptionRu;
  final String? transcriptionEn;
  final String? summary;
  final String status; // 'ringing' | 'in-progress' | 'completed' | 'no-answer' | 'failed' | 'busy'
  final String aiStatus; // 'none' | 'processing' | 'done' | 'error'
  final String? aiError;
  final Map<String, dynamic>? extractedData;
  final Map<String, dynamic>? aiReception;
  final String? clientId;
  final String? createdJobId;
  final bool reviewed;
  final String answeredBy; // '' | 'master' | 'ai'
  final bool serviceDeclined;
  final String declineReason;

  CallRecord({
    required this.id,
    required this.callSid,
    required this.fromNumber,
    required this.toNumber,
    required this.direction,
    this.startTime,
    this.endTime,
    this.durationSeconds,
    this.recordingUrl,
    this.storageUrl,
    this.transcription,
    this.transcriptionRu,
    this.transcriptionEn,
    this.summary,
    this.status = 'ringing',
    this.aiStatus = 'none',
    this.aiError,
    this.extractedData,
    this.aiReception,
    this.clientId,
    this.createdJobId,
    this.reviewed = false,
    this.answeredBy = '',
    this.serviceDeclined = false,
    this.declineReason = '',
  });

  bool get isIncoming => direction == 'inbound';
  bool get answeredByAi => answeredBy == 'ai';
  bool get hasRecording =>
      (storageUrl ?? '').trim().isNotEmpty ||
      (recordingUrl ?? '').trim().isNotEmpty;

  String get liveError {
    final reception = aiReception;
    if (reception == null) return '';
    return (reception['liveError'] ?? '').toString().trim();
  }

  bool get liveFailed => aiReception?['liveFailed'] == true;

  Map<String, dynamic> toAttachment() {
    return {
      'callId': id,
      'url': recordingUrl ?? '',
      'storageUrl': storageUrl ?? '',
      'transcription': transcription ?? '',
      'transcriptionRu': transcriptionRu ?? transcription ?? '',
      'transcriptionEn': transcriptionEn ?? '',
      'summary': summary ?? '',
      'history': aiReception?['history'],
      'answeredBy': answeredBy,
      'extracted': extractedData,
    };
  }

  static DateTime? parseStamp(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  factory CallRecord.fromMap(Map<String, dynamic> map, String docId) {
    return CallRecord(
      id: docId,
      callSid: map['callSid'] ?? docId,
      fromNumber: map['fromNumber'] ?? '',
      toNumber: map['toNumber'] ?? '',
      direction: map['direction'] ?? 'inbound',
      startTime: parseStamp(map['startTime']),
      endTime: parseStamp(map['endTime']),
      durationSeconds: map['durationSeconds'],
      recordingUrl: map['recordingUrl'],
      storageUrl: (map['storageUrl'] ?? '').toString().trim().isEmpty
          ? null
          : (map['storageUrl'] ?? '').toString(),
      transcription: map['transcription'],
      transcriptionRu: (map['transcriptionRu'] ?? '').toString().trim().isEmpty
          ? null
          : (map['transcriptionRu'] ?? '').toString(),
      transcriptionEn: (map['transcriptionEn'] ?? '').toString().trim().isEmpty
          ? null
          : (map['transcriptionEn'] ?? '').toString(),
      summary: (map['summary'] ?? '').toString().trim().isEmpty
          ? null
          : (map['summary'] ?? '').toString(),
      status: map['status'] ?? 'ringing',
      aiStatus: map['aiStatus'] ?? 'none',
      aiError: map['aiError'],
      extractedData: map['extractedData'] != null
          ? Map<String, dynamic>.from(map['extractedData'])
          : null,
      aiReception: map['aiReception'] is Map
          ? Map<String, dynamic>.from(map['aiReception'] as Map)
          : null,
      clientId: map['clientId'],
      createdJobId: map['createdJobId'],
      reviewed: map['reviewed'] == true,
      answeredBy: (map['answeredBy'] ?? '').toString(),
      serviceDeclined: map['serviceDeclined'] == true ||
          (map['extractedData'] is Map &&
              map['extractedData']['service_declined'] == true) ||
          (map['aiReception'] is Map &&
              map['aiReception']['serviceDeclined'] == true),
      declineReason: () {
        final top = (map['declineReason'] ?? '').toString().trim();
        if (top.isNotEmpty) return top;
        final extracted = map['extractedData'];
        if (extracted is Map) {
          return (extracted['decline_reason'] ?? '').toString().trim();
        }
        return '';
      }(),
    );
  }
}

/// Сервис звонков через Twilio Voice — приём и совершение звонков прямо в
/// приложении (VoIP). Входящий UI принадлежит CRM (self-managed PhoneAccount),
/// а не системному приложению «Телефон». Запись и ИИ-обработка разговора
/// выполняются на сервере (Firebase Functions).
class TwilioService {
  static bool _isInitialized = false;
  static bool _eventsAttached = false;
  static bool get isInitialized => _isInitialized;

  static final StreamController<ActiveCall?> _activeCallController =
      StreamController<ActiveCall?>.broadcast();
  static Stream<ActiveCall?> get activeCallStream => _activeCallController.stream;

  static final StreamController<CallEvent> _callEventController =
      StreamController<CallEvent>.broadcast();
  static Stream<CallEvent> get callEventStream => _callEventController.stream;

  /// Упрощённый текстовый статус для UI: calling / ringing / connected / ended / failed.
  static final StreamController<String> _callStatusController =
      StreamController<String>.broadcast();
  static Stream<String> get callStatusStream => _callStatusController.stream;
  static String callStatus = 'idle';

  static ActiveCall? _activeCall;
  static ActiveCall? get activeCall => _activeCall;

  /// Пока идёт исходящий, входящий «эхо»-инвайт на identity master игнорируем.
  static bool placingOutgoing = false;

  /// Заявка, с которой мастер набрал номер — ИИ кладёт запись в эту карточку.
  static String? pendingJobId;

  /// Коллекция звонков в Firestore (пишется в основном Firebase Functions).
  static CollectionReference get _callsRef => FirestoreService.callsRef;

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Инициализация: запрашивает разрешения, регистрирует устройство в Twilio
  /// и начинает слушать события звонков. Безопасно вызывать многократно.
  static Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      await TwilioVoicePlatform.instance.requestMicAccess();

      if (_isAndroid) {
        await TwilioVoicePlatform.instance.requestCallPhonePermission();
        await TwilioVoicePlatform.instance.requestReadPhoneStatePermission();
        await TwilioVoicePlatform.instance.requestReadPhoneNumbersPermission();
        await TwilioVoicePlatform.instance.requestManageOwnCallsPermission();
        // Всегда перерегистрируем: старый CALL_PROVIDER-аккаунт нужно заменить
        // на self-managed, иначе входящие звонки всплывают в системном Phone.
        await TwilioVoicePlatform.instance.registerPhoneAccount();
        final enabled = await TwilioVoicePlatform.instance.isPhoneAccountEnabled();
        if (!enabled) {
          debugPrint(
            'TwilioService: self-managed аккаунт вызовов ещё не активен — '
            'откройте настройки аккаунта (TwilioService.openPhoneAccountSettings)',
          );
        }
      }

      final accessToken = await _fetchAccessToken();
      if (accessToken == null) {
        debugPrint('TwilioService: не удалось получить access token — проверьте настройку Firebase Functions');
        return;
      }

      String? deviceToken;
      if (!kIsWeb) {
        try {
          deviceToken = await FirebaseMessaging.instance.getToken();
        } catch (e) {
          debugPrint('TwilioService: не удалось получить FCM токен: $e');
        }
      }

      await TwilioVoicePlatform.instance.setTokens(
        accessToken: accessToken,
        deviceToken: deviceToken,
      );
      await TwilioVoicePlatform.instance.registerClient(kTwilioMasterIdentity, 'Мастер');
      await TwilioVoicePlatform.instance.setDefaultCallerName('Клиент');
      await TwilioVoicePlatform.instance.setAllowIncomingWhileBusy(allow: false);

      if (!_eventsAttached) {
        TwilioVoicePlatform.instance.callEventsListener.listen(_handleCallEvent);
        _eventsAttached = true;
      }

      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
        final token = await _fetchAccessToken();
        if (token != null) {
          await TwilioVoicePlatform.instance.setTokens(accessToken: token, deviceToken: newToken);
        }
      });

      _isInitialized = true;
      debugPrint('TwilioService: инициализирован');
    } catch (e) {
      debugPrint('TwilioService: ошибка инициализации: $e');
    }
  }

  static Future<String?> _fetchAccessToken() async {
    try {
      final response = await http.get(
        Uri.parse('$kFirebaseFunctionsUrl/twilioAccessToken?identity=$kTwilioMasterIdentity'),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['token'];
      }
      debugPrint('TwilioService: сервер вернул ${response.statusCode}: ${response.body}');
    } catch (e) {
      debugPrint('TwilioService: ошибка получения токена: $e');
    }
    return null;
  }

  static void _setCallStatus(String status) {
    callStatus = status;
    _callStatusController.add(status);
  }

  static void _handleCallEvent(CallEvent event) {
    debugPrint('TwilioService: событие звонка: $event');
    if (placingOutgoing &&
        (event == CallEvent.incoming ||
            event == CallEvent.missedCall ||
            event == CallEvent.declined)) {
      debugPrint('TwilioService: игнорируем $event во время исходящего');
      return;
    }
    _callEventController.add(event);

    switch (event) {
      case CallEvent.incoming:
      case CallEvent.ringing:
        _activeCall = TwilioVoicePlatform.instance.call.activeCall;
        _activeCallController.add(_activeCall);
        _setCallStatus(
          _activeCall?.callDirection == CallDirection.incoming ? 'ringing' : 'calling',
        );
        break;
      case CallEvent.connected:
      case CallEvent.answer:
      case CallEvent.reconnected:
        _activeCall = TwilioVoicePlatform.instance.call.activeCall;
        _activeCallController.add(_activeCall);
        _setCallStatus('connected');
        break;
      case CallEvent.callEnded:
      case CallEvent.declined:
      case CallEvent.missedCall:
        placingOutgoing = false;
        _activeCall = null;
        _activeCallController.add(null);
        _setCallStatus('ended');
        break;
      default:
        break;
    }
  }

  /// Возвращает номер звонящего в читаемом виде. Плагин иногда отдаёт
  /// внутренний короткий идентификатор (6 цифр) вместо реального Caller ID —
  /// такие значения отбрасываем.
  static String displayIncomingNumber(ActiveCall? call) {
    if (call == null) return '';
    for (final candidate in [call.from, call.fromFormatted]) {
      final pretty = _prettyPhone(candidate);
      if (pretty != null) return pretty;
    }
    return call.fromFormatted.isNotEmpty ? call.fromFormatted : call.from;
  }

  static String? _prettyPhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 10) return null;
    final d = digits.substring(digits.length - 10);
    return '(${d.substring(0, 3)}) ${d.substring(3, 6)}-${d.substring(6)}';
  }

  /// Форматирует номер под североамериканский стандарт E.164.
  static String _formatNumber(String phoneNumber) {
    String formatted = phoneNumber.replaceAll(RegExp(r'[^\d+]'), '');
    if (formatted.startsWith('+')) return formatted;
    if (formatted.length == 10) return '+1$formatted';
    if (formatted.length == 11 && formatted.startsWith('1')) return '+$formatted';
    return '+$formatted';
  }

  /// Совершить исходящий звонок на номер клиента.
  static Future<bool> makeCall(String phoneNumber, {String? jobId}) async {
    if (!_isInitialized) {
      await initialize();
    }
    if (!_isInitialized) return false;

    pendingJobId = (jobId != null && jobId.isNotEmpty) ? jobId : null;
    if (pendingJobId != null) {
      await _writePendingOutbound(phoneNumber, pendingJobId!);
    }

    placingOutgoing = true;
    try {
      final result = await TwilioVoicePlatform.instance.call.place(
        from: kTwilioMasterIdentity,
        to: _formatNumber(phoneNumber),
      );
      if (result != true) {
        placingOutgoing = false;
      } else if (pendingJobId != null) {
        unawaited(_tagLatestOutboundWithJob(phoneNumber, pendingJobId!));
      }
      return result == true;
    } catch (e) {
      placingOutgoing = false;
      debugPrint('TwilioService: ошибка исходящего звонка: $e');
      return false;
    }
  }

  static Future<void> _writePendingOutbound(String phone, String jobId) async {
    try {
      await FirestoreService.settingsRef.doc('pending_outbound_call').set({
        'jobId': jobId,
        'phone': _digits(phone),
        'at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('TwilioService pending outbound: $e');
    }
  }

  static Future<void> _tagLatestOutboundWithJob(
    String phone,
    String jobId,
  ) async {
    final want = _digits(phone);
    for (var i = 0; i < 24; i++) {
      await Future<void>.delayed(
        Duration(milliseconds: i == 0 ? 700 : 500),
      );
      try {
        final snapshot =
            await _callsRef.orderBy('startTime', descending: true).limit(10).get();
        for (final doc in snapshot.docs) {
          final data = doc.data() as Map<String, dynamic>;
          if (data['direction'] != 'outbound') continue;
          final to = _digits((data['toNumber'] ?? '').toString());
          if (want.length >= 10 && to.length >= 10 && to != want) continue;
          if ((data['jobId'] ?? '').toString() == jobId) return;
          await doc.reference.set({'jobId': jobId}, SetOptions(merge: true));
          return;
        }
      } catch (e) {
        debugPrint('TwilioService tag outbound: $e');
      }
    }
  }

  static String? parentCallSid([ActiveCall? call]) {
    final params = (call ?? _activeCall)?.customParams;
    if (params == null) return null;
    for (final key in ['parentCallSid', 'ParentCallSid']) {
      final value = params[key]?.toString() ?? '';
      if (value.startsWith('CA')) return value;
    }
    return null;
  }

  static String _digits(String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');
    return digits.length > 10 ? digits.substring(digits.length - 10) : digits;
  }

  static Future<DocumentReference?> _latestInboundCallRef(String? phoneNumber) async {
    final sid = parentCallSid();
    if (sid != null) return _callsRef.doc(sid);

    final snapshot = await _callsRef.orderBy('startTime', descending: true).limit(12).get();
    final want = _digits(phoneNumber ?? '');
    for (final doc in snapshot.docs) {
      final data = doc.data() as Map<String, dynamic>;
      if (data['direction'] != 'inbound') continue;
      final status = (data['status'] ?? '').toString();
      if (status == 'completed' || status == 'canceled') continue;
      if (want.length >= 10) {
        final from = _digits((data['fromNumber'] ?? '').toString());
        if (from != want) continue;
      }
      return doc.reference;
    }
    return null;
  }

  static Future<void> _flagInboundCall(String? phoneNumber, Map<String, dynamic> flags) async {
    final ref = await _latestInboundCallRef(phoneNumber);
    if (ref == null) {
      debugPrint('TwilioService: не нашёл входящий звонок для $flags');
      return;
    }
    await ref.set(flags, SetOptions(merge: true));
  }

  /// Красная кнопка: сбросить клиента, ИИ не берёт трубку.
  static Future<void> declineIncoming({String? phoneNumber}) async {
    try {
      await _flagInboundCall(phoneNumber, {
        'declineNoAi': true,
        'handoffToAi': false,
      });
    } catch (e) {
      debugPrint('TwilioService.declineIncoming: $e');
    }
    await hangUp();
  }

  /// Переключить текущего клиента на ИИ-секретаря.
  static Future<void> sendToAiSecretary({String? phoneNumber}) async {
    await _flagInboundCall(phoneNumber, {
      'handoffToAi': true,
      'declineNoAi': false,
    });
    await hangUp();
  }

  static Future<void> answerIncomingCall() async {
    await TwilioVoicePlatform.instance.call.answer();
  }

  static Future<void> hangUp() async {
    placingOutgoing = false;
    final jobId = pendingJobId;
    final phone = _activeCall?.to ?? _activeCall?.toFormatted ?? '';
    try {
      await TwilioVoicePlatform.instance.call.hangUp();
    } catch (e) {
      debugPrint('TwilioService: hangUp: $e');
    }
    _activeCall = null;
    _activeCallController.add(null);
    _setCallStatus('ended');
    if (jobId != null && jobId.isNotEmpty) {
      unawaited(_tagLatestOutboundWithJob(phone, jobId));
    }
    pendingJobId = null;
  }

  /// Incoming UI leftover after the secretary already answered, or after the
  /// invite was cancelled while the app was closed.
  static Future<bool> dropStaleIncomingIfNeeded() async {
    final active = _activeCall ?? TwilioVoicePlatform.instance.call.activeCall;
    if (active == null) return false;
    if (active.callDirection != CallDirection.incoming) return false;
    if (callStatus == 'connected') return false;

    var stale = false;
    try {
      final snapshot = await _callsRef
          .where('direction', isEqualTo: 'inbound')
          .orderBy('startTime', descending: true)
          .limit(1)
          .get();
      if (snapshot.docs.isNotEmpty) {
        final data = snapshot.docs.first.data() as Map<String, dynamic>;
        final status = (data['status'] ?? '').toString();
        final answeredBy = (data['answeredBy'] ?? '').toString();
        final start = CallRecord.parseStamp(data['startTime']);
        final tooOld = start != null &&
            DateTime.now().difference(start) > const Duration(seconds: 40);
        stale = tooOld ||
            answeredBy == 'ai' ||
            status == 'in-progress' ||
            status == 'completed' ||
            status == 'no-answer' ||
            status == 'busy' ||
            status == 'failed';
      }
    } catch (e) {
      debugPrint('TwilioService.dropStaleIncomingIfNeeded: $e');
    }

    if (!stale) return false;
    debugPrint('TwilioService: dropping stale incoming invite');
    await hangUp();
    return true;
  }

  static Future<bool> toggleMute() async {
    final isMuted = await TwilioVoicePlatform.instance.call.isMuted() ?? false;
    await TwilioVoicePlatform.instance.call.toggleMute(!isMuted);
    return !isMuted;
  }

  static Future<bool> toggleSpeaker() async {
    final isSpeaker = await TwilioVoicePlatform.instance.call.isOnSpeaker() ?? false;
    await TwilioVoicePlatform.instance.call.toggleSpeaker(!isSpeaker);
    return !isSpeaker;
  }

  static Future<void> sendDigits(String digits) async {
    await TwilioVoicePlatform.instance.call.sendDigits(digits);
  }

  /// Звонки, где секретарь уже извлёк данные и мастер их ещё не проверил.
  /// Показываются в колокольчике.
  static Stream<List<CallRecord>> getPendingReviewCalls() {
    return _callsRef
        .where('aiStatus', isEqualTo: 'done')
        .where('reviewed', isEqualTo: false)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => CallRecord.fromMap(doc.data() as Map<String, dynamic>, doc.id))
            .toList()
          ..sort((a, b) => (b.startTime ?? DateTime(0)).compareTo(a.startTime ?? DateTime(0))));
  }

  static Stream<List<CallRecord>> getAiProcessingCalls() {
    return _callsRef
        .where('aiStatus', isEqualTo: 'processing')
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => CallRecord.fromMap(doc.data() as Map<String, dynamic>, doc.id))
            .toList()
          ..sort((a, b) => (b.startTime ?? DateTime(0)).compareTo(a.startTime ?? DateTime(0))));
  }

  static Stream<List<CallRecord>> getAllCalls() {
    return _callsRef.orderBy('startTime', descending: true).limit(100).snapshots().map(
          (snapshot) => snapshot.docs
              .map((doc) => CallRecord.fromMap(doc.data() as Map<String, dynamic>, doc.id))
              .toList(),
        );
  }

  static Stream<List<CallRecord>> streamAll() {
    return _callsRef.snapshots().map(
          (snapshot) => snapshot.docs
              .map((doc) => CallRecord.fromMap(doc.data() as Map<String, dynamic>, doc.id))
              .toList(),
        );
  }

  static Stream<CallRecord?> watchCall(String callId) {
    if (callId.trim().isEmpty) return Stream.value(null);
    return _callsRef.doc(callId).snapshots().map((snapshot) {
      final data = snapshot.data();
      if (data == null) return null;
      return CallRecord.fromMap(data as Map<String, dynamic>, snapshot.id);
    });
  }

  static Future<void> markReviewed(String callId) async {
    await _callsRef.doc(callId).set({'reviewed': true}, SetOptions(merge: true));
  }

  static Future<void> markAllPendingReviewed() async {
    final snap = await _callsRef
        .where('aiStatus', isEqualTo: 'done')
        .where('reviewed', isEqualTo: false)
        .get();
    if (snap.docs.isEmpty) return;
    final batch = FirebaseFirestore.instance.batch();
    for (final doc in snap.docs) {
      batch.set(doc.reference, {'reviewed': true}, SetOptions(merge: true));
    }
    await batch.commit();
  }

  static Future<void> markJobCallsReviewed(String jobId) async {
    if (jobId.trim().isEmpty) return;
    final snaps = await Future.wait([
      _callsRef.where('createdJobId', isEqualTo: jobId).get(),
      _callsRef.where('jobId', isEqualTo: jobId).get(),
    ]);
    final ids = <String>{};
    for (final snap in snaps) {
      for (final doc in snap.docs) {
        ids.add(doc.id);
      }
    }
    for (final id in ids) {
      await _callsRef.doc(id).set({'reviewed': true}, SetOptions(merge: true));
    }
  }

  static bool _stuckRetryInFlight = false;

  /// Повторить ИИ-обработку записи (например, если она упала с ошибкой).
  static Future<void> retryAiProcessing(String callId) async {
    await _callsRef.doc(callId).set({
      'aiStatus': 'processing',
      'aiStartedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    try {
      final response = await http
          .post(
            Uri.parse('$kFirebaseFunctionsUrl/processCallRecording'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'callId': callId}),
          )
          .timeout(const Duration(seconds: 45));

      if (response.statusCode >= 400) {
        String message = 'Не удалось запустить ИИ';
        try {
          final decoded = json.decode(response.body);
          if (decoded is Map && decoded['error'] != null) {
            message = decoded['error'].toString();
          }
        } catch (_) {
          if (response.body.trim().isNotEmpty) message = response.body.trim();
        }
        await _callsRef.doc(callId).set({
          'aiStatus': 'error',
          'aiError': message,
        }, SetOptions(merge: true));
        throw Exception(message);
      }
    } on TimeoutException {
      debugPrint('TwilioService: повтор ИИ ещё выполняется на сервере');
    } catch (e) {
      debugPrint('TwilioService: ошибка повторной ИИ-обработки: $e');
      rethrow;
    }
  }

  /// При открытии истории звонков сам поднимает упавшие ИИ-задачи.
  static Future<void> retryStuckAiCalls() async {
    if (_stuckRetryInFlight) return;
    _stuckRetryInFlight = true;
    try {
      final snapshot = await _callsRef.where('aiStatus', isEqualTo: 'error').limit(15).get();
      var started = 0;
      for (final doc in snapshot.docs) {
        if (started >= 3) break;
        final data = doc.data() as Map<String, dynamic>;
        final retries = (data['aiRetryCount'] as num?)?.toInt() ?? 0;
        if (retries >= 5) continue;
        final duration = (data['durationSeconds'] as num?)?.toInt() ?? 0;
        final hasRecording = (data['recordingUrl'] ?? '').toString().isNotEmpty;
        if (!hasRecording && duration <= 0) continue;
        started++;
        try {
          await retryAiProcessing(doc.id);
        } catch (e) {
          debugPrint('TwilioService.retryStuckAiCalls ${doc.id}: $e');
        }
      }
    } catch (e) {
      debugPrint('TwilioService.retryStuckAiCalls: $e');
    } finally {
      _stuckRetryInFlight = false;
    }
  }

  /// Проверяет, активен ли self-managed аккаунт вызовов. Для self-managed
  /// Android обычно включает его сам; false значит, что регистрация не прошла.
  static Future<bool> isPhoneAccountEnabled() async {
    if (!_isAndroid) return true;
    try {
      return await TwilioVoicePlatform.instance.isPhoneAccountEnabled();
    } catch (e) {
      debugPrint('TwilioService: ошибка проверки аккаунта вызовов: $e');
      return false;
    }
  }

  /// Открывает системный экран Android, где нужно включить аккаунт вызовов
  /// приложения (Settings > Приложения > Приложения для звонков по умолчанию).
  static Future<void> openPhoneAccountSettings() async {
    if (!_isAndroid) return;
    try {
      await TwilioVoicePlatform.instance.registerPhoneAccount();
      await TwilioVoicePlatform.instance.openPhoneAccountSettings();
    } catch (e) {
      debugPrint('TwilioService: ошибка открытия настроек аккаунта вызовов: $e');
    }
  }

  static void dispose() {
    _activeCallController.close();
    _callStatusController.close();
    _callEventController.close();
  }
}
