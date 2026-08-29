import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import '../../../core/constants.dart';
import '../../../models/client.dart';
import '../../../models/job.dart';
import '../../../services/services.dart';
import '../../../core/l10n/app_locale.dart';

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
  final Map<String, Map<String, dynamic>> _relatedCalls = {};
  bool _disposed = false;
  bool _financeTabRequested = false;

  bool get financeTabRequested => _financeTabRequested;

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
    durationMinutes = (jobData['durationMinutes'] as num?)?.toInt() ?? kDefaultVisitMinutes;
    packingNotes = jobData['packingNotes'] ?? '';
    trackingNumber = (jobData['trackingNumber'] ?? '').toString();
    amazonOrderId = (jobData['amazonOrderId'] ?? '').toString();
    trackingStatus = (jobData['trackingStatus'] ?? '').toString();
    visits = _parseVisits(jobData);
    _applyVisitFields(visits);

    hasJobSite = jobData['hasJobSite'] == true;
    jobSiteName = jobData['jobSiteName'] ?? '';
    jobSitePhone = jobData['jobSitePhone'] ?? '';
    jobSiteAddress = jobData['jobSiteAddress'] ?? '';
    jobSiteEmail = (jobData['jobSiteEmail'] ?? '').toString();

    if (jobData['documents'] != null) {
      documents = List<Map<String, dynamic>>.from(jobData['documents']);
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
      if (!snap.exists) return;
      final data = snap.data() as Map<String, dynamic>?;
      if (data == null) return;
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

      if (data.containsKey('clientName') || data.containsKey('name')) {
        jobData['clientName'] =
            (data['clientName'] ?? data['name'] ?? jobData['clientName']);
      }
      if (data.containsKey('clientPhone')) {
        jobData['clientPhone'] = data['clientPhone'];
      }

      if (data['documents'] != null) {
        final nextDocs = List<Map<String, dynamic>>.from(
          (data['documents'] as List).map(
            (e) => Map<String, dynamic>.from(e as Map),
          ),
        );
        _onDocumentsRemoteUpdate(nextDocs);
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
        visits = _parseVisits(data);
        _applyVisitFields(visits);
        hasJobSite = data['hasJobSite'] == true;
        if (data.containsKey('jobSiteName')) {
          jobSiteName = (data['jobSiteName'] ?? '').toString();
        }
        if (data.containsKey('jobSitePhone')) {
          jobSitePhone = (data['jobSitePhone'] ?? '').toString();
        }
        if (data.containsKey('jobSiteAddress')) {
          jobSiteAddress = (data['jobSiteAddress'] ?? '').toString();
        }
        if (data.containsKey('jobSiteEmail')) {
          jobSiteEmail = (data['jobSiteEmail'] ?? '').toString();
        }
        if (data.containsKey('clientAddress')) {
          jobData['clientAddress'] = data['clientAddress'];
        }
        if (data.containsKey('clientName') || data.containsKey('name')) {
          jobData['clientName'] =
              (data['clientName'] ?? data['name'] ?? jobData['clientName']);
        }
        if (data.containsKey('clientPhone')) {
          jobData['clientPhone'] = data['clientPhone'];
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
    items.sort((a, b) {
      final aAt = CallRecord.parseStamp(a['startTime']) ??
          CallRecord.parseStamp(a['uploadedAt']) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bAt = CallRecord.parseStamp(b['startTime']) ??
          CallRecord.parseStamp(b['uploadedAt']) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return aAt.compareTo(bAt);
    });
    return items;
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
      r'(^|\n)\s*(ИИ|AI|Assistant|Master|Мастер|Секретарь)\s*:',
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
    return a.trim().length >= b.trim().length ? a : b;
  }

  void _listenRelatedCalls() {
    Map<String, dynamic> toAttachment(QueryDocumentSnapshot doc) {
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
        'transcriptionRu': (data['transcriptionRu'] ?? transcription)
            .toString(),
        'transcriptionEn': (data['transcriptionEn'] ?? '').toString(),
        'summary': (data['summary'] ?? '').toString(),
        'history': history,
        'answeredBy': (data['answeredBy'] ?? '').toString(),
        'startTime': data['startTime'] ?? data['createdAt'],
        'direction': (data['direction'] ?? '').toString(),
        'fromNumber': (data['fromNumber'] ?? '').toString(),
      };
    }

    void ingest(QuerySnapshot snap) {
      for (final doc in snap.docs) {
        _relatedCalls[doc.id] = toAttachment(doc);
      }
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

  @override
  void dispose() {
    _disposed = true;
    _jobSubscription?.cancel();
    _clientSub?.cancel();
    _callsCreatedSub?.cancel();
    _callsJobSub?.cancel();
    super.dispose();
  }

  /// Адрес для навигации
  String get workAddress => hasJobSite
      ? jobSiteAddress
      : (jobData['clientAddress'] ?? 'Не указан'.tr);

  /// Контактное имя на месте
  String get contactName =>
      hasJobSite ? jobSiteName : (jobData['clientName'] ?? 'Неизвестно'.tr);

  /// Контактный телефон
  String get contactPhone =>
      hasJobSite ? jobSitePhone : (jobData['clientPhone'] ?? '');

  List<JobChatContact> get chatContacts {
    final client = JobChatContact(
      id: 'client',
      label: 'Хозяин'.tr,
      name: (jobData['clientName'] ?? 'Клиент'.tr).toString().trim(),
      phone: (jobData['clientPhone'] ?? '').toString().trim(),
      email: clientEmail,
    );
    final site = JobChatContact(
      id: 'site',
      label: 'Арендатор'.tr,
      name: jobSiteName.trim().isEmpty ? 'Арендатор'.tr : jobSiteName.trim(),
      phone: jobSitePhone.trim(),
      email: jobSiteEmail.trim(),
    );

    final result = <JobChatContact>[];
    if (client.hasChannel) result.add(client);
    if (hasJobSite && site.hasChannel) {
      if (result.isEmpty || site.normalizedPhone != client.normalizedPhone) {
        result.add(site);
      }
    }
    return result;
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
    _clientSub = FirestoreService.clientsRef.doc(clientId).snapshots().listen((
      snap,
    ) {
      if (_disposed || !snap.exists) return;
      final data = snap.data() as Map<String, dynamic>?;
      if (data == null) return;
      final name = (data['fullName'] ?? data['name'] ?? '').toString().trim();
      final phone = (data['phone'] ?? '').toString().trim();
      final address = (data['address'] ?? '').toString().trim();
      final email = (data['email'] ?? '').toString().trim();
      var changed = false;
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
    } else if (JobStatuses.isCancelledStatus(status)) {
      _applyVisitFields(JobVisit.markAllScheduledCancelled(visits));
      _visitsDirty = true;
      needsReview = false;
    }
    _queue({
      'status': status,
      if (JobStatuses.isCompletedStatus(status))
        'completedAt': FieldValue.serverTimestamp(),
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
      await saveVisits(
        [
          JobVisit.create(startAt: newValue, durationMinutes: durationMinutes),
        ],
        markInstall: fromParts,
      );
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

  Future<void> updateVisit(JobVisit visit) {
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
      [
        for (final item in visits) item.id == visit.id ? visit : item,
      ],
      markRescheduled: dayChanged && !fromParts,
      markInstall: fromParts,
    );
  }

  Future<void> removeVisit(String visitId) {
    return saveVisits(visits.where((v) => v.id != visitId).toList());
  }

  Future<void> updateVisitConfirm(JobVisit visit, String status) async {
    final nextStatus =
        status.trim().isEmpty ? JobVisit.confirmPending : status.trim();
    final current = visit.effectiveConfirmStatus;
    final alreadyPending = current.isEmpty || current == JobVisit.confirmPending;
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

  Future<void> updateApplianceType(String type) async {
    await updateAppliance(type: type);
  }

  Future<void> updateAppliance({required String type, String? brand}) async {
    final nextType = type.trim();
    if (nextType.isEmpty) return;
    final nextBrand = (brand ?? jobData['brand'] ?? '').toString().trim();
    jobData['applianceType'] = nextType;
    jobData['brand'] = nextBrand;
    final raw = jobData['appliances'];
    final list = <Map<String, dynamic>>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) list.add(Map<String, dynamic>.from(item));
      }
    }
    if (list.isEmpty) {
      list.add({
        'type': nextType,
        'brand': nextBrand,
        'model': (jobData['model'] ?? '').toString(),
        'serialNumber': (jobData['serialNumber'] ?? '').toString(),
        'issue': currentDescription,
      });
    } else {
      list[0]['type'] = nextType;
      list[0]['brand'] = nextBrand;
    }
    jobData['appliances'] = list;
    _queue({'applianceType': nextType, 'brand': nextBrand, 'appliances': list});
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
          item['url'] = await storageRef
              .getDownloadURL()
              .timeout(const Duration(seconds: 15));
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
  }) async {
    trackingNumber = number.trim();
    amazonOrderId = amazonId.trim();
    _queue({
      'trackingNumber': trackingNumber,
      'amazonOrderId': amazonOrderId,
      'trackingCarrier': carrier.trim().isNotEmpty
          ? carrier.trim()
          : (amazonOrderId.isNotEmpty ? 'amazon' : 'other'),
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

  void _onDocumentsRemoteUpdate(List<Map<String, dynamic>> nextDocs) {
    final prevDocs = documents;
    var justPaid = false;
    if (prevDocs.isNotEmpty) {
      for (var i = 0; i < nextDocs.length; i++) {
        final next = nextDocs[i];
        if (!_invoiceFullyPaid(next)) continue;
        final prev = i < prevDocs.length ? prevDocs[i] : null;
        if (prev != null && _invoiceFullyPaid(prev)) continue;
        justPaid = true;
        break;
      }
    }
    documents = nextDocs;
    if (justPaid) {
      onInvoiceFullyPaid?.call();
      unawaited(completeAfterInvoicePaid());
    }
  }

  bool _invoiceFullyPaid(Map<String, dynamic> doc) {
    return Job.isInvoice(doc) &&
        !Job.isDocumentTrashed(doc) &&
        Job.documentPayMark(doc) == 'paid';
  }

  /// Полная оплата инвойса → статус «Готово». Просьбу об отзыве спрашивает экран.
  Future<void> completeAfterInvoicePaid() async {
    openFinanceMainList();
    if (JobStatuses.isCompletedStatus(currentStatus) ||
        JobStatuses.isCancelledStatus(currentStatus)) {
      return;
    }
    await updateStatus(
      JobStatuses.completed,
      persistNow: true,
    );
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
      documents[index] = doc;
      await saveDocuments();
      notifyListeners();
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

  String get displayName => name.isEmpty ? label : name;

  bool get hasChannel =>
      normalizedPhone.length >= 10 || email.trim().contains('@');
}
