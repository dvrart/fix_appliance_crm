import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:twilio_voice/twilio_voice.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../core/app_commands.dart';
import '../core/api_keys.dart';
import 'call_routing.dart';
import 'firestore_service.dart';
import 'auth_service.dart';
import 'network_status_service.dart';
import 'notification_service.dart';
import 'technician_service.dart';

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
  final String
  status; // 'ringing' | 'in-progress' | 'completed' | 'no-answer' | 'failed' | 'busy'
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
  final bool jobCreateBlocked;
  final DateTime? deletedAt;

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
    this.jobCreateBlocked = false,
    this.deletedAt,
  });

  bool get isDeleted => deletedAt != null;
  bool get aiBlocked => jobCreateBlocked || isDeleted;

  static const trashKeepDays = 30;

  int get trashDaysLeft {
    final deleted = deletedAt;
    if (deleted == null) return 0;
    return deleted
        .add(const Duration(days: trashKeepDays))
        .difference(DateTime.now())
        .inDays;
  }

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

  static int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  factory CallRecord.fromMap(Map<String, dynamic> map, String docId) {
    return CallRecord(
      id: docId,
      callSid: (map['callSid'] ?? docId).toString(),
      fromNumber: (map['fromNumber'] ?? '').toString(),
      toNumber: (map['toNumber'] ?? '').toString(),
      direction: (map['direction'] ?? 'inbound').toString(),
      startTime: parseStamp(map['startTime']) ?? parseStamp(map['createdAt']),
      endTime: parseStamp(map['endTime']),
      durationSeconds: _asInt(map['durationSeconds']),
      recordingUrl: (map['recordingUrl'] ?? '').toString().trim().isEmpty
          ? null
          : map['recordingUrl'].toString(),
      storageUrl: (map['storageUrl'] ?? '').toString().trim().isEmpty
          ? null
          : (map['storageUrl'] ?? '').toString(),
      transcription: map['transcription']?.toString(),
      transcriptionRu: (map['transcriptionRu'] ?? '').toString().trim().isEmpty
          ? null
          : (map['transcriptionRu'] ?? '').toString(),
      transcriptionEn: (map['transcriptionEn'] ?? '').toString().trim().isEmpty
          ? null
          : (map['transcriptionEn'] ?? '').toString(),
      summary: (map['summary'] ?? '').toString().trim().isEmpty
          ? null
          : (map['summary'] ?? '').toString(),
      status: (map['status'] ?? 'ringing').toString(),
      aiStatus: (map['aiStatus'] ?? 'none').toString(),
      aiError: map['aiError']?.toString(),
      extractedData: map['extractedData'] is Map
          ? Map<String, dynamic>.from(map['extractedData'] as Map)
          : null,
      aiReception: map['aiReception'] is Map
          ? Map<String, dynamic>.from(map['aiReception'] as Map)
          : null,
      clientId: map['clientId']?.toString(),
      createdJobId: () {
        final linked = (map['createdJobId'] ?? '').toString().trim();
        if (linked.isNotEmpty) return linked;
        final jobId = (map['jobId'] ?? '').toString().trim();
        return jobId.isEmpty ? null : jobId;
      }(),
      reviewed: map['reviewed'] == true,
      answeredBy: (map['answeredBy'] ?? '').toString(),
      serviceDeclined:
          map['serviceDeclined'] == true ||
          (map['extractedData'] is Map &&
              map['extractedData']['service_declined'] == true) ||
          (map['aiReception'] is Map &&
              map['aiReception']['serviceDeclined'] == true),
      jobCreateBlocked: map['jobCreateBlocked'] == true,
      deletedAt: parseStamp(map['deletedAt']),
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
  static bool _permissionsReady = false;
  static Future<void>? _initializing;
  static Future<void>? _registering;
  static Timer? _registrationRetry;
  static DateTime? _voiceTokenAt;
  static final registrationState = ValueNotifier<String>('pending');
  static String? lastPlaceError;
  static bool get isInitialized => _isInitialized;

  static final StreamController<ActiveCall?> _activeCallController =
      StreamController<ActiveCall?>.broadcast();
  static Stream<ActiveCall?> get activeCallStream =>
      _activeCallController.stream;

  static final StreamController<CallEvent> _callEventController =
      StreamController<CallEvent>.broadcast();
  static Stream<CallEvent> get callEventStream => _callEventController.stream;

  /// Упрощённый текстовый статус для UI: connecting / calling / ringing /
  /// answering (нажал «Ответить», звук ещё не поднялся) / connected (звук
  /// есть) / reconnecting / audioFailed / movingToCell / movedToCell /
  /// cell (звоним через SIM) / ended / failed.
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

  /// Как звонить: приложение / SIM / авто (Настройки → Телефон → Звонки).
  static CallRouting routing = const CallRouting();
  static bool _routingLoaded = false;
  static StreamSubscription<DocumentSnapshot>? _routingSub;

  /// Номер мастерской: телефон набирает его через SIM, сервер соединяет с
  /// клиентом. Приходит вместе с токеном Twilio и хранится на телефоне —
  /// звонок через SIM нужен как раз тогда, когда интернета почти нет.
  static String? _shopNumber;
  static const _shopNumberPrefsKey = 'twilio_shop_number';

  /// Что показать на экране звонка: предупреждения Twilio о связи, «клиент
  /// ответил» у исходящего и пояснение к переходу на SIM.
  static final qualityWarnings =
      ValueNotifier<Set<CallQualityWarning>>(const <CallQualityWarning>{});
  static final peerAnswered = ValueNotifier<bool>(false);
  static String? handoverNote;

  static Timer? _audioWatch;
  static Timer? _outboundWatch;
  static StreamSubscription<DocumentSnapshot>? _peerSub;
  static bool _movingToCell = false;
  static bool _switchingOutbound = false;
  static String? _outboundPhone;
  static String? _outboundJobId;

  /// Коллекция звонков в Firestore (пишется в основном Firebase Functions).
  static CollectionReference get _callsRef => FirestoreService.callsRef;

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static const _deviceChannel = MethodChannel('fix_appliance/device');

  /// Инициализация: запрашивает разрешения, регистрирует устройство в Twilio
  /// и начинает слушать события звонков. Безопасно вызывать многократно.
  static Future<void> initialize() {
    _attachCallEvents();
    if (AuthService.signedIn) _watchRouting();
    if (_isInitialized || !AuthService.signedIn) return Future.value();
    return _initializing ??= _initialize().whenComplete(
      () => _initializing = null,
    );
  }

  static void _attachCallEvents() {
    if (_eventsAttached) return;
    _eventsAttached = true;
    TwilioVoicePlatform.instance.callEventsListener.listen(_handleCallEvent);
    TwilioVoicePlatform.instance.call.qualityWarnings.listen(
      (event) => qualityWarnings.value = event.current,
      onError: (Object error) => debugPrint('TwilioService: quality: $error'),
    );
    TwilioVoicePlatform.instance.setOnDeviceTokenChanged((token) {
      unawaited(NotificationService.refreshRegistration(token: token));
      unawaited(refreshRegistration(deviceToken: token));
    });
    FirebaseMessaging.instance.onTokenRefresh.listen(
      (token) {
        unawaited(refreshRegistration(deviceToken: token));
      },
      onError: (Object error) =>
          debugPrint('TwilioService: token refresh: $error'),
    );
    NetworkStatusService.offline.addListener(() {
      if (!NetworkStatusService.offline.value) unawaited(refreshRegistration());
    });
  }

  static Future<void> _initialize() async {
    try {
      if (!_permissionsReady) {
        await TwilioVoicePlatform.instance.requestMicAccess();

        if (_isAndroid) {
          await TwilioVoicePlatform.instance.requestCallPhonePermission();
          await TwilioVoicePlatform.instance.requestReadPhoneStatePermission();
          await TwilioVoicePlatform.instance
              .requestReadPhoneNumbersPermission();
          await TwilioVoicePlatform.instance.requestManageOwnCallsPermission();
          try {
            await Permission.bluetoothConnect.request();
          } catch (e) {
            debugPrint('TwilioService: bluetoothConnect: $e');
          }
          // Всегда перерегистрируем: старый CALL_PROVIDER-аккаунт нужно заменить
          // на self-managed, иначе входящие звонки всплывают в системном Phone.
          await TwilioVoicePlatform.instance.registerPhoneAccount();
          final enabled = await TwilioVoicePlatform.instance
              .isPhoneAccountEnabled();
          if (!enabled) {
            debugPrint(
              'TwilioService: self-managed аккаунт вызовов ещё не активен — '
              'откройте настройки аккаунта (TwilioService.openPhoneAccountSettings)',
            );
          }
        }

        _permissionsReady = true;
      }
      TwilioVoicePlatform.instance.showMissedCallNotifications = false;
      await TwilioVoicePlatform.instance.setAllowIncomingWhileBusy(
        allow: false,
      );
      if (!await _refreshVoiceToken()) {
        _retryRegistration();
        return;
      }
      debugPrint('TwilioService: инициализирован');
    } catch (e) {
      debugPrint('TwilioService: ошибка инициализации: $e');
      _retryRegistration();
    }
  }

  static Future<void> refreshRegistration({String? deviceToken}) {
    if (!AuthService.signedIn) return Future.value();
    if (!_isInitialized) return initialize();
    if (deviceToken == null &&
        _voiceTokenAt != null &&
        DateTime.now().difference(_voiceTokenAt!) <
            const Duration(minutes: 45)) {
      return Future.value();
    }
    return _registering ??= _refreshRegistration(
      deviceToken,
    ).whenComplete(() => _registering = null);
  }

  static Future<void> _refreshRegistration(String? deviceToken) async {
    try {
      if (!await _refreshVoiceToken(newDeviceToken: deviceToken)) {
        _retryRegistration();
      }
    } catch (error) {
      debugPrint('TwilioService: регистрация будет повторена: $error');
      _retryRegistration();
    }
  }

  static void _retryRegistration() {
    registrationState.value = 'retrying';
    _registrationRetry?.cancel();
    if (!AuthService.signedIn) return;
    _registrationRetry = Timer(const Duration(seconds: 30), () {
      unawaited(refreshRegistration());
    });
  }

  static String get currentClientIdentity => TechnicianService.isTechnician
      ? 'tech_${TechnicianService.currentUid}'
      : kTwilioMasterIdentity;

  static String get _pendingCellDocId => TechnicianService.isTechnician
      ? 'pending_cell_call_${TechnicianService.currentUid}'
      : 'pending_cell_call';

  static String get _pendingOutboundDocId => TechnicianService.isTechnician
      ? 'pending_outbound_call_${TechnicianService.currentUid}'
      : 'pending_outbound_call';

  static Future<String?> _fetchAccessToken() async {
    try {
      final identity = Uri.encodeQueryComponent(currentClientIdentity);
      final response = await http
          .get(
            Uri.parse(
              '$kFirebaseFunctionsUrl/twilioAccessToken?identity=$identity',
            ),
            headers: await AuthService.headers(),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        _rememberShopNumber(data['shopNumber']?.toString());
        return data['token'];
      }
      debugPrint('TwilioService: сервер вернул ${response.statusCode}');
    } catch (e) {
      debugPrint('TwilioService: ошибка получения токена: $e');
    }
    return null;
  }

  static void _setCallStatus(String status) {
    callStatus = status;
    _callStatusController.add(status);
    _syncOutgoingRingback();
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
        if (_activeCall?.callDirection == CallDirection.incoming) {
          qualityWarnings.value = const <CallQualityWarning>{};
        }
        _setCallStatus(
          _activeCall?.callDirection == CallDirection.incoming
              ? 'ringing'
              : 'calling',
        );
        break;
      case CallEvent.answer:
        _activeCall = TwilioVoicePlatform.instance.call.activeCall;
        _activeCallController.add(_activeCall);
        // «Ответить» нажато, но звук ещё не поднялся — клиент мастера пока не
        // слышит. Раньше здесь сразу ставилось connected и шёл таймер: мастер
        // видел разговор и слушал тишину (разбор 26.10.2026).
        if (callStatus != 'connected' && callStatus != 'reconnecting') {
          _setCallStatus('answering');
          _startAudioWatch();
        }
        break;
      case CallEvent.connected:
      case CallEvent.reconnected:
        {
          _activeCall = TwilioVoicePlatform.instance.call.activeCall;
          _activeCallController.add(_activeCall);
          final firstAudio =
              callStatus != 'connected' && callStatus != 'reconnecting';
          _cancelAudioWatch();
          _cancelOutboundWatch();
          _setCallStatus('connected');
          if (firstAudio && event == CallEvent.connected) _onAudioConnected();
        }
        break;
      case CallEvent.reconnecting:
        _setCallStatus('reconnecting');
        break;
      case CallEvent.callEnded:
      case CallEvent.declined:
      case CallEvent.missedCall:
        _onCallFinished(event);
        break;
      default:
        break;
    }
  }

  static void _onAudioConnected() {
    if (_activeCall?.callDirection == CallDirection.incoming) {
      // Входящий: клиент уже на линии, значит соединились именно с ним.
      unawaited(buzzConnected());
      return;
    }
    // Исходящий: поднялся канал до Twilio, а клиент ещё слушает гудки.
    // Вибрация будет, когда сервер отметит «клиент ответил».
    unawaited(_watchPeerAnswer(_outboundPhone ?? _activeCall?.to ?? ''));
  }

  static const _handoverStatuses = {'cell', 'movingToCell', 'movedToCell'};

  static void _onCallFinished(CallEvent event) {
    _cancelAudioWatch();
    _cancelOutboundWatch();
    final wasAnswering = callStatus == 'answering' || callStatus == 'audioFailed';
    final outboundNoAudio = placingOutgoing &&
        const {'connecting', 'calling', 'ringing'}.contains(callStatus);
    if (_movingToCell ||
        _switchingOutbound ||
        _handoverStatuses.contains(callStatus)) {
      // Звонок уже уходит на SIM — экран сам скажет, что делать дальше.
      _activeCall = null;
      _activeCallController.add(null);
      return;
    }
    if (event == CallEvent.callEnded) {
      if (outboundNoAudio && routing.outboundAutoFallback) {
        // Канал до Twilio так и не поднялся: звоним этому клиенту через SIM.
        unawaited(_fallbackOutboundToCell());
        return;
      }
      if (routing.autoFallback && wasAnswering && parentCallSid() != null) {
        unawaited(moveIncomingToCell());
        return;
      }
    }
    placingOutgoing = false;
    _activeCall = null;
    _activeCallController.add(null);
    _resetCallSignals();
    if (event == CallEvent.callEnded && (wasAnswering || outboundNoAudio)) {
      lastPlaceError = 'Звук не соединился: слабый интернет. Клиент вас не слышал.';
      _setCallStatus('failed');
      return;
    }
    _setCallStatus('ended');
  }

  static void _resetCallSignals() {
    qualityWarnings.value = const <CallQualityWarning>{};
    peerAnswered.value = false;
    unawaited(_peerSub?.cancel());
    _peerSub = null;
    _outboundPhone = null;
    _outboundJobId = null;
  }

  static void _startAudioWatch() {
    _audioWatch?.cancel();
    _audioWatch = Timer(CallRouting.audioTimeout, () {
      if (callStatus != 'answering') return;
      if (routing.autoFallback) {
        unawaited(moveIncomingToCell());
      } else {
        _setCallStatus('audioFailed');
      }
    });
  }

  static void _cancelAudioWatch() {
    _audioWatch?.cancel();
    _audioWatch = null;
  }

  static void _startOutboundWatch() {
    _outboundWatch?.cancel();
    _outboundWatch = Timer(CallRouting.audioTimeout, () {
      if (!placingOutgoing) return;
      if (callStatus == 'connected' || callStatus == 'reconnecting') return;
      unawaited(_fallbackOutboundToCell());
    });
  }

  static void _cancelOutboundWatch() {
    _outboundWatch?.cancel();
    _outboundWatch = null;
  }

  static void _watchRouting() {
    if (_routingSub != null) return;
    _routingSub = FirestoreService.configRef.snapshots().listen(
      (doc) {
        routing = CallRouting.fromConfig(
          (doc.data() as Map<String, dynamic>?) ?? const <String, dynamic>{},
        );
        _routingLoaded = true;
      },
      onError: (Object error) => debugPrint('TwilioService: routing: $error'),
    );
  }

  static Future<CallRouting> _currentRouting() async {
    if (_routingLoaded) return routing;
    try {
      final doc = await FirestoreService.configRef.get().timeout(
            const Duration(seconds: 2),
          );
      routing = CallRouting.fromConfig(
        (doc.data() as Map<String, dynamic>?) ?? const <String, dynamic>{},
      );
    } catch (e) {
      debugPrint('TwilioService: routing read: $e');
    }
    return routing;
  }

  static void _rememberShopNumber(String? value) {
    final number = CallRouting.normalizePhone(value ?? '');
    if (number.isEmpty || number == _shopNumber) return;
    _shopNumber = number;
    unawaited(
      SharedPreferences.getInstance()
          .then((prefs) => prefs.setString(_shopNumberPrefsKey, number))
          .catchError((Object _) => false),
    );
  }

  static Future<String?> _shopNumberOrNull() async {
    if (_shopNumber != null) return _shopNumber;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_shopNumberPrefsKey);
      if (saved != null && saved.isNotEmpty) return _shopNumber = saved;
    } catch (e) {
      debugPrint('TwilioService: shop number prefs: $e');
    }
    await _fetchAccessToken();
    return _shopNumber;
  }

  /// Двойная вибрация «клиент на линии».
  static Future<void> buzzConnected() async {
    if (!_isAndroid) return;
    try {
      await _deviceChannel.invokeMethod('vibrateCallConnected');
    } catch (e) {
      debugPrint('TwilioService: vibrate: $e');
    }
  }

  /// Исходящий из приложения: ждём от сервера отметку «клиент ответил» —
  /// она приходит, когда клиент снял трубку, а не когда поднялся канал.
  static Future<void> _watchPeerAnswer(String phone) async {
    await _peerSub?.cancel();
    _peerSub = null;
    final want = _digits(phone);
    for (var i = 0; i < 10 && placingOutgoing; i++) {
      try {
        final snapshot = await _callsRef
            .orderBy('startTime', descending: true)
            .limit(6)
            .get();
        for (final doc in snapshot.docs) {
          final data = doc.data() as Map<String, dynamic>;
          if (data['direction'] != 'outbound') continue;
          final to = _digits((data['toNumber'] ?? '').toString());
          if (want.length >= 10 && to != want) continue;
          final started = CallRecord.parseStamp(data['startTime']);
          if (started != null &&
              DateTime.now().difference(started) > const Duration(minutes: 3)) {
            continue;
          }
          if (!placingOutgoing) return;
          _peerSub = doc.reference.snapshots().listen((snap) {
            final map = snap.data() as Map<String, dynamic>?;
            if (map == null || map['peerAnsweredAt'] == null) return;
            if (peerAnswered.value) return;
            peerAnswered.value = true;
            unawaited(buzzConnected());
          }, onError: (Object error) => debugPrint('TwilioService: peer: $error'));
          return;
        }
      } catch (e) {
        debugPrint('TwilioService: peer lookup: $e');
      }
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
  }

  /// Перевести текущий входящий на SIM: звук в приложении не поднялся.
  /// Сервер перенаправит звонок, и телефон зазвонит обычным звонком.
  static Future<bool> moveIncomingToCell() async {
    final sid = parentCallSid();
    if (sid == null || !routing.hasCell || _movingToCell) return false;
    _cancelAudioWatch();
    _movingToCell = true;
    _setCallStatus('movingToCell');
    try {
      await settleWrite(
        _callsRef.doc(sid).set({
          'moveToCellRequested': true,
          'moveToCellAskedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true)),
      );
    } catch (e) {
      debugPrint('TwilioService: move flag: $e');
    }
    final moved = _requestMoveToCell(sid);
    try {
      await TwilioVoicePlatform.instance.call.hangUp();
    } catch (e) {
      debugPrint('TwilioService: move hangUp: $e');
    }
    final ok = await moved;
    _movingToCell = false;
    placingOutgoing = false;
    _activeCall = null;
    _activeCallController.add(null);
    _resetCallSignals();
    _setCallStatus('movedToCell');
    return ok;
  }

  static Future<bool> _requestMoveToCell(String callSid) async {
    try {
      final response = await http
          .post(
            Uri.parse('$kFirebaseFunctionsUrl/moveCallToCell'),
            headers: await AuthService.headers(),
            body: json.encode({'callSid': callSid}),
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) return false;
      final data = json.decode(response.body);
      return data is Map &&
          (data['moved'] == true || data['reason'] == 'already');
    } catch (e) {
      debugPrint('TwilioService: moveCallToCell: $e');
      return false;
    }
  }

  /// Позвонить клиенту через обычную сотовую связь: телефон набирает номер
  /// мастерской, сервер соединяет с клиентом. Клиент видит номер мастерской,
  /// разговор пишется и расшифровывается как обычно.
  static Future<bool> placeViaCell(
    String phoneNumber, {
    String? jobId,
    String? note,
  }) async {
    lastPlaceError = null;
    final shop = await _shopNumberOrNull();
    if (shop == null) {
      lastPlaceError =
          'Не знаю номер мастерской — откройте приложение с интернетом и повторите.';
      _setCallStatus('failed');
      return false;
    }
    handoverNote = note;
    _setCallStatus('cell');
    try {
      await settleWrite(
        FirestoreService.settingsRef.doc(_pendingCellDocId).set({
          'phone': _formatNumber(phoneNumber),
          'jobId': jobId ?? '',
          'at': FieldValue.serverTimestamp(),
        }),
      );
    } catch (e) {
      debugPrint('TwilioService: pending cell call: $e');
    }
    var placed = false;
    if (_isAndroid) {
      try {
        placed = await _deviceChannel.invokeMethod<bool>(
              'placeCellularCall',
              {'number': shop},
            ) ??
            false;
      } catch (e) {
        debugPrint('TwilioService: placeCellularCall: $e');
      }
    }
    if (!placed) {
      lastPlaceError = 'Телефон не дал позвонить через SIM.';
      _setCallStatus('failed');
      return false;
    }
    return true;
  }

  static Future<bool> _fallbackOutboundToCell() async {
    final phone = _outboundPhone;
    final jobId = _outboundJobId;
    if (phone == null || phone.isEmpty || _switchingOutbound) return false;
    _cancelOutboundWatch();
    _switchingOutbound = true;
    try {
      try {
        await TwilioVoicePlatform.instance.call.hangUp();
      } catch (e) {
        debugPrint('TwilioService: fallback hangUp: $e');
      }
      placingOutgoing = false;
      _activeCall = null;
      _activeCallController.add(null);
      return await placeViaCell(
        phone,
        jobId: jobId,
        note: 'Слабый интернет — звоню через сотовую связь',
      );
    } finally {
      _switchingOutbound = false;
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
    return '+$formatted';
  }

  static Future<bool> _refreshVoiceToken({String? newDeviceToken}) async {
    lastPlaceError = null;
    _registrationRetry?.cancel();
    final accessToken = await _fetchAccessToken();
    if (accessToken == null) {
      lastPlaceError = 'Нет токена Twilio. Проверьте интернет.';
      return false;
    }
    String? deviceToken = newDeviceToken;
    if (!kIsWeb && deviceToken == null) {
      try {
        deviceToken = await FirebaseMessaging.instance.getToken().timeout(
          const Duration(seconds: 10),
        );
      } catch (e) {
        debugPrint('TwilioService: FCM токен при звонке: $e');
      }
    }
    if (_isAndroid && (deviceToken == null || deviceToken.isEmpty)) {
      lastPlaceError = 'Не удалось зарегистрировать входящие звонки.';
      return false;
    }
    final registered = await TwilioVoicePlatform.instance
        .setTokens(accessToken: accessToken, deviceToken: deviceToken)
        .timeout(const Duration(seconds: 15));
    if (registered == false) return false;
    if (!_isInitialized) {
      await TwilioVoicePlatform.instance.registerClient(
        currentClientIdentity,
        'Мастер',
      );
      await TwilioVoicePlatform.instance.setDefaultCallerName('Клиент');
      _attachCallEvents();
      _isInitialized = true;
    }
    _voiceTokenAt = DateTime.now();
    registrationState.value = 'registered';
    return true;
  }

  /// Совершить исходящий звонок на номер клиента.
  static Future<bool> makeCall(String phoneNumber, {String? jobId}) async {
    lastPlaceError = null;
    handoverNote = null;
    _resetCallSignals();
    final route = await _currentRouting();
    if (route.outboundViaCell) {
      return placeViaCell(phoneNumber, jobId: jobId);
    }
    _setCallStatus('connecting');
    if (!_isInitialized) {
      await initialize();
    }
    // Skip full re-registration if Twilio token was recently refreshed (< 45 min).
    // This mirrors the same guard in refreshRegistration and avoids an HTTP
    // round-trip + FCM token fetch on every single outgoing call.
    final tokenFresh = _voiceTokenAt != null &&
        DateTime.now().difference(_voiceTokenAt!) <
            const Duration(minutes: 45);
    if (!tokenFresh) {
      final tokenOk = await _refreshVoiceToken();
      if (!tokenOk) {
        _setCallStatus('failed');
        return false;
      }
    }

    if (_isAndroid) {
      try {
        final enabled = await TwilioVoicePlatform.instance
            .isPhoneAccountEnabled();
        if (enabled == false) {
          lastPlaceError = 'Аккаунт звонков выключен в настройках телефона.';
          debugPrint('TwilioService: PhoneAccount выключен');
        }
      } catch (e) {
        debugPrint('TwilioService: isPhoneAccountEnabled: $e');
      }
    }

    pendingJobId = (jobId != null && jobId.isNotEmpty) ? jobId : null;
    if (pendingJobId != null) {
      await _writePendingOutbound(phoneNumber, pendingJobId!);
    }

    _outboundPhone = phoneNumber;
    _outboundJobId = jobId;
    placingOutgoing = true;
    _setCallStatus('calling');
    try {
      final result = await TwilioVoicePlatform.instance.call.place(
        from: currentClientIdentity,
        to: _formatNumber(phoneNumber),
      );
      if (result != true) {
        placingOutgoing = false;
        lastPlaceError ??= 'Телефон не принял вызов.';
        if (route.outboundAutoFallback) return _fallbackOutboundToCell();
        _setCallStatus('failed');
      } else {
        if (pendingJobId != null) {
          unawaited(_tagLatestOutboundWithJob(phoneNumber, pendingJobId!));
        }
        // «Авто»: не поднялся канал за 7 секунд — звоним через SIM.
        if (route.outboundAutoFallback) _startOutboundWatch();
      }
      return result == true;
    } catch (e) {
      placingOutgoing = false;
      lastPlaceError = e.toString();
      debugPrint('TwilioService: ошибка исходящего звонка: $e');
      if (route.outboundAutoFallback) return _fallbackOutboundToCell();
      _setCallStatus('failed');
      return false;
    }
  }

  static Future<void> _writePendingOutbound(String phone, String jobId) async {
    try {
      await settleWrite(
        FirestoreService.settingsRef.doc(_pendingOutboundDocId).set({
          'jobId': jobId,
          'phone': _digits(phone),
          'at': FieldValue.serverTimestamp(),
        }),
      );
    } catch (e) {
      debugPrint('TwilioService pending outbound: $e');
    }
  }

  static Future<void> _tagLatestOutboundWithJob(
    String phone,
    String jobId,
  ) async {
    if (TechnicianService.isTechnician) return;
    final want = _digits(phone);
    for (var i = 0; i < 24; i++) {
      await Future<void>.delayed(Duration(milliseconds: i == 0 ? 700 : 500));
      try {
        final snapshot = await _callsRef
            .orderBy('startTime', descending: true)
            .limit(10)
            .get();
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

  static Future<DocumentReference?> _latestInboundCallRef(
    String? phoneNumber,
  ) async {
    final sid = parentCallSid();
    if (sid != null) return _callsRef.doc(sid);

    final snapshot = await _callsRef
        .orderBy('startTime', descending: true)
        .limit(12)
        .get();
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

  static Future<void> _flagInboundCall(
    String? phoneNumber,
    Map<String, dynamic> flags,
  ) async {
    final ref = await _latestInboundCallRef(
      phoneNumber,
    ).timeout(const Duration(seconds: 2));
    if (ref == null) {
      debugPrint('TwilioService: не нашёл входящий звонок для $flags');
      return;
    }
    await settleWrite(ref.set(flags, SetOptions(merge: true)));
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
    _cancelAudioWatch();
    _cancelOutboundWatch();
    final jobId = pendingJobId;
    final phone = _activeCall?.to ?? _activeCall?.toFormatted ?? '';
    try {
      await TwilioVoicePlatform.instance.call.hangUp();
    } catch (e) {
      debugPrint('TwilioService: hangUp: $e');
    }
    _activeCall = null;
    _activeCallController.add(null);
    _resetCallSignals();
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

    final sid = parentCallSid(active);
    if (sid == null) return false;
    var stale = false;
    try {
      final snapshot = await _callsRef
          .doc(sid)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(milliseconds: 1500));
      if (snapshot.exists) {
        stale = isStaleIncomingRecord({
          ...Map<String, dynamic>.from(snapshot.data() as Map),
          'callSid': snapshot.id,
        }, expectedCallSid: sid);
      }
    } catch (e) {
      debugPrint('TwilioService.dropStaleIncomingIfNeeded: $e');
    }

    final current = _activeCall ?? TwilioVoicePlatform.instance.call.activeCall;
    if (!stale || callStatus == 'connected' || parentCallSid(current) != sid) {
      return false;
    }
    debugPrint('TwilioService: dropping stale incoming invite');
    await hangUp();
    return true;
  }

  static bool isStaleIncomingRecord(
    Map<String, dynamic> data, {
    required String expectedCallSid,
  }) {
    if (expectedCallSid.isEmpty || data['callSid'] != expectedCallSid) {
      return false;
    }
    return data['answeredBy'] == 'ai' ||
        const {
          'completed',
          'canceled',
          'cancelled',
          'no-answer',
          'busy',
          'failed',
        }.contains(data['status']);
  }

  static Future<bool> toggleMute() async {
    final isMuted = await TwilioVoicePlatform.instance.call.isMuted() ?? false;
    await TwilioVoicePlatform.instance.call.toggleMute(!isMuted);
    return !isMuted;
  }

  static Future<bool> toggleSpeaker() async {
    final isSpeaker =
        await TwilioVoicePlatform.instance.call.isOnSpeaker() ?? false;
    await setSpeaker(!isSpeaker);
    return !isSpeaker;
  }

  static Future<void> setSpeaker(bool on) async {
    await TwilioVoicePlatform.instance.call.toggleSpeaker(on);
  }

  static bool _ringbackOn = false;

  static void _syncOutgoingRingback() {
    final want =
        placingOutgoing &&
        (callStatus == 'connecting' ||
            callStatus == 'calling' ||
            callStatus == 'ringing');
    if (want == _ringbackOn) return;
    _ringbackOn = want;
    if (want) {
      unawaited(playOutgoingRingback());
    } else {
      unawaited(stopOutgoingRingback());
    }
  }

  static Future<void> playOutgoingRingback() async {
    if (!_isAndroid) return;
    try {
      await _deviceChannel.invokeMethod('playOutgoingRingback');
      if (!_ringbackOn) {
        await _deviceChannel.invokeMethod('stopOutgoingRingback');
      }
    } catch (e) {
      debugPrint('TwilioService: playOutgoingRingback: $e');
    }
  }

  static Future<void> stopOutgoingRingback() async {
    if (!_isAndroid) return;
    try {
      await _deviceChannel.invokeMethod('stopOutgoingRingback');
    } catch (e) {
      debugPrint('TwilioService: stopOutgoingRingback: $e');
    }
  }

  /// If the phone is on car Bluetooth / a headset, keep the call there.
  static Future<void> preferCarAudio() async {
    if (!_isAndroid) return;
    try {
      final hasCar =
          await _deviceChannel.invokeMethod<bool>('hasCarAudio') ?? false;
      if (!hasCar) return;
      final onSpeaker =
          await TwilioVoicePlatform.instance.call.isOnSpeaker() ?? false;
      if (onSpeaker) return;
      final onBt =
          await TwilioVoicePlatform.instance.call.isBluetoothOn() ?? false;
      if (!onBt) {
        await TwilioVoicePlatform.instance.call.toggleBluetooth(
          bluetoothOn: true,
        );
      }
    } catch (e) {
      debugPrint('TwilioService: preferCarAudio: $e');
    }
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
        .map(
          (snapshot) =>
              snapshot.docs
                  .map(
                    (doc) => CallRecord.fromMap(
                      doc.data() as Map<String, dynamic>,
                      doc.id,
                    ),
                  )
                  .where((call) => !call.isDeleted)
                  .toList()
                ..sort(
                  (a, b) => (b.startTime ?? DateTime(0)).compareTo(
                    a.startTime ?? DateTime(0),
                  ),
                ),
        );
  }

  /// Входящие, которые мастер ещё не открывал: счётчик на вкладке «Звонки».
  /// Исходящие сюда не попадают — у них `reviewed` остаётся false навсегда,
  /// и бейдж бы не гас. Идущий прямо сейчас звонок тоже не «новость».
  static Stream<List<CallRecord>> streamNewIncomingCalls() {
    return _callsRef
        .where('direction', isEqualTo: 'inbound')
        .where('reviewed', isEqualTo: false)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map(
                (doc) =>
                    CallRecord.fromMap(doc.data() as Map<String, dynamic>, doc.id),
              )
              .where(
                (call) =>
                    !call.isDeleted &&
                    !const [
                      'ringing',
                      'in-progress',
                      'queued',
                      'initiated',
                    ].contains(call.status),
              )
              .toList(),
        );
  }

  static Stream<List<CallRecord>> getAiProcessingCalls() {
    return _callsRef
        .where('aiStatus', isEqualTo: 'processing')
        .snapshots()
        .map(
          (snapshot) =>
              snapshot.docs
                  .map(
                    (doc) => CallRecord.fromMap(
                      doc.data() as Map<String, dynamic>,
                      doc.id,
                    ),
                  )
                  .where((call) => !call.isDeleted)
                  .toList()
                ..sort(
                  (a, b) => (b.startTime ?? DateTime(0)).compareTo(
                    a.startTime ?? DateTime(0),
                  ),
                ),
        );
  }

  static List<CallRecord> _mapCallDocs(
    Iterable<QueryDocumentSnapshot> docs, {
    bool includeDeleted = false,
  }) {
    final calls = <CallRecord>[];
    for (final doc in docs) {
      try {
        final data = doc.data();
        if (data is! Map) continue;
        calls.add(CallRecord.fromMap(Map<String, dynamic>.from(data), doc.id));
      } catch (error) {
        debugPrint('Call ${doc.id}: $error');
      }
    }
    final visible = [
      for (final call in calls)
        if (includeDeleted || !call.isDeleted) call,
    ];
    visible.sort(
      (a, b) =>
          (b.startTime ?? DateTime(0)).compareTo(a.startTime ?? DateTime(0)),
    );
    return visible;
  }

  static Stream<List<CallRecord>> getAllCalls() => streamAll();

  static Stream<List<CallRecord>> streamAll() {
    return _callsRef.snapshots().map((snapshot) => _mapCallDocs(snapshot.docs));
  }

  static Stream<List<CallRecord>> streamTrashed() {
    return _callsRef.snapshots().map(
      (snapshot) =>
          _mapCallDocs(
            snapshot.docs,
            includeDeleted: true,
          ).where((call) => call.isDeleted).toList()..sort(
            (a, b) => (b.deletedAt ?? b.startTime ?? DateTime(0)).compareTo(
              a.deletedAt ?? a.startTime ?? DateTime(0),
            ),
          ),
    );
  }

  static Future<void> delete(String id) async {
    if (id.trim().isEmpty) return;
    AppCommands.reactAngry();
    final snap = await _callsRef.doc(id).get();
    final data = snap.data() as Map<String, dynamic>?;
    await _callsRef.doc(id).set({
      'deletedAt': FieldValue.serverTimestamp(),
      'jobCreateBlocked': true,
      'reviewed': true,
      'aiSkip': true,
      'aiStatus': 'skipped',
    }, SetOptions(merge: true));
    final jobId = ((data?['createdJobId'] ?? data?['jobId']) ?? '')
        .toString()
        .trim();
    if (jobId.isEmpty) return;
    try {
      final jobSnap = await FirestoreService.jobsRef.doc(jobId).get();
      final job = jobSnap.data() as Map<String, dynamic>?;
      if (job == null || job['deletedAt'] != null) return;
      if (job['needsReview'] == true) {
        await FirestoreService.jobsRef.doc(jobId).set({
          'deletedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } catch (_) {}
  }

  static Future<void> restore(String id) async {
    if (id.trim().isEmpty) return;
    await _callsRef.doc(id).set({
      'deletedAt': FieldValue.delete(),
    }, SetOptions(merge: true));
  }

  static Future<void> deleteForever(String id) async {
    if (id.trim().isEmpty) return;
    await _callsRef.doc(id).delete();
  }

  static Future<void> deleteMany(Iterable<String> ids) async {
    for (final id in ids) {
      await delete(id);
    }
  }

  static Future<void> purgeExpiredTrash() async {
    final cutoff = DateTime.now().subtract(
      const Duration(days: CallRecord.trashKeepDays),
    );
    final snapshot = await _callsRef.limit(400).get();
    for (final doc in snapshot.docs) {
      try {
        final call = CallRecord.fromMap(
          doc.data() as Map<String, dynamic>,
          doc.id,
        );
        if (call.deletedAt != null && call.deletedAt!.isBefore(cutoff)) {
          await deleteForever(call.id);
        }
      } catch (_) {}
    }
  }

  static Stream<List<CallRecord>> streamForClient({
    required String clientId,
    List<String> phones = const [],
  }) {
    final keys = {
      for (final phone in phones)
        if (_digits(phone).length >= 10) _digits(phone),
    };
    return streamAll().map((calls) {
      final matched = [
        for (final call in calls)
          if ((call.clientId ?? '') == clientId ||
              keys.contains(_digits(call.fromNumber)) ||
              keys.contains(_digits(call.toNumber)))
            call,
      ];
      matched.sort(
        (a, b) =>
            (b.startTime ?? DateTime(0)).compareTo(a.startTime ?? DateTime(0)),
      );
      return matched;
    });
  }

  /// Звонки одного клиента — запросами по карточке и по его номерам, без
  /// выгрузки всех звонков мастерской.
  static Stream<List<CallRecord>> streamForContact({
    required String clientId,
    Iterable<String> phones = const [],
  }) {
    final numbers = {
      for (final phone in phones) CallRouting.normalizePhone(phone),
    }.where((phone) => phone.isNotEmpty).take(30).toList();
    final queries = <Query>[
      if (clientId.trim().isNotEmpty)
        _callsRef.where('clientId', isEqualTo: clientId.trim()),
      if (numbers.isNotEmpty) ...[
        _callsRef.where('fromNumber', whereIn: numbers),
        _callsRef.where('toNumber', whereIn: numbers),
      ],
    ];
    if (queries.isEmpty) return Stream.value(const <CallRecord>[]);
    return Stream<List<CallRecord>>.multi((controller) {
      final parts = List<List<QueryDocumentSnapshot>?>.filled(
        queries.length,
        null,
      );
      final subs = [
        for (var i = 0; i < queries.length; i++)
          queries[i].snapshots().listen((snap) {
            parts[i] = snap.docs;
            if (parts.contains(null)) return;
            controller.add(
              _mapCallDocs({
                for (final docs in parts)
                  for (final doc in docs!) doc.id: doc,
              }.values),
            );
          }, onError: controller.addError),
      ];
      controller.onCancel = () async {
        for (final sub in subs) {
          await sub.cancel();
        }
      };
    });
  }

  static Stream<CallRecord?> watchCall(String callId) {
    if (callId.trim().isEmpty) return Stream.value(null);
    return _callsRef.doc(callId).snapshots().map((snapshot) {
      final data = snapshot.data();
      if (data == null) return null;
      return CallRecord.fromMap(data as Map<String, dynamic>, snapshot.id);
    });
  }

  static Future<CallRecord?> getById(String callId) async {
    if (callId.trim().isEmpty) return null;
    final snap = await _callsRef.doc(callId).get();
    final data = snap.data();
    if (!snap.exists || data == null) return null;
    return CallRecord.fromMap(data as Map<String, dynamic>, snap.id);
  }

  /// Первый из переданных id, под которым звонок действительно лежит в
  /// базе. В уведомлении приходят и SID Twilio, и id документа: обычно это
  /// одно и то же, но у дочернего звонка SID свой, и разбор по нему
  /// открылся бы пустым. Если ничего не нашлось — отдаём первый непустой,
  /// чтобы экран показал честное «звонок не найден», а не промолчал.
  static Future<String> firstExistingCallId(Iterable<String> ids) async {
    final want = <String>[];
    for (final raw in ids) {
      final id = raw.trim();
      if (id.isNotEmpty && !want.contains(id)) want.add(id);
    }
    for (final id in want) {
      try {
        if ((await _callsRef.doc(id).get()).exists) return id;
      } catch (e) {
        debugPrint('TwilioService: firstExistingCallId: $e');
        return id;
      }
    }
    return want.isEmpty ? '' : want.first;
  }

  static Future<List<CallRecord>> recentCalls({int limit = 20}) async {
    final snap = await _callsRef
        .orderBy('startTime', descending: true)
        .limit(limit)
        .get();
    return _mapCallDocs(snap.docs);
  }

  static Future<void> attachJob({
    required String callId,
    required String jobId,
    String clientId = '',
  }) async {
    if (callId.trim().isEmpty || jobId.trim().isEmpty) return;
    await _callsRef.doc(callId).set({
      'createdJobId': jobId,
      'jobId': jobId,
      if (clientId.isNotEmpty) 'clientId': clientId,
      'reviewed': false,
    }, SetOptions(merge: true));
  }

  static Future<void> blockJobCreate(String callId) async {
    if (callId.trim().isEmpty) return;
    await _callsRef.doc(callId).set({
      'jobCreateBlocked': true,
      'reviewed': true,
    }, SetOptions(merge: true));
  }

  static Future<void> blockJobCreateForJob(
    String jobId, {
    String? sourceCallId,
  }) async {
    if (sourceCallId != null && sourceCallId.trim().isNotEmpty) {
      await blockJobCreate(sourceCallId);
    }
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
      await blockJobCreate(id);
    }
  }

  /// Звонок просмотрен. Снимаем и пометку «новое» в приложении, и карточку
  /// в шторке телефона: FIX уже увидел, что ему звонили, и видеть это ещё
  /// раз в списке уведомлений незачем.
  static Future<void> markReviewed(String callId, {CallRecord? call}) async {
    if (callId.trim().isEmpty) return;
    await _callsRef.doc(callId).set({
      'reviewed': true,
    }, SetOptions(merge: true));
    await dismissCallShade(callId, call: call);
  }

  static Future<void> dismissCallShade(
    String callId, {
    CallRecord? call,
  }) async {
    try {
      final record = call ?? await getById(callId);
      final phone = record == null
          ? ''
          : (record.isIncoming ? record.fromNumber : record.toNumber);
      await NotificationService.dismissCall(
        callId: callId,
        callSid: record?.callSid ?? '',
        phone: phone,
        jobId: record?.createdJobId ?? '',
      );
    } catch (e) {
      debugPrint('TwilioService: dismissCallShade: $e');
    }
  }

  static Future<String> latestInboxCallId({String from = ''}) async {
    final phone = _digits(from);
    final snap = await _callsRef
        .orderBy('startTime', descending: true)
        .limit(20)
        .get();
    for (final doc in snap.docs) {
      final call = CallRecord.fromMap(
        doc.data() as Map<String, dynamic>,
        doc.id,
      );
      if (call.reviewed) continue;
      if (phone.length >= 10) {
        final match =
            _digits(call.fromNumber) == phone ||
            _digits(call.toNumber) == phone;
        if (!match) continue;
      }
      return call.id;
    }
    return '';
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
    for (final doc in snap.docs) {
      await dismissCallShade(
        doc.id,
        call: CallRecord.fromMap(doc.data() as Map<String, dynamic>, doc.id),
      );
    }
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
      await dismissCallShade(id);
    }
  }

  static bool _stuckRetryInFlight = false;

  /// Повторить ИИ-обработку записи (например, если она упала с ошибкой).
  static Future<void> retryAiProcessing(String callId) async {
    final existing = await getById(callId);
    if (existing != null && existing.aiBlocked) {
      throw Exception('ИИ для этого звонка отключён');
    }
    await _callsRef.doc(callId).set({
      'aiStatus': 'processing',
      'aiStartedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    try {
      final response = await http
          .post(
            Uri.parse('$kFirebaseFunctionsUrl/processCallRecording'),
            headers: await AuthService.headers(),
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
      final snapshot = await _callsRef
          .where('aiStatus', isEqualTo: 'error')
          .limit(15)
          .get();
      var started = 0;
      for (final doc in snapshot.docs) {
        if (started >= 3) break;
        final data = doc.data() as Map<String, dynamic>;
        if (data['deletedAt'] != null ||
            data['jobCreateBlocked'] == true ||
            data['aiSkip'] == true) {
          continue;
        }
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
      debugPrint(
        'TwilioService: ошибка открытия настроек аккаунта вызовов: $e',
      );
    }
  }

  static void dispose() {
    _activeCallController.close();
    _callStatusController.close();
    _callEventController.close();
  }
}
