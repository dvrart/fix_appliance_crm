import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import '../../../core/constants.dart';
import '../../../models/client.dart';
import '../../../models/job.dart';
import '../../../models/location.dart';
import '../../../services/services.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../shared/stale_routes.dart';
import '../../../shared/widgets/call_transcript_chat.dart';

/// Контроллер состояния для JobDetailsScreen
/// Вынесен отдельно, чтобы вкладки могли обращаться к общему состоянию
class JobDetailsController extends ChangeNotifier {
  final String jobId;
  final String clientId;
  final Map<String, dynamic> jobData;

  late Map<String, dynamic> _lastRemote;
  final Map<String, dynamic> _draft = {};
  bool _visitsDirty = false;
  bool _attachmentsDirty = false;
  ({String street, String city, String postal, String unit})?
  _pendingClientAddress;
  bool _committing = false;
  bool _seenAlive = false;

  bool get hasUnsavedChanges =>
      _draft.isNotEmpty ||
      _visitsDirty ||
      _attachmentsDirty ||
      _pendingClientAddress != null ||
      financeMode == 'builder';
  bool get hasSavableChanges =>
      _draft.isNotEmpty ||
      _visitsDirty ||
      _attachmentsDirty ||
      _pendingClientAddress != null ||
      (financeMode == 'builder' && builderItems.isNotEmpty);
  bool get isCommitting => _committing;

  Future<bool> Function()? saveFinanceBuilder;
  VoidCallback? discardFinanceBuilder;
  VoidCallback? onInvoiceFullyPaid;

  JobDetailsController({
    required this.jobId,
    required this.clientId,
    required this.jobData,
  }) {
    _lastRemote = Map<String, dynamic>.from(jobData);
    _initFromJobData();
    _listenJobDocuments();
    _listenRelatedCalls();
    _listenClientCalls();
    _loadTaxDefault();
    _calculateTravelTime();
    _listenClient();
    _syncClientNameFromJob();
  }

  void _syncClientNameFromJob() {
    final id = clientId.trim();
    if (id.isEmpty) return;
    String spoken = '';
    for (final raw in [
      jobData['clientName'],
      jobData['jobSiteName'],
      jobSiteName,
    ]) {
      final value = (raw ?? '').toString().trim();
      if (value.isNotEmpty && !Client.isPlaceholderName(value)) {
        spoken = value;
        break;
      }
    }
    if (spoken.isEmpty) return;
    unawaited(() async {
      final client = await ClientService.getById(id);
      if (client == null) return;
      if (!Client.isPlaceholderName(client.fullName)) return;
      await ClientService.update(id, {'fullName': spoken, 'name': spoken});
    }());
  }

  late bool needsReview;

  // Состояние
  late String currentStatus;
  late String currentDescription;
  late String currentSolution;
  late bool hasJobSite;
  late String jobSiteName;
  late String jobSitePhone;
  late String jobSiteAddress;
  late String jobSiteEmail;

  String financeMode = 'main'; // 'main', 'builder', 'view_document'
  String builderDocType = 'Invoice';
  List<Map<String, dynamic>> documents = [];
  List<Map<String, dynamic>> builderItems = [];
  double builderTaxRate = TaxRates.hst;
  int? viewingDocumentIndex;
  StreamSubscription<DocumentSnapshot>? _jobSubscription;
  StreamSubscription<DocumentSnapshot>? _clientSub;
  StreamSubscription<QuerySnapshot>? _callsCreatedSub;
  StreamSubscription<QuerySnapshot>? _callsJobSub;
  final List<StreamSubscription<QuerySnapshot>> _clientCallSubs = [];
  final Map<String, Map<String, dynamic>> _relatedCalls = {};
  final Map<String, Map<String, dynamic>> _clientCalls = {};
  String _clientCallsKey = '';
  List<Location> _clientLocations = const [];
  List<Job> _clientJobs = const [];
  Future<void>? _loadingClientContacts;
  bool _disposed = false;
  bool _financeTabRequested = false;

  bool get financeTabRequested => _financeTabRequested;

  bool pendingSuggestComplete = false;
  bool pendingSuggestCancel = false;

  List<Map<String, dynamic>> attachments = [];
  bool isUploadingImage = false;

  String travelTime = '';
  bool isLoadingTime = true;

  String activeChatRole = 'client';
  String chatSendMethod = 'SMS';
  String clientEmail = '';

  DateTime? scheduledAt;
  int durationMinutes = kDefaultVisitMinutes;
  String packingNotes = '';
  String trackingNumber = '';
  String amazonOrderId = '';
  String trackingCarrier = '';
  String trackingPart = '';
  String trackingStatus = '';
  List<JobVisit> visits = [];

  DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is Timestamp) return value.toDate();
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  List<JobVisit> _parseVisits(Map<String, dynamic> data) {
    final raw = data['visits'];
    final parsed = <JobVisit>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          parsed.add(JobVisit.fromMap(Map<String, dynamic>.from(item)));
        }
      }
    }
    return JobVisit.coalesce(
      parsed,
      scheduledAt:
          _parseDate(data['scheduledAt']) ?? _parseDate(data['scheduledDate']),
      durationMinutes:
          (data['durationMinutes'] as num?)?.toInt() ?? durationMinutes,
    );
  }

  void _applyVisitFields(List<JobVisit> next) {
    visits = [...next]..sort((a, b) => a.startAt.compareTo(b.startAt));
    final synced = JobVisit.syncFields(
      visits,
      defaultDuration: durationMinutes,
    );
    scheduledAt = synced['scheduledAt'] as DateTime?;
    durationMinutes = (synced['durationMinutes'] as int?) ?? durationMinutes;
  }

  void _initFromJobData() {
    currentStatus = jobData['status'] ?? 'Новая';
    currentDescription = jobData['description'] ?? 'Нет описания';
    currentSolution = (jobData['solution'] ?? '').toString();

    scheduledAt =
        _parseDate(jobData['scheduledAt']) ??
        _parseDate(jobData['scheduledDate']);
    durationMinutes =
        (jobData['durationMinutes'] as num?)?.toInt() ?? kDefaultVisitMinutes;
    packingNotes = jobData['packingNotes'] ?? '';
    trackingNumber = (jobData['trackingNumber'] ?? '').toString();
    amazonOrderId = (jobData['amazonOrderId'] ?? '').toString();
    trackingCarrier = (jobData['trackingCarrier'] ?? '').toString();
    trackingPart = (jobData['trackingPart'] ?? '').toString();
    trackingStatus = (jobData['trackingStatus'] ?? '').toString();
    visits = _parseVisits(jobData);
    _applyVisitFields(visits);

    final phone = (jobData['clientPhone'] ?? '').toString().trim();
    jobData['clientName'] = Client.stripClientWord(
      (jobData['clientName'] ?? jobData['name'] ?? '').toString(),
      phone,
    );
    hasJobSite = jobData['hasJobSite'] == true;
    jobSitePhone = (jobData['jobSitePhone'] ?? '').toString();
    jobSiteName = Client.stripClientWord(
      (jobData['jobSiteName'] ?? '').toString(),
      jobSitePhone.trim().isNotEmpty ? jobSitePhone : phone,
    );
    jobSiteAddress = jobData['jobSiteAddress'] ?? '';
    jobSiteEmail = (jobData['jobSiteEmail'] ?? '').toString();
    clientEmail = (jobData['clientEmail'] ?? '').toString().trim();

    if (jobData['documents'] != null) {
      documents = List<Map<String, dynamic>>.from(jobData['documents']);
      unawaited(_autoConvertApprovedEstimates());
    }

    if (jobData['attachments'] != null) {
      attachments = List<Map<String, dynamic>>.from(jobData['attachments']);
    }
    needsReview = jobData['needsReview'] == true;
  }

  void _listenJobDocuments() {
    _jobSubscription = FirestoreService.jobsRef.doc(jobId).snapshots().listen((
      snap,
    ) {
      final data = snap.exists ? snap.data() as Map<String, dynamic>? : null;
      if (data == null) {
        // Удалена навсегда. Пустой ответ из кэша без сети ещё ничего не значит.
        if (_seenAlive || !snap.metadata.isFromCache) {
          StaleRoutes.dropJob(jobId);
        }
        return;
      }
      // Карточку из корзины открывают намеренно — закрываем только при
      // переходе «живая → в корзине».
      if (!StaleRoutes.isTrashed(data, snap.metadata)) {
        _seenAlive = true;
      } else if (_seenAlive) {
        StaleRoutes.dropJob(jobId);
        return;
      }
      // Пока есть черновик — не затираем снимок remote визитами/полями с сервера
      // вслепую: _lastRemote нужен для discard. Обновляем remote только без правок
      // или мержим без visits, если visits грязные.
      if (!hasUnsavedChanges) {
        _lastRemote = {..._lastRemote, ...data};
      } else if (!_visitsDirty) {
        final merged = {..._lastRemote, ...data};
        if (_lastRemote['visits'] != null) {
          merged['visits'] = _lastRemote['visits'];
        }
        if (_lastRemote['scheduledAt'] != null) {
          merged['scheduledAt'] = _lastRemote['scheduledAt'];
        }
        _lastRemote = merged;
      }

      if (data.containsKey('clientPhone')) {
        jobData['clientPhone'] = data['clientPhone'];
      }
      if (data.containsKey('clientName') || data.containsKey('name')) {
        jobData['clientName'] = Client.stripClientWord(
          (data['clientName'] ?? data['name'] ?? jobData['clientName'])
              ?.toString(),
          (jobData['clientPhone'] ?? '').toString(),
        );
      }
      if (data.containsKey('clientIsRegular') || data.containsKey('isRegular')) {
        jobData['clientIsRegular'] =
            data['clientIsRegular'] == true || data['isRegular'] == true;
      }
      // Метки дубляжа ставит сервер — показываем их даже поверх черновика.
      for (final key in [
        'mergedIntoJobId',
        'mergedFromJobIds',
        'possibleDuplicateOfJobId',
        'duplicateDismissed',
      ]) {
        if (data.containsKey(key)) jobData[key] = data[key];
      }

      if (data['documents'] != null) {
        final nextDocs = List<Map<String, dynamic>>.from(
          (data['documents'] as List).map(
            (e) => Map<String, dynamic>.from(e as Map),
          ),
        );
        _onDocumentsRemoteUpdate(
          nextDocs,
          remoteStatus: (data['status'] ?? '').toString(),
        );
      }
      if (data['attachments'] != null && !_attachmentsDirty) {
        attachments = List<Map<String, dynamic>>.from(data['attachments']);
      }
      trackingStatus = (data['trackingStatus'] ?? trackingStatus).toString();
      needsReview = data['needsReview'] == true;

      if (!hasUnsavedChanges) {
        currentStatus = data['status'] ?? currentStatus;
        durationMinutes =
            (data['durationMinutes'] as num?)?.toInt() ?? durationMinutes;
        packingNotes = data['packingNotes'] ?? packingNotes;
        trackingNumber = (data['trackingNumber'] ?? trackingNumber).toString();
        amazonOrderId = (data['amazonOrderId'] ?? amazonOrderId).toString();
        trackingCarrier =
            (data['trackingCarrier'] ?? trackingCarrier).toString();
        trackingPart = (data['trackingPart'] ?? trackingPart).toString();
        visits = _parseVisits(data);
        _applyVisitFields(visits);
        hasJobSite = data['hasJobSite'] == true;
        if (data.containsKey('jobSitePhone')) {
          jobSitePhone = (data['jobSitePhone'] ?? '').toString();
        }
        if (data.containsKey('jobSiteName')) {
          final fallbackPhone = jobSitePhone.trim().isNotEmpty
              ? jobSitePhone
              : (jobData['clientPhone'] ?? '').toString();
          jobSiteName = Client.stripClientWord(
            (data['jobSiteName'] ?? '').toString(),
            fallbackPhone,
          );
        }
        if (data.containsKey('jobSiteAddress')) {
          jobSiteAddress = (data['jobSiteAddress'] ?? '').toString();
        }
        if (data.containsKey('jobSiteEmail')) {
          jobSiteEmail = (data['jobSiteEmail'] ?? '').toString();
        }
        if (data.containsKey('clientEmail') &&
            (data['clientEmail'] ?? '').toString().trim().isNotEmpty) {
          clientEmail = (data['clientEmail'] ?? '').toString().trim();
        }
        if (data.containsKey('clientAddress')) {
          jobData['clientAddress'] = data['clientAddress'];
        }
        if (data.containsKey('clientPhone')) {
          jobData['clientPhone'] = data['clientPhone'];
          _listenClientCalls();
        }
        if (data.containsKey('clientName') || data.containsKey('name')) {
          jobData['clientName'] = Client.stripClientWord(
            (data['clientName'] ?? data['name'] ?? jobData['clientName'])
                ?.toString(),
            (jobData['clientPhone'] ?? '').toString(),
          );
        }
        if (data.containsKey('description')) {
          currentDescription = (data['description'] ?? currentDescription)
              .toString();
        }
        if (data.containsKey('solution')) {
          currentSolution = (data['solution'] ?? currentSolution).toString();
        }
        if (data.containsKey('applianceType')) {
          jobData['applianceType'] = data['applianceType'];
        }
        if (data.containsKey('appliances')) {
          jobData['appliances'] = data['appliances'];
        }
        for (final key in [
          'source',
          'sourceCallId',
          'sourceEmailId',
          'sourceEmailFrom',
          'sourceEmailSubject',
          'sourceEmailPreview',
        ]) {
          if (data.containsKey(key)) jobData[key] = data[key];
        }
        jobData['hasJobSite'] = hasJobSite;
        jobData['jobSiteAddress'] = jobSiteAddress;
      }
      if (data['suggestComplete'] == true &&
          !JobStatuses.isCompletedStatus(currentStatus)) {
        pendingSuggestComplete = true;
      }
      if (data['suggestCancel'] == true &&
          !JobStatuses.isCancelledStatus(currentStatus)) {
        pendingSuggestCancel = true;
      }
      if (!_disposed) notifyListeners();
    });
  }

  Future<void> _loadTaxDefault() async {
    final config = await SettingsService.loadConfig();
    builderTaxRate = SettingsService.readDefaultTaxRate(config);
    notifyListeners();
  }

  List<Map<String, dynamic>> get callItems {
    final fromJob = [
      for (final item in attachments)
        if ((item['kind'] ?? '').toString() == 'call')
          Map<String, dynamic>.from(item),
    ];
    final merged = <String, Map<String, dynamic>>{};
    for (final item in fromJob) {
      final key = (item['callId'] ?? item['url'] ?? merged.length.toString())
          .toString();
      merged[key] = item;
    }
    for (final entry in _relatedCalls.entries) {
      final existing = merged[entry.key];
      if (existing == null) {
        merged[entry.key] = entry.value;
        continue;
      }
      merged[entry.key] = {
        ...existing,
        if ((existing['url'] ?? '').toString().isEmpty)
          'url': entry.value['url'],
        if ((existing['storageUrl'] ?? '').toString().isEmpty)
          'storageUrl': entry.value['storageUrl'],
        'history': existing['history'] ?? entry.value['history'],
        'transcription': _preferCallTranscript(
          existing['transcription']?.toString() ?? '',
          entry.value['transcription']?.toString() ?? '',
        ),
        'transcriptionRu': _preferCallTranscript(
          existing['transcriptionRu']?.toString() ?? '',
          entry.value['transcriptionRu']?.toString() ?? '',
        ),
        'transcriptionEn': keepFullerTranscript(
          existing['transcriptionEn']?.toString() ?? '',
          entry.value['transcriptionEn']?.toString() ?? '',
          preferRussian: false,
        ),
        if ((existing['summary'] ?? '').toString().trim().isEmpty)
          'summary': entry.value['summary'],
        if (CallRecord.parseStamp(existing['startTime']) == null)
          'startTime': entry.value['startTime'],
        if ((existing['direction'] ?? '').toString().trim().isEmpty)
          'direction': entry.value['direction'],
        if ((existing['fromNumber'] ?? '').toString().trim().isEmpty)
          'fromNumber': entry.value['fromNumber'],
      };
    }
    final items = merged.values.toList();
    _sortCallsByTime(items);
    return items;
  }

  /// Разговоры с тем же клиентом, которые к заявке не привязаны.
  ///
  /// Секретарь часто говорит с человеком до того, как заявка появилась, и та
  /// беседа висит на черновике или вовсе без заявки. Без этого списка на
  /// карточке открывался только последний звонок, а разговор с ИИ было не
  /// послушать.
  List<Map<String, dynamic>> get otherClientCalls {
    final linked = {
      for (final item in callItems)
        if ((item['callId'] ?? '').toString().trim().isNotEmpty)
          (item['callId'] ?? '').toString().trim(),
    };
    final items = [
      for (final entry in _clientCalls.entries)
        if (!linked.contains(entry.key)) entry.value,
    ];
    _sortCallsByTime(items);
    return items;
  }

  static void _sortCallsByTime(List<Map<String, dynamic>> items) {
    DateTime at(Map<String, dynamic> item) =>
        CallRecord.parseStamp(item['startTime']) ??
        CallRecord.parseStamp(item['uploadedAt']) ??
        DateTime.fromMillisecondsSinceEpoch(0);
    items.sort((a, b) => at(a).compareTo(at(b)));
  }

  static String _transcriptFromCallHistory(dynamic raw) {
    if (raw is! List) return '';
    final lines = <String>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final text = (item['text'] ?? '').toString().trim();
      if (text.isEmpty) continue;
      final role = (item['role'] ?? '').toString();
      lines.add('${role == 'assistant' ? 'ИИ' : 'Клиент'}: $text');
    }
    return lines.join('\n');
  }

  static bool _hasCallSpeakers(String text) {
    final hasShop = RegExp(
      r'(^|\n)\s*(ИИ|AI|Assistant|Me|Master|Мастер|Моё|Мое|Technician|Секретарь)\s*:',
      caseSensitive: false,
    ).hasMatch(text);
    final hasClient = RegExp(
      r'(^|\n)\s*(Клиент|Client|User|Caller)\s*:',
      caseSensitive: false,
    ).hasMatch(text);
    return hasShop && hasClient;
  }

  static String _preferCallTranscript(String a, String b) {
    if (_hasCallSpeakers(b) && !_hasCallSpeakers(a)) return b;
    if (_hasCallSpeakers(a) && !_hasCallSpeakers(b)) return a;
    return keepFullerTranscript(a, b);
  }

  static Map<String, dynamic> _callAttachment(DocumentSnapshot doc) {
    final data = (doc.data() as Map<String, dynamic>?) ?? {};
    final callId = doc.id;
    final url =
        (data['playableUrl'] ??
                data['storageUrl'] ??
                data['recordingUrl'] ??
                '')
            .toString();
    final history = (data['aiReception'] is Map)
        ? (data['aiReception'] as Map)['history']
        : null;
    final extracted = (data['extractedData'] is Map)
        ? Map<String, dynamic>.from(data['extractedData'] as Map)
        : (data['aiReception'] is Map &&
                  (data['aiReception'] as Map)['extracted'] is Map)
              ? Map<String, dynamic>.from(
                  (data['aiReception'] as Map)['extracted'] as Map,
                )
              : const <String, dynamic>{};
    final fromHistory = _transcriptFromCallHistory(history);
    final stored = (data['transcription'] ?? '').toString();
    final ru = (data['transcriptionRu'] ?? '').toString();
    final en = (data['transcriptionEn'] ?? '').toString();
    final transcription = _preferCallTranscript(
      _preferCallTranscript(stored, ru),
      _preferCallTranscript(en, fromHistory),
    );
    return {
      'kind': 'call',
      'callId': callId,
      'url': url,
      'storageUrl': (data['storageUrl'] ?? '').toString(),
      'name': 'Звонок',
      'transcription': transcription,
      'transcriptionRu': (data['transcriptionRu'] ?? transcription).toString(),
      'transcriptionEn': (data['transcriptionEn'] ?? '').toString(),
      'summary': (data['summary'] ?? '').toString(),
      'history': history,
      'answeredBy': (data['answeredBy'] ?? '').toString(),
      'startTime': data['startTime'] ?? data['createdAt'],
      'direction': (data['direction'] ?? '').toString(),
      'fromNumber': (data['fromNumber'] ?? '').toString(),
      'toNumber': (data['toNumber'] ?? '').toString(),
      'contactOnSiteName':
          (extracted['contact_on_site_name'] ?? '').toString().trim(),
      'contactOnSitePhone':
          (extracted['contact_on_site_phone'] ?? '').toString().trim(),
    };
  }

  void _listenRelatedCalls() {
    void ingest(QuerySnapshot snap) {
      for (final doc in snap.docs) {
        _relatedCalls[doc.id] = _callAttachment(doc);
      }
      _listenClientCalls();
      if (!_disposed) notifyListeners();
    }

    _callsCreatedSub = FirestoreService.callsRef
        .where('createdJobId', isEqualTo: jobId)
        .snapshots()
        .listen(ingest);
    _callsJobSub = FirestoreService.callsRef
        .where('jobId', isEqualTo: jobId)
        .snapshots()
        .listen(ingest);
  }

  /// Подписка на звонки этого клиента — по его карточке и по номеру.
  ///
  /// Телефон приходит позже самой заявки, поэтому метод можно звать повторно:
  /// пока ключ не изменился, он ничего не делает.
  void _listenClientCalls() {
    final phones = <String>{
      for (final c in chatContacts)
        if (c.normalizedPhone.length >= 10) SmsService.toE164(c.phone),
    }..removeWhere((p) => p.length < 11);
    final sortedPhones = phones.toList()..sort();
    final key = '$clientId|${sortedPhones.join(',')}';
    if (key == _clientCallsKey) return;
    _clientCallsKey = key;
    for (final sub in _clientCallSubs) {
      sub.cancel();
    }
    _clientCallSubs.clear();
    _clientCalls.clear();
    final queries = <Query>[
      if (clientId.trim().isNotEmpty)
        FirestoreService.callsRef.where('clientId', isEqualTo: clientId),
      for (final phone in sortedPhones) ...[
        FirestoreService.callsRef.where('fromNumber', isEqualTo: phone),
        FirestoreService.callsRef.where('toNumber', isEqualTo: phone),
      ],
    ];
    for (final query in queries) {
      _clientCallSubs.add(
        query.snapshots().listen((snap) {
          var changed = false;
          for (final doc in snap.docs) {
            final data = (doc.data() as Map<String, dynamic>?) ?? {};
            if (data['deletedAt'] != null) continue;
            final item = _callAttachment(doc);
            // Пустые звонки (сорвался гудок) слушать нечего — только шум в списке.
            final hasAudio =
                (item['url'] ?? '').toString().trim().isNotEmpty ||
                (item['storageUrl'] ?? '').toString().trim().isNotEmpty;
            final hasText = (item['transcription'] ?? '')
                .toString()
                .trim()
                .isNotEmpty;
            if (!hasAudio && !hasText) continue;
            _clientCalls[doc.id] = item;
            changed = true;
          }
          if (changed && !_disposed) notifyListeners();
        }),
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _jobSubscription?.cancel();
    _clientSub?.cancel();
    _callsCreatedSub?.cancel();
    _callsJobSub?.cancel();
    for (final sub in _clientCallSubs) {
      sub.cancel();
    }
    _clientCallSubs.clear();
    super.dispose();
  }

  /// Адрес для навигации.
  ///
  /// Галочка «другое место работы» иногда стоит, а адрес туда не вписан —
  /// тогда едем к клиенту, иначе маршрут открывался бы в пустоту.
  String get workAddress {
    final site = jobSiteAddress.trim();
    if (hasJobSite && site.isNotEmpty) return site;
    return (jobData['clientAddress'] ?? '').toString();
  }

  /// Телефон человека на месте (из заявки, локаций карточки клиента, других
  /// заявок клиента или разбора звонка).
  String get effectiveJobSitePhone {
    final own = jobSitePhone.trim();
    final clientNorm = SmsService.normalizePhone(
      (jobData['clientPhone'] ?? '').toString(),
    );
    if (own.isNotEmpty && SmsService.normalizePhone(own) != clientNorm) {
      return own;
    }
    for (final loc in _clientLocations) {
      for (final contact in loc.contacts) {
        final norm = SmsService.normalizePhone(contact.phone);
        if (norm.length >= 10 && norm != clientNorm) {
          return contact.phone.trim();
        }
      }
    }
    for (final call in _relatedCalls.values) {
      final cp = (call['contactOnSitePhone'] ?? '').toString().trim();
      final norm = SmsService.normalizePhone(cp);
      if (norm.length >= 10 && norm != clientNorm) {
        return cp;
      }
    }
    for (final j in _clientJobs) {
      final jp = (j.jobSitePhone ?? '').trim();
      final norm = SmsService.normalizePhone(jp);
      if (norm.length >= 10 && norm != clientNorm) {
        return jp;
      }
    }
    return own;
  }

  /// Имя человека на месте (из заявки, локаций клиента, других заявок или звонка).
  String get effectiveJobSiteName {
    final own = Client.stripClientWord(jobSiteName, effectiveJobSitePhone);
    final clientNameNorm = Client.stripClientWord(
      jobData['clientName']?.toString(),
      (jobData['clientPhone'] ?? '').toString(),
    ).toLowerCase();
    if (own.isNotEmpty && own.toLowerCase() != clientNameNorm) {
      return own;
    }
    final clientPhoneNorm = SmsService.normalizePhone(
      (jobData['clientPhone'] ?? '').toString(),
    );
    for (final loc in _clientLocations) {
      for (final contact in loc.contacts) {
        final norm = SmsService.normalizePhone(contact.phone);
        final cName = Client.stripClientWord(contact.name, contact.phone);
        if (cName.isNotEmpty &&
            (norm != clientPhoneNorm || contact.role == 'tenant') &&
            cName.toLowerCase() != clientNameNorm) {
          return cName;
        }
      }
    }
    for (final call in _relatedCalls.values) {
      final cn = Client.stripClientWord(
        (call['contactOnSiteName'] ?? '').toString(),
        (call['contactOnSitePhone'] ?? '').toString(),
      );
      if (cn.isNotEmpty && cn.toLowerCase() != clientNameNorm) {
        return cn;
      }
    }
    for (final j in _clientJobs) {
      final jn = Client.stripClientWord(j.jobSiteName, j.jobSitePhone ?? '');
      if (jn.isNotEmpty && jn.toLowerCase() != clientNameNorm) {
        return jn;
      }
    }
    return own;
  }

  /// Контактное имя на месте
  String get contactName {
    final site = effectiveJobSiteName;
    if (hasJobSite && site.isNotEmpty) return site;
    final owner = Client.stripClientWord(
      jobData['clientName']?.toString(),
      contactPhone,
    );
    return owner.isNotEmpty ? owner : 'Неизвестно'.tr;
  }

  /// Контактный телефон
  String get contactPhone {
    final site = effectiveJobSitePhone;
    return hasJobSite
        ? (site.isEmpty ? (jobData['clientPhone'] ?? '').toString() : site)
        : (jobData['clientPhone'] ?? '').toString();
  }

  List<JobChatContact> get chatContacts {
    final result = <JobChatContact>[];
    final seenPhones = <String>{};
    final seenEmails = <String>{};

    void add(JobChatContact contact) {
      if (!contact.hasChannel) return;
      final normPhone = contact.normalizedPhone;
      final normEmail = contact.normalizedEmail;
      final newPhone =
          normPhone.length >= 10 && !seenPhones.contains(normPhone);
      final newEmail =
          normEmail.contains('@') && !seenEmails.contains(normEmail);
      if (!newPhone && !newEmail) return;
      if (newPhone) seenPhones.add(normPhone);
      if (newEmail) seenEmails.add(normEmail);
      result.add(
        JobChatContact(
          id: contact.id,
          label: contact.label,
          name: contact.name,
          phone: newPhone ? contact.phone.trim() : '',
          email: newEmail ? contact.email.trim() : '',
        ),
      );
    }

    final clientPhone = (jobData['clientPhone'] ?? '').toString().trim();
    add(
      JobChatContact(
        id: 'client',
        label: 'Хозяин'.tr,
        name: Client.stripClientWord(
          jobData['clientName']?.toString(),
          clientPhone,
        ),
        phone: clientPhone,
        email: clientEmail.trim(),
      ),
    );

    final sitePhone = effectiveJobSitePhone;
    final siteName = effectiveJobSiteName;
    if (hasJobSite ||
        sitePhone.isNotEmpty ||
        jobSiteEmail.trim().isNotEmpty) {
      add(
        JobChatContact(
          id: 'site',
          label: 'Арендатор'.tr,
          name: siteName.isEmpty ? 'Арендатор'.tr : siteName,
          phone: sitePhone,
          email: jobSiteEmail.trim(),
        ),
      );
    }

    for (final location in _clientLocations) {
      for (final contact in location.contacts) {
        final isFirstOwner = result.isEmpty && contact.role == 'owner';
        final label = isFirstOwner
            ? 'Хозяин'.tr
            : (contact.role == 'manager'
                ? contact.roleLabel
                : 'Арендатор'.tr);
        final cName = Client.stripClientWord(contact.name, contact.phone);
        add(
          JobChatContact(
            id: result.any((c) => c.id == 'site')
                ? 'loc-${contact.id.isEmpty ? contact.phone : contact.id}'
                : 'site',
            label: label,
            name: cName.isNotEmpty
                ? cName
                : (siteName.isNotEmpty ? siteName : label),
            phone: contact.phone,
          ),
        );
      }
    }

    for (final call in _relatedCalls.values) {
      final cp = (call['contactOnSitePhone'] ?? '').toString().trim();
      if (cp.isEmpty) continue;
      final cn = Client.stripClientWord(
        (call['contactOnSiteName'] ?? '').toString(),
        cp,
      );
      add(
        JobChatContact(
          id: result.any((c) => c.id == 'site')
              ? 'call-${call['callId'] ?? cp}'
              : 'site',
          label: 'Арендатор'.tr,
          name: cn.isNotEmpty
              ? cn
              : (siteName.isNotEmpty ? siteName : 'Арендатор'.tr),
          phone: cp,
        ),
      );
    }

    for (final j in _clientJobs) {
      if (j.id == jobId) continue;
      final jp = (j.jobSitePhone ?? '').trim();
      final je = (j.jobSiteEmail ?? '').trim();
      if (!j.hasJobSite && jp.isEmpty && je.isEmpty) continue;
      final jn = Client.stripClientWord(j.jobSiteName, jp);
      add(
        JobChatContact(
          id: result.any((c) => c.id == 'site') ? 'job-${j.id}' : 'site',
          label: 'Арендатор'.tr,
          name: jn.isEmpty ? 'Арендатор'.tr : jn,
          phone: jp,
          email: je,
        ),
      );
    }

    return result;
  }

  /// Догружает карточку клиента и все его заявки, если мастер нажал кнопку
  /// звонка/SMS быстрее, чем пришёл первый снимок.
  Future<void> ensureChatContactsLoaded() async {
    final pending = _loadingClientContacts;
    if (pending != null) {
      await pending;
      return;
    }
    if (clientId.trim().isEmpty) return;
    final future = () async {
      try {
        if (_clientLocations.isEmpty) {
          final client = await ClientService.getById(clientId);
          if (client != null && !_disposed) {
            _clientLocations = client.locations;
            if (client.email != null &&
                client.email!.trim().isNotEmpty &&
                clientEmail.isEmpty) {
              clientEmail = client.email!.trim();
            }
          }
        }
        if (_clientJobs.isEmpty) {
          await _loadClientJobs();
        }
      } catch (_) {}
    }();
    _loadingClientContacts = future;
    try {
      await future;
    } finally {
      _loadingClientContacts = null;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _loadClientJobs() async {
    if (clientId.trim().isEmpty) return;
    try {
      final snap = await FirestoreService.jobsRef
          .where('clientId', isEqualTo: clientId)
          .get();
      if (_disposed) return;
      final loaded = <Job>[];
      for (final doc in snap.docs) {
        final parsed = Job.fromMap(
          doc.data() as Map<String, dynamic>,
          doc.id,
        );
        if (!parsed.isDeleted) loaded.add(parsed);
      }
      _clientJobs = loaded;
      _listenClientCalls();
      if (!_disposed) notifyListeners();
    } catch (_) {}
  }

  JobChatContact? get selectedChatContact {
    final contacts = chatContacts;
    if (contacts.isEmpty) return null;
    for (final contact in contacts) {
      if (contact.id == activeChatRole) return contact;
    }
    return contacts.first;
  }

  Future<void> _calculateTravelTime() async {
    final time = await MapsService.getTravelTime(workAddress);
    if (_disposed) return;
    travelTime = time ?? 'GO';
    isLoadingTime = false;
    notifyListeners();
  }

  void _listenClient() {
    if (clientId.isEmpty) return;
    unawaited(_loadClientJobs());
    _clientSub = FirestoreService.clientsRef.doc(clientId).snapshots().listen((
      snap,
    ) {
      if (_disposed || !snap.exists) return;
      final data = snap.data() as Map<String, dynamic>?;
      if (data == null) return;
      final parsedClient = Client.fromMap(data, clientId);
      final prevContactsCount = chatContacts.length;
      _clientLocations = parsedClient.locations;
      final phone = (data['phone'] ?? '').toString().trim();
      final name = Client.stripClientWord(
        (data['fullName'] ?? data['name'] ?? '').toString(),
        phone,
      );
      final address = (data['address'] ?? '').toString().trim();
      final email = (data['email'] ?? '').toString().trim();
      final isRegular = data['isRegular'] == true;
      ClientService.noteClientMap(clientId, data);
      var changed = chatContacts.length != prevContactsCount;
      if ((jobData['clientIsRegular'] == true) != isRegular) {
        jobData['clientIsRegular'] = isRegular;
        changed = true;
      }
      if (name.isNotEmpty && !_draft.containsKey('clientName')) {
        if (jobData['clientName'] != name) {
          jobData['clientName'] = name;
          changed = true;
        }
      }
      if (!_draft.containsKey('clientPhone') &&
          jobData['clientPhone'] != phone) {
        jobData['clientPhone'] = phone;
        changed = true;
      }
      if (address.isNotEmpty &&
          !_draft.containsKey('clientAddress') &&
          jobData['clientAddress'] != address) {
        jobData['clientAddress'] = address;
        changed = true;
      }
      if (email != clientEmail) {
        clientEmail = email;
        changed = true;
      }
      _listenClientCalls();
      if (changed && !_disposed) notifyListeners();
    });
  }

  // === Методы обновления ===

  void _queue(Map<String, dynamic> data) {
    _draft.addAll(data);
    notifyListeners();
  }

  void abandonUnsaved() {
    _draft.clear();
    _visitsDirty = false;
    _attachmentsDirty = false;
    _pendingClientAddress = null;
  }

  void discardChanges() {
    discardFinanceBuilder?.call();
    abandonUnsaved();
    for (final entry in _lastRemote.entries) {
      jobData[entry.key] = entry.value;
    }
    _initFromJobData();
    notifyListeners();
  }

  Future<bool> commitChanges() async {
    if (!hasUnsavedChanges || _committing) return true;
    _committing = true;
    notifyListeners();
    try {
      if (financeMode == 'builder') {
        final ok = await saveFinanceBuilder?.call() ?? false;
        if (!ok) return false;
      }
      if (_draft.isEmpty &&
          !_visitsDirty &&
          !_attachmentsDirty &&
          _pendingClientAddress == null) {
        return true;
      }
      final data = Map<String, dynamic>.from(_draft);
      if (_visitsDirty) {
        data.addAll(
          JobVisit.syncFields(visits, defaultDuration: durationMinutes),
        );
      }
      if (_attachmentsDirty) {
        isUploadingImage = true;
        notifyListeners();
        try {
          attachments = await _uploadPendingAttachments();
          data['attachments'] = attachments;
        } finally {
          isUploadingImage = false;
        }
      }
      if (data.isNotEmpty) {
        await JobService.update(jobId, data);
        data.forEach((key, value) {
          if (value is FieldValue) return;
          jobData[key] = value;
          _lastRemote[key] = value;
        });
      }
      final pendingAddr = _pendingClientAddress;
      if (pendingAddr != null && clientId.isNotEmpty) {
        await ClientService.updateAddress(
          clientId,
          street: pendingAddr.street,
          city: pendingAddr.city,
          postal: pendingAddr.postal,
          unit: pendingAddr.unit,
        );
      }
      abandonUnsaved();
      return true;
    } catch (_) {
      return false;
    } finally {
      _committing = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> markReviewed() async {
    needsReview = false;
    notifyListeners();
    await JobService.markReviewed(jobId);
    await TwilioService.markJobCallsReviewed(jobId);
  }

  Future<void> rejectUnconfirmed() async {
    await JobService.delete(jobId);
  }

  Future<void> updateStatus(
    String status, {
    Map<String, dynamic>? extra,
    bool persistNow = false,
  }) async {
    currentStatus = status;
    if (status == JobStatuses.waitingPart) {
      _applyVisitFields(JobVisit.markLatestScheduledDone(visits));
      _visitsDirty = true;
    } else if (JobStatuses.isCompletedStatus(status)) {
      _applyVisitFields(JobVisit.markAllScheduledDone(visits));
      _visitsDirty = true;
      needsReview = false;
    } else if (JobStatuses.isCancelledStatus(status)) {
      _applyVisitFields(JobVisit.markAllScheduledCancelled(visits));
      _visitsDirty = true;
      needsReview = false;
    }
    _queue({
      'status': status,
      if (JobStatuses.isCompletedStatus(status)) ...{
        'completedAt': FieldValue.serverTimestamp(),
        'needsReview': false,
      },
      if (JobStatuses.isCancelledStatus(status)) 'needsReview': false,
      if (extra != null) ...extra,
    });
    if (persistNow) await commitChanges();
  }

  Future<void> updateDescription(String description) async {
    currentDescription = description;
    _queue({'description': description});
  }

  Future<void> updateProblemAndSolution({
    required String problem,
    required String solution,
  }) async {
    currentDescription = problem.isEmpty ? 'Нет описания' : problem;
    currentSolution = solution;
    _queue({'description': problem, 'solution': solution});
  }

  /// Изменить дату/время ближайшего визита (или снять все визиты, если [newValue] == null)
  Future<void> updateScheduledAt(DateTime? newValue) async {
    if (newValue == null) {
      await saveVisits(const []);
      return;
    }
    if (visits.isEmpty) {
      final fromParts = currentStatus == JobStatuses.waitingPart;
      await saveVisits([
        JobVisit.create(startAt: newValue, durationMinutes: durationMinutes),
      ], markInstall: fromParts);
      return;
    }
    final now = DateTime.now();
    final planned = visits.where((v) => v.isScheduled).toList();
    final JobVisit target;
    if (planned.isEmpty) {
      target = visits.last;
    } else {
      final upcoming = planned.where((v) => !v.startAt.isBefore(now)).toList();
      target = upcoming.isNotEmpty ? upcoming.first : planned.last;
    }
    await updateVisit(target.copyWith(startAt: newValue));
  }

  Future<void> saveVisits(
    List<JobVisit> next, {
    bool markRescheduled = false,
    bool markInstall = false,
  }) async {
    _applyVisitFields(next);
    _visitsDirty = true;
    if (markInstall && currentStatus == JobStatuses.waitingPart) {
      currentStatus = JobStatuses.install;
      _queue({'status': JobStatuses.install});
    } else if (JobStatuses.shouldWriteRescheduled(
      currentStatus,
      mark: markRescheduled,
    )) {
      currentStatus = JobStatuses.rescheduled;
      _queue({'status': JobStatuses.rescheduled});
    }
    notifyListeners();
  }

  Future<void> addVisit(JobVisit visit) {
    final fromParts = currentStatus == JobStatuses.waitingPart;
    final mark = JobStatuses.shouldMarkRescheduledOnNewVisit(
      currentStatus: currentStatus,
      alreadyHasVisits: visits.isNotEmpty,
    );
    return saveVisits(
      [...visits, visit],
      markRescheduled: mark,
      markInstall: fromParts,
    );
  }

  /// [correction] — исправление даты/времени этого же визита: статус не
  /// меняется на «Перенос» / «Установка».
  Future<void> updateVisit(JobVisit visit, {bool correction = false}) {
    if (correction) {
      return saveVisits([
        for (final item in visits) item.id == visit.id ? visit : item,
      ]);
    }
    JobVisit? previous;
    for (final item in visits) {
      if (item.id == visit.id) {
        previous = item;
        break;
      }
    }
    final dayChanged =
        previous != null &&
        !JobVisit.isSameDay(previous.startAt, visit.startAt);
    final fromParts = dayChanged && currentStatus == JobStatuses.waitingPart;
    return saveVisits(
      [for (final item in visits) item.id == visit.id ? visit : item],
      markRescheduled: dayChanged && !fromParts,
      markInstall: fromParts,
    );
  }

  Future<void> removeVisit(String visitId) {
    return saveVisits(visits.where((v) => v.id != visitId).toList());
  }

  Future<void> updateVisitConfirm(JobVisit visit, String status) async {
    final nextStatus = status.trim().isEmpty
        ? JobVisit.confirmPending
        : status.trim();
    final current = visit.effectiveConfirmStatus;
    final alreadyPending =
        current.isEmpty || current == JobVisit.confirmPending;
    if (nextStatus == JobVisit.confirmPending && alreadyPending) {
      // «Нет» при уже неподтверждённом визите — ничего не пишем в Firestore,
      // иначе уйдут все черновые правки (новая дата и т.п.).
      return;
    }

    final hadOtherDraft =
        _visitsDirty ||
        _draft.isNotEmpty ||
        _attachmentsDirty ||
        _pendingClientAddress != null;

    await updateVisit(visit.withManualConfirm(nextStatus));

    if (nextStatus == JobVisit.confirmConfirmed) {
      // Подтверждение — сохраняем сразу (нужно для SMS).
      await commitChanges();
      return;
    }

    // Снятие подтверждения: в Firestore только если не было других правок.
    if (!hadOtherDraft) {
      await commitChanges();
    }
  }

  Future<void> markVisitDone(String visitId) async {
    JobVisit? target;
    for (final visit in visits) {
      if (visit.id == visitId) target = visit;
    }
    if (target == null) return;
    await updateVisit(target.copyWith(outcome: JobVisit.done));
  }

  Future<void> updateDurationMinutes(int minutes) async {
    durationMinutes = minutes.clamp(15, 8 * 60);
    final planned = visits.where((v) => v.isScheduled).toList();
    if (planned.length == 1) {
      await updateVisit(
        planned.first.copyWith(durationMinutes: durationMinutes),
      );
      return;
    }
    notifyListeners();
    _queue({'durationMinutes': durationMinutes});
  }

  Future<void> updatePackingNotes(String notes) async {
    packingNotes = notes;
    _queue({'packingNotes': notes});
  }

  Future<void> updateAppliances(List<Map<String, dynamic>> items) async {
    final list = <Map<String, dynamic>>[];
    for (final item in items) {
      final normalized = <String, String>{
        'type': (item['type'] ?? '').toString().trim(),
        'brand': (item['brand'] ?? '').toString().trim(),
        'model': (item['model'] ?? '').toString().trim(),
        'serialNumber': (item['serialNumber'] ?? '').toString().trim(),
        'issue': (item['issue'] ?? '').toString().trim(),
      };
      if (normalized['type']!.isEmpty) continue;
      list.add(normalized);
    }
    if (list.isEmpty) return;
    final first = list.first;
    jobData['appliances'] = list;
    jobData['applianceType'] = first['type'];
    jobData['brand'] = first['brand'];
    jobData['model'] = first['model'];
    jobData['serialNumber'] = first['serialNumber'];
    _queue({
      'appliances': list,
      'applianceType': first['type'],
      'brand': first['brand'],
      'model': first['model'],
      'serialNumber': first['serialNumber'],
    });
  }

  void replaceAttachments(List<Map<String, dynamic>> next) {
    attachments = [for (final item in next) Map<String, dynamic>.from(item)];
    _attachmentsDirty = true;
    notifyListeners();
  }

  /// Фото не улетело и ждёт связи — карточка показывает подсказку.
  bool photosQueued = false;

  Future<List<Map<String, dynamic>>> _uploadPendingAttachments() async {
    photosQueued = false;
    final result = <Map<String, dynamic>>[];
    for (final raw in attachments) {
      final item = Map<String, dynamic>.from(raw);
      final pending = item['pendingUpload'] == true;
      final local = (item['localPath'] ?? '').toString();
      if (pending && local.isNotEmpty) {
        final fileName =
            (item['name'] ?? '${DateTime.now().millisecondsSinceEpoch}.jpg')
                .toString();
        try {
          final storageRef = FirebaseStorage.instance.ref().child(
            'jobs/$jobId/attachments/$fileName',
          );
          // На слабой связи загрузка может тянуться минутами и держать
          // «Сохранить». Ждём недолго, дальше фото уходит в очередь.
          await storageRef
              .putFile(File(local))
              .timeout(const Duration(seconds: 25));
          item['url'] = await storageRef.getDownloadURL().timeout(
            const Duration(seconds: 15),
          );
          item.remove('localPath');
          item.remove('pendingUpload');
        } catch (_) {
          photosQueued = true;
          await OfflineQueueService.enqueuePhoto(
            jobId: jobId,
            localPath: local,
            fileName: fileName,
          );
        }
      }
      result.add(item);
    }
    return result;
  }

  Future<void> updateTracking({
    required String number,
    required String amazonId,
    String carrier = '',
    String part = '',
  }) async {
    trackingNumber = number.trim();
    amazonOrderId = amazonId.trim();
    trackingPart = part.trim();
    final hasAny =
        trackingNumber.isNotEmpty ||
        amazonOrderId.isNotEmpty ||
        trackingPart.isNotEmpty;
    final resolvedCarrier = !hasAny
        ? ''
        : (carrier.trim().isNotEmpty
              ? carrier.trim()
              : (amazonOrderId.isNotEmpty ? 'amazon' : 'other'));
    trackingCarrier = resolvedCarrier;
    jobData['trackingNumber'] = trackingNumber;
    jobData['amazonOrderId'] = amazonOrderId;
    jobData['trackingCarrier'] = resolvedCarrier;
    jobData['trackingPart'] = trackingPart;
    _queue({
      'trackingNumber': trackingNumber,
      'amazonOrderId': amazonOrderId,
      'trackingCarrier': resolvedCarrier,
      'trackingPart': trackingPart,
    });
  }

  Future<void> updateWorkAddress({
    required String street,
    required String city,
    required String postal,
    String unit = '',
  }) async {
    final full = [
      if (street.trim().isNotEmpty) street.trim(),
      if (unit.trim().isNotEmpty)
        (RegExp(
              r'^(?:unit|apt|suite|#)\b',
              caseSensitive: false,
            ).hasMatch(unit.trim())
            ? unit.trim()
            : 'Unit ${unit.trim()}'),
      if (city.trim().isNotEmpty) city.trim(),
      if (postal.trim().isNotEmpty) postal.trim(),
    ].join(', ');
    if (hasJobSite) {
      jobSiteAddress = full;
      jobData['jobSiteAddress'] = full;
      _queue({'jobSiteAddress': full});
    } else {
      jobData['clientAddress'] = full;
      _pendingClientAddress = (
        street: street,
        city: city,
        postal: postal,
        unit: unit,
      );
      _queue({'clientAddress': full});
    }
    isLoadingTime = true;
    notifyListeners();
    await _calculateTravelTime();
  }

  String _composeAddress({
    required String street,
    required String city,
    required String postal,
    String unit = '',
  }) {
    return [
      if (street.trim().isNotEmpty) street.trim(),
      if (unit.trim().isNotEmpty)
        (RegExp(
              r'^(?:unit|apt|suite|#)\b',
              caseSensitive: false,
            ).hasMatch(unit.trim())
            ? unit.trim()
            : 'Unit ${unit.trim()}'),
      if (city.trim().isNotEmpty) city.trim(),
      if (postal.trim().isNotEmpty) postal.trim(),
    ].join(', ');
  }

  Future<void> updateClientAddress({
    required String street,
    required String city,
    required String postal,
    String unit = '',
  }) async {
    final full = _composeAddress(
      street: street,
      city: city,
      postal: postal,
      unit: unit,
    );
    jobData['clientAddress'] = full;
    _pendingClientAddress = (
      street: street,
      city: city,
      postal: postal,
      unit: unit,
    );
    _queue({'clientAddress': full});
    if (!hasJobSite) {
      isLoadingTime = true;
      notifyListeners();
      await _calculateTravelTime();
      return;
    }
    notifyListeners();
  }

  Future<void> updateJobSite({
    required String name,
    required String phone,
    required String address,
    String email = '',
  }) async {
    hasJobSite = true;
    jobSiteName = name.trim();
    jobSitePhone = phone.trim();
    jobSiteAddress = address.trim();
    jobSiteEmail = email.trim();
    jobData['hasJobSite'] = true;
    jobData['jobSiteName'] = jobSiteName;
    jobData['jobSitePhone'] = jobSitePhone;
    jobData['jobSiteAddress'] = jobSiteAddress;
    jobData['jobSiteEmail'] = jobSiteEmail;
    _queue({
      'hasJobSite': true,
      'jobSiteName': jobSiteName,
      'jobSitePhone': jobSitePhone,
      'jobSiteAddress': jobSiteAddress,
      'jobSiteEmail': jobSiteEmail,
    });
    isLoadingTime = true;
    notifyListeners();
    await _calculateTravelTime();
  }

  Future<void> clearJobSite() async {
    hasJobSite = false;
    jobSiteName = '';
    jobSitePhone = '';
    jobSiteAddress = '';
    jobSiteEmail = '';
    jobData['hasJobSite'] = false;
    jobData['jobSiteName'] = '';
    jobData['jobSitePhone'] = '';
    jobData['jobSiteAddress'] = '';
    jobData['jobSiteEmail'] = '';
    _queue({
      'hasJobSite': false,
      'jobSiteName': '',
      'jobSitePhone': '',
      'jobSiteAddress': '',
      'jobSiteEmail': '',
    });
    isLoadingTime = true;
    notifyListeners();
    await _calculateTravelTime();
  }

  Future<void> saveDocuments() async {
    await JobService.updateDocuments(jobId, documents);
  }

  void setFinanceMode(String mode) {
    financeMode = mode;
    if (mode != 'builder') {
      builderItems = [];
    }
    notifyListeners();
  }

  void openFinanceMainList({bool switchTab = true}) {
    viewingDocumentIndex = null;
    financeMode = 'main';
    if (switchTab) _financeTabRequested = true;
    notifyListeners();
  }

  void consumeFinanceTabRequest() {
    _financeTabRequested = false;
  }

  void _onDocumentsRemoteUpdate(
    List<Map<String, dynamic>> nextDocs, {
    String remoteStatus = '',
  }) {
    final prevDocs = documents;
    var justPaid = false;
    var justDeposited = false;
    if (prevDocs.isNotEmpty) {
      for (var i = 0; i < nextDocs.length; i++) {
        final next = nextDocs[i];
        final prev = i < prevDocs.length ? prevDocs[i] : null;
        if (_invoiceFullyPaid(next) &&
            !(prev != null && _invoiceFullyPaid(prev))) {
          justPaid = true;
        }
        if (Job.documentDepositTaken(next) &&
            !(prev != null && Job.documentDepositTaken(prev))) {
          justDeposited = true;
        }
      }
    }
    documents = nextDocs;
    unawaited(_autoConvertApprovedEstimates());
    if (justDeposited) unawaited(markDepositTaken(remoteStatus: remoteStatus));
    if (justPaid) {
      onInvoiceFullyPaid?.call();
      unawaited(completeAfterInvoicePaid());
    }
  }

  bool _convertingApprovedEstimate = false;

  /// Когда клиент подтверждает Estimate, он автоматически превращается в Invoice.
  Future<void> _autoConvertApprovedEstimates() async {
    if (_convertingApprovedEstimate || _disposed) return;
    _convertingApprovedEstimate = true;
    try {
      var changed = false;
      for (var i = 0; i < documents.length; i++) {
        final doc = documents[i];
        if (Job.isDocumentTrashed(doc)) continue;
        if ((doc['type'] ?? '') != 'Estimate') continue;
        if (doc['status'] == 'cancelled') continue;
        if ((doc['estimateStatus'] ?? '') != 'approved') continue;
        if (doc['convertedToInvoice'] == true) continue;
        final items = [
          for (final item in doc['items'] as List? ?? [])
            if (item is Map) Map<String, dynamic>.from(item),
        ];
        if (items.isEmpty) continue;
        final number = await SettingsService.takeNextDocumentNumber('Invoice');
        if (_disposed) return;
        final invoice = <String, dynamic>{
          'type': 'Invoice',
          'number': number,
          'items': items,
          'taxRate': doc['taxRate'] ?? 0.0,
          'payments': <Map<String, dynamic>>[],
          'createdAt': DateTime.now().toIso8601String(),
          'fromEstimateNumber': doc['number'],
        };
        await WarehouseService.applyDocumentStock(invoice, reverse: false);
        documents[i] = {
          ...doc,
          'convertedToInvoice': true,
          'convertedInvoiceNumber': number,
        };
        documents.add(invoice);
        if (viewingDocumentIndex == i) {
          viewingDocumentIndex = documents.length - 1;
        }
        changed = true;
      }
      if (changed && !_disposed) {
        await saveDocuments();
        notifyListeners();
      }
    } catch (_) {
    } finally {
      _convertingApprovedEstimate = false;
    }
  }

  bool _invoiceFullyPaid(Map<String, dynamic> doc) {
    return Job.isInvoice(doc) &&
        !Job.isDocumentTrashed(doc) &&
        Job.documentPayMark(doc) == 'paid';
  }

  /// Клиент оставил депозит по счёту → статус заявки «Депозит» сразу, без
  /// вопросов. «Ожидание запчасти» и закрытые статусы не трогаем.
  Future<void> markDepositTaken({String remoteStatus = ''}) async {
    // Тем же обновлением статус мог поставить сервер (вебхук Stripe) —
    // второй раз в базу не пишем.
    final status = remoteStatus.trim().isEmpty ? currentStatus : remoteStatus;
    if (!JobStatuses.shouldMarkDeposit(status)) return;
    await updateStatus(JobStatuses.deposit, persistNow: true);
  }

  /// Полная оплата инвойса → предлагаем пометить «Готово», не переводим автоматически.
  Future<void> completeAfterInvoicePaid() async {
    openFinanceMainList();
    if (JobStatuses.isCompletedStatus(currentStatus) ||
        JobStatuses.isCancelledStatus(currentStatus)) {
      return;
    }
    // Предлагаем пометить заявку завершённой вместо автоматического перевода.
    pendingSuggestComplete = true;
    notifyListeners();
  }

  void dismissSuggestComplete() {
    pendingSuggestComplete = false;
    notifyListeners();
  }

  void dismissSuggestCancel() {
    pendingSuggestCancel = false;
    notifyListeners();
  }

  Future<void> confirmSuggestComplete() async {
    pendingSuggestComplete = false;
    if (JobStatuses.isCompletedStatus(currentStatus)) return;
    await updateStatus(JobStatuses.completed, persistNow: true);
  }

  Future<void> confirmSuggestCancel() async {
    pendingSuggestCancel = false;
    if (JobStatuses.isCancelledStatus(currentStatus)) return;
    await updateStatus(JobStatuses.cancelled, persistNow: true);
  }

  void notifyBuilderChanged() {
    notifyListeners();
  }

  void setViewingDocumentIndex(int? index) {
    viewingDocumentIndex = index;
    notifyListeners();
  }

  Future<void> addDocument(Map<String, dynamic> doc) async {
    if ((doc['type'] ?? '') != 'Estimate') {
      await WarehouseService.applyDocumentStock(doc, reverse: false);
    }
    documents.add(doc);
    await saveDocuments();
    notifyListeners();
  }

  Future<void> updateDocument(int index, Map<String, dynamic> doc) async {
    if (index >= 0 && index < documents.length) {
      final wasDeposit = Job.documentDepositTaken(documents[index]);
      documents[index] = doc;
      await saveDocuments();
      notifyListeners();
      if (!wasDeposit && Job.documentDepositTaken(doc)) {
        await markDepositTaken();
      }
    }
  }

  Future<void> deleteDocument(int index) async {
    if (index >= 0 && index < documents.length) {
      if (Job.isDocumentTrashed(documents[index])) return;
      await WarehouseService.applyDocumentStock(
        documents[index],
        reverse: true,
      );
      documents[index] = {
        ...documents[index],
        'deletedAt': DateTime.now().toIso8601String(),
      };
      if (viewingDocumentIndex == index) {
        viewingDocumentIndex = null;
        financeMode = 'main';
      }
      await saveDocuments();
      notifyListeners();
    }
  }

  void addAttachment(Map<String, dynamic> attachment) {
    attachments.add(attachment);
    notifyListeners();
  }

  void setUploadingImage(bool value) {
    isUploadingImage = value;
    notifyListeners();
  }

  void setChatRole(String role) {
    activeChatRole = role;
    notifyListeners();
  }

  void setChatSendMethod(String method) {
    chatSendMethod = method;
    notifyListeners();
  }

  // === Вспомогательные методы для финансов ===

  static double _asDouble(dynamic value, [double fallback = 0]) {
    if (value is num) return value.toDouble();
    return double.tryParse('$value') ?? fallback;
  }

  double calcSubtotal(List<dynamic> items) {
    double total = 0;
    for (var item in items) {
      if (item is! Map) continue;
      final qty = _asDouble(item['qty'], 1);
      final price = _asDouble(item['price'], 0);
      total += qty * price;
    }
    return total;
  }

  double calcTax(double subtotal, dynamic rate) {
    return subtotal * _asDouble(rate, 0);
  }

  double calcTotal(double subtotal, double tax) {
    return subtotal + tax;
  }

  double calcPaid(List<dynamic> payments) {
    double total = 0;
    for (var p in payments) {
      if (p is! Map) continue;
      total += _asDouble(p['amount'], 0);
    }
    return total;
  }

  double calcDue(double total, double paid) {
    return (total - paid).clamp(0, double.infinity);
  }

  Color getStatusColor() => StatusService.colorOf(currentStatus);
}

class JobChatContact {
  final String id;
  final String label;
  final String name;
  final String phone;
  final String email;

  const JobChatContact({
    required this.id,
    required this.label,
    required this.name,
    required this.phone,
    this.email = '',
  });

  String get normalizedPhone => SmsService.normalizePhone(phone);

  String get normalizedEmail => email.trim().toLowerCase();

  bool get hasPhone => normalizedPhone.length >= 10;

  bool get hasEmail => normalizedEmail.contains('@');

  bool get isOwner =>
      id == 'client' || id == 'owner' || label == 'Хозяин'.tr;

  String get displayName => name.isEmpty ? label : name;

  String get subtitleLine => [
    label,
    if (hasPhone) phone.trim(),
    if (hasEmail) email.trim(),
  ].join(' · ');

  bool get hasChannel => hasPhone || hasEmail;
}
