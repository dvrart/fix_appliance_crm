import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'firestore_service.dart';
import '../core/app_commands.dart';
import '../core/constants.dart';
import '../models/job.dart';
import 'client_service.dart';
import 'offline_queue_service.dart';
import 'twilio_service.dart';

/// Сервис для работы с заявками
class JobService {
  static final _ref = FirestoreService.jobsRef;

  /// Стрим всех заявок
  static Stream<List<Job>> streamAll() {
    return _ref.snapshots().map((snapshot) => _parseDocs(snapshot));
  }

  static Stream<List<Job>> streamTrashed() {
    return _ref.snapshots().map(
      (snapshot) => _parseDocs(
        snapshot,
        includeDeleted: true,
      ).where((job) => job.isDeleted).toList(),
    );
  }

  static List<Job> _parseDocs(
    QuerySnapshot snapshot, {
    bool includeDeleted = false,
  }) {
    final jobs = <Job>[];
    for (final doc in snapshot.docs) {
      try {
        final job = Job.fromMap(doc.data() as Map<String, dynamic>, doc.id);
        if (!includeDeleted && job.isDeleted) continue;
        jobs.add(job);
      } catch (_) {}
    }
    return jobs;
  }

  /// Стрим заявок по статусу
  static Stream<List<Job>> streamByStatus(String status) {
    return _ref
        .where('status', isEqualTo: status)
        .snapshots()
        .map((snapshot) => _parseDocs(snapshot));
  }

  /// Стрим заявок для календаря (только с датой)
  static Stream<List<Job>> streamScheduled() {
    return _ref
        .where('scheduledAt', isNull: false)
        .snapshots()
        .map((snapshot) => _parseDocs(snapshot));
  }

  /// Стрим заявок клиента
  static Stream<List<Job>> streamByClient(String clientId) {
    return _ref
        .where('clientId', isEqualTo: clientId)
        .snapshots()
        .map((snapshot) => _parseDocs(snapshot));
  }

  static Future<int> activeCountForClient(String clientId) async {
    if (clientId.trim().isEmpty) return 0;
    final jobs = await streamByClient(clientId).first;
    return jobs.length;
  }

  static Future<Set<String>> clientIdsWithJobs(Iterable<String> ids) async {
    final out = <String>{};
    for (final id in ids) {
      if (id.trim().isEmpty) continue;
      if (await activeCountForClient(id) > 0) out.add(id);
    }
    return out;
  }

  /// Стрим заявок, которые ИИ создал и которые ещё не проверили
  static Stream<List<Job>> streamNeedsReview() {
    return _ref.where('needsReview', isEqualTo: true).snapshots().map((
      snapshot,
    ) {
      final jobs = <Job>[];
      for (final doc in snapshot.docs) {
        try {
          final job = Job.fromMap(doc.data() as Map<String, dynamic>, doc.id);
          if (job.isDeleted || JobStatuses.isClosed(job.status)) continue;
          jobs.add(job);
        } catch (_) {}
      }
      jobs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return jobs;
    });
  }

  static Future<void> markReviewed(String id) async {
    await update(id, {'needsReview': false});
    try {
      await TwilioService.markJobCallsReviewed(id);
    } catch (_) {}
  }

  static Future<List<Job>> loadAllOnce() async {
    final snapshot = await _ref.get();
    return _parseDocs(snapshot);
  }

  static const _legacyCompleteKey = 'completedJobsBefore';
  static const _legacyCompleteValue = '2026-08-17';

  static bool _isLegacyBeforeCutoff(Job job, DateTime cutoff) {
    if (job.isDeleted || JobStatuses.isClosed(job.status)) return false;
    final visits = job.coalescedVisits;
    if (visits.isNotEmpty) {
      return visits.every((visit) => visit.startAt.isBefore(cutoff));
    }
    final date = job.scheduledAt ?? job.createdAt;
    return date.isBefore(cutoff);
  }

  /// One-shot: mark jobs whose last visit is before 17 Aug 2026 as completed.
  static Future<void> completeLegacyJobsIfNeeded() async {
    try {
      final snap = await FirestoreService.configRef.get();
      final data = (snap.data() as Map<String, dynamic>?) ?? {};
      if (data[_legacyCompleteKey] == _legacyCompleteValue) return;
      final count = await _completeJobsBefore(DateTime(2026, 8, 17));
      await FirestoreService.configRef.set({
        _legacyCompleteKey: _legacyCompleteValue,
        'completedJobsBeforeCount': count,
      }, SetOptions(merge: true));
    } catch (e, st) {
      debugPrint('completeLegacyJobsIfNeeded: $e\n$st');
    }
  }

  static Future<int> _completeJobsBefore(DateTime cutoff) async {
    final jobs = await loadAllOnce();
    final targets = jobs.where((job) => _isLegacyBeforeCutoff(job, cutoff));
    var count = 0;
    WriteBatch? batch;
    var ops = 0;

    Future<void> flush() async {
      final current = batch;
      if (current == null || ops == 0) return;
      await current.commit();
      batch = null;
      ops = 0;
    }

    for (final job in targets) {
      batch ??= FirebaseFirestore.instance.batch();
      final visits = JobVisit.markAllScheduledDone(job.coalescedVisits);
      final last = job.latestVisit?.startAt ?? job.scheduledAt ?? job.createdAt;
      batch!.update(_ref.doc(job.id), {
        'status': JobStatuses.completed,
        'completedAt': Timestamp.fromDate(last),
        'needsReview': false,
        'reviewSmsSentAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        ...JobVisit.syncFields(visits, defaultDuration: job.durationMinutes),
      });
      ops += 1;
      count += 1;
      if (ops >= 400) await flush();
    }
    await flush();
    return count;
  }

  /// Получить заявку по ID
  static Future<Job?> getById(String id) async {
    final doc = await _ref.doc(id).get();
    if (!doc.exists) return null;
    return Job.fromMap(doc.data() as Map<String, dynamic>, doc.id);
  }

  static final _creatingFromCall = <String>{};

  static String _textOf(Map<String, dynamic>? data, List<String> keys) {
    if (data == null) return '';
    for (final key in keys) {
      final value = (data[key] ?? '').toString().trim();
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  static String _historyText(CallRecord call) {
    final history = call.aiReception?['history'];
    if (history is! List) return '';
    final bits = <String>[];
    for (final item in history) {
      if (item is Map && (item['text'] ?? '').toString().trim().isNotEmpty) {
        bits.add(item['text'].toString());
      }
    }
    return bits.join('\n');
  }

  static String _callText(CallRecord call) {
    return [
      call.transcription ?? '',
      call.transcriptionEn ?? '',
      call.transcriptionRu ?? '',
      _historyText(call),
    ].join('\n');
  }

  static String _inferAppliance(String text) {
    final t = text.toLowerCase();
    if (RegExp(r'dish\s*wash|посудомое').hasMatch(t)) return 'Dishwasher';
    if (RegExp(r'\b(washer|washing machine|стиральн)').hasMatch(t)) {
      return 'Washer';
    }
    if (RegExp(r'\b(dryer|сушильн)').hasMatch(t)) return 'Dryer';
    if (RegExp(r'\b(fridge|refrigerator|холодильн)').hasMatch(t))
      return 'Fridge';
    if (RegExp(r'\b(freezer|морозил)').hasMatch(t)) return 'Freezer';
    if (RegExp(r'\b(microwave|микроволн)').hasMatch(t)) return 'Microwave';
    if (RegExp(r'\b(cooktop|cook top|варочн)').hasMatch(t)) return 'Cooktop';
    if (RegExp(r'\b(stove|range|плит)').hasMatch(t)) return 'Stove';
    if (RegExp(r'\b(oven|духовк)').hasMatch(t)) return 'Oven';
    return '';
  }

  static bool _looksLikeRepairCall(CallRecord call) {
    if (call.serviceDeclined) return false;
    final extracted =
        call.extractedData ??
        ((call.aiReception?['extracted'] is Map)
            ? Map<String, dynamic>.from(call.aiReception!['extracted'] as Map)
            : <String, dynamic>{});
    if (call.aiReception?['createJob'] == true) return true;
    if (_textOf(extracted, const [
      'appliance_type',
      'applianceType',
    ]).isNotEmpty) {
      return true;
    }
    if (_textOf(extracted, const [
      'problem_description',
      'problem',
    ]).isNotEmpty) {
      return true;
    }
    final text = _callText(call);
    if (_inferAppliance(text).isNotEmpty) return true;
    return RegExp(
          r'(repair|broken|not working|leak|appointment|visit|washer|dryer|fridge|dishwasher|ремонт|сломал|не работает)',
          caseSensitive: false,
        ).hasMatch(text) &&
        text.length > 80;
  }

  static DateTime? _visitFromExtracted(Map<String, dynamic> extracted) {
    final date = _textOf(extracted, const ['scheduled_date', 'scheduledDate']);
    final time = _textOf(extracted, const ['scheduled_time', 'scheduledTime']);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) return null;
    final clock = time.isEmpty ? '09:00' : time;
    return DateTime.tryParse('$date $clock');
  }

  static String _applianceKey(String raw) {
    final t = raw.trim().toLowerCase().replaceAll('ё', 'е');
    if (t.isEmpty || t == 'техника' || t == 'other' || t == 'appliance') {
      return '';
    }
    if (RegExp(r'(dish|посуд)').hasMatch(t)) return 'dishwasher';
    if (RegExp(r'(washer|стирал)').hasMatch(t)) return 'washer';
    if (RegExp(r'(dryer|сушилн)').hasMatch(t)) return 'dryer';
    if (RegExp(r'(fridge|refriger|холодиль)').hasMatch(t)) return 'fridge';
    if (RegExp(r'(freezer|морозил)').hasMatch(t)) return 'freezer';
    if (RegExp(r'(microwave|микроволн)').hasMatch(t)) return 'microwave';
    if (RegExp(r'(cooktop|варочн)').hasMatch(t)) return 'cooktop';
    if (RegExp(r'(stove|range|плит)').hasMatch(t)) return 'stove';
    if (RegExp(r'(oven|духов)').hasMatch(t)) return 'oven';
    return t.length > 24 ? t.substring(0, 24) : t;
  }

  static int _fillScore(Job job) {
    var n = 0;
    if (job.clientName.trim().isNotEmpty &&
        !job.clientName.startsWith('Клиент')) {
      n += 4;
    }
    if (job.clientAddress.trim().isNotEmpty) n += 3;
    if (job.applianceType.trim().isNotEmpty && job.applianceType != 'Техника') {
      n += 3;
    }
    if (job.description.trim().isNotEmpty) n += 2;
    if (job.visits.isNotEmpty || job.scheduledAt != null) n += 1;
    return n;
  }

  static Future<Job?> findReusableOpen({
    required String clientId,
    required String phone,
    String appliance = '',
  }) async {
    final jobs = <Job>[];
    if (clientId.trim().isNotEmpty) {
      jobs.addAll(await streamByClient(clientId).first);
    }
    if (jobs.isEmpty && phone.trim().isNotEmpty) {
      final needle = ClientService.normalizePhone(phone);
      for (final job in await loadAllOnce()) {
        final phones = [
          ClientService.normalizePhone(job.clientPhone),
          ClientService.normalizePhone(job.jobSitePhone ?? ''),
        ];
        if (phones.contains(needle)) jobs.add(job);
      }
    }
    final want = _applianceKey(appliance);
    Job? best;
    var bestScore = -1;
    for (final job in jobs) {
      if (job.isDeleted || JobStatuses.isClosed(job.status)) continue;
      final got = _applianceKey(job.applianceType);
      if (want.isNotEmpty && got.isNotEmpty && want != got) continue;
      final score = _fillScore(job);
      if (score > bestScore) {
        best = job;
        bestScore = score;
      }
    }
    return best;
  }

  /// If the secretary took a repair order but no job card exists, create it.
  static Future<String?> ensureDraftFromCall(CallRecord call) async {
    if (call.aiBlocked) return null;
    if (!_looksLikeRepairCall(call)) return null;
    if (!_creatingFromCall.add(call.id)) return call.createdJobId;
    try {
      final linked = (call.createdJobId ?? '').trim();
      if (linked.isNotEmpty) {
        final existing = await getById(linked);
        if (existing != null) {
          if (existing.isDeleted || JobStatuses.isClosed(existing.status)) {
            await TwilioService.blockJobCreate(call.id);
            return null;
          }
          return existing.id;
        }
        await TwilioService.blockJobCreate(call.id);
        return null;
      }
      final bySource = await _ref
          .where('sourceCallId', isEqualTo: call.id)
          .limit(8)
          .get();
      if (bySource.docs.isNotEmpty) {
        for (final doc in bySource.docs) {
          final job = Job.fromMap(doc.data() as Map<String, dynamic>, doc.id);
          if (job.isDeleted || JobStatuses.isClosed(job.status)) continue;
          await TwilioService.attachJob(
            callId: call.id,
            jobId: job.id,
            clientId: job.clientId,
          );
          return job.id;
        }
        await TwilioService.blockJobCreate(call.id);
        return null;
      }
      final started = call.startTime;
      if (started == null || DateTime.now().difference(started).inHours > 48) {
        return null;
      }

      final extracted = {
        ...?call.extractedData,
        if (call.aiReception?['extracted'] is Map)
          ...Map<String, dynamic>.from(call.aiReception!['extracted'] as Map),
      };
      final phone = ClientService.normalizePhone(
        _textOf(extracted, const ['client_phone', 'clientPhone']).isNotEmpty
            ? _textOf(extracted, const ['client_phone', 'clientPhone'])
            : (call.isIncoming ? call.fromNumber : call.toNumber),
      );
      var name = _textOf(extracted, const [
        'client_name',
        'clientName',
        'name',
      ]);
      if (name.isEmpty ||
          name.toLowerCase().startsWith('client') ||
          name.startsWith('Клиент')) {
        final named = RegExp(
          r"(?:my name is|this is|i'm|i am|меня зовут)\s+([A-Za-zА-Яа-яЁё']+)",
          caseSensitive: false,
        ).firstMatch(_callText(call));
        if (named != null) name = named.group(1) ?? '';
      }
      if (name.isEmpty) {
        name = phone.isEmpty ? 'Клиент' : 'Клиент $phone';
      }
      final transcript = _callText(call);
      var appliance = _textOf(extracted, const [
        'appliance_type',
        'applianceType',
      ]);
      if (appliance.isEmpty) appliance = _inferAppliance(transcript);
      if (appliance.isEmpty) appliance = 'Техника';
      final issue = _textOf(extracted, const [
        'problem_description',
        'problem',
      ]);
      final address = _textOf(extracted, const ['address', 'client_address']);
      final city = _textOf(extracted, const ['city']);
      final brand = _textOf(extracted, const ['brand']);
      final model = _textOf(extracted, const ['model']);
      final visitAt = _visitFromExtracted(extracted);

      var client = await ClientService.findByPhone(phone);
      client ??= await ClientService.findExisting(phone: phone);
      final existingName = (client?.fullName ?? '').trim();
      final placeholder =
          existingName.isEmpty ||
          existingName.toLowerCase().startsWith('client') ||
          existingName.startsWith('Клиент');
      final clientId =
          client?.id ??
          await ClientService.createOrUpdate(
            fullName: name,
            phone: phone,
            address: address,
            source: 'phone',
            createdByAi: true,
          );
      if (placeholder && name.isNotEmpty && !name.startsWith('Клиент')) {
        final keepAddress = (client?.address ?? '').trim().isNotEmpty
            ? client!.address
            : address;
        await ClientService.update(clientId, {
          'fullName': name,
          'phone': client?.phone ?? phone,
          if (keepAddress.trim().isNotEmpty) 'address': keepAddress,
          'source': 'phone',
        });
      }

      final reusable = await findReusableOpen(
        clientId: clientId,
        phone: phone,
        appliance: appliance,
      );
      if (reusable != null) {
        await TwilioService.attachJob(
          callId: call.id,
          jobId: reusable.id,
          clientId: clientId,
        );
        return reusable.id;
      }

      final visits = visitAt == null
          ? <JobVisit>[]
          : [
              JobVisit(
                id: 'v1',
                startAt: visitAt,
                durationMinutes: 120,
                outcome: 'scheduled',
              ),
            ];
      final jobId = await create(
        Job(
          id: '',
          clientId: clientId,
          clientName: name,
          clientPhone: phone,
          clientAddress: address,
          appliances: [
            JobAppliance(
              type: appliance,
              brand: brand,
              model: model,
              issue: issue,
            ),
          ],
          description: issue,
          status: JobStatuses.call,
          createdAt: DateTime.now(),
          scheduledAt: visitAt,
          visits: visits,
          city: city,
          needsReview: true,
          createdByAi: true,
          sourceCallId: call.id,
          source: 'phone',
          durationMinutes: 120,
        ),
      );
      await TwilioService.attachJob(
        callId: call.id,
        jobId: jobId,
        clientId: clientId,
      );
      return jobId;
    } catch (error) {
      debugPrint('ensureDraftFromCall: $error');
      return null;
    } finally {
      _creatingFromCall.remove(call.id);
    }
  }

  static Future<void> recoverMissingCallJobs() async {
    try {
      final calls = await TwilioService.recentCalls(limit: 12);
      final cutoff = DateTime.now().subtract(const Duration(hours: 48));
      for (final call in calls) {
        if (call.aiBlocked) continue;
        if (!call.answeredByAi && call.answeredBy != 'ai') continue;
        if (call.startTime != null && call.startTime!.isBefore(cutoff))
          continue;
        await ensureDraftFromCall(call);
      }
    } catch (error) {
      debugPrint('recoverMissingCallJobs: $error');
    }
  }

  /// Создать заявку
  static Future<String> create(Job job) async {
    final docRef = await _ref.add({
      ...job.toMap(),
      'createdAt': FieldValue.serverTimestamp(),
    });
    return docRef.id;
  }

  /// Новая заявка: тот же клиент, техника и неисправность после готового ремонта.
  static Future<String> createRepeatFrom(Job original) async {
    final appliances = original.appliances
        .map(
          (item) => JobAppliance(
            type: item.type,
            brand: item.brand,
            model: item.model,
            serialNumber: item.serialNumber,
            issue: item.issue,
          ),
        )
        .toList();
    final job = Job(
      id: '',
      clientId: original.clientId,
      clientName: original.clientName,
      clientPhone: original.clientPhone,
      clientAddress: original.clientAddress,
      hasJobSite: original.hasJobSite,
      jobSiteName: original.jobSiteName,
      jobSitePhone: original.jobSitePhone,
      jobSiteAddress: original.jobSiteAddress,
      jobSiteEmail: original.jobSiteEmail,
      appliances: appliances,
      description: original.description,
      status: JobStatuses.repeat,
      priority: original.priority,
      city: original.city,
      createdAt: DateTime.now(),
      durationMinutes: original.durationMinutes,
      repeatOfJobId: original.id,
    );
    return create(job);
  }

  /// Обновить заявку
  static Future<void> update(String id, Map<String, dynamic> data) async {
    try {
      await _ref.doc(id).update({
        ...data,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      unawaited(OfflineQueueService.flush());
    } catch (e) {
      await OfflineQueueService.enqueueJobUpdate(id, data);
    }
    final status = (data['status'] ?? '').toString();
    if (JobStatuses.isCancelledStatus(status) || data['deletedAt'] != null) {
      unawaited(_blockSourceCall(id));
    }
  }

  /// Обновить статус
  static Future<void> updateStatus(
    String id,
    String status, {
    Map<String, dynamic>? extra,
  }) async {
    final updates = <String, dynamic>{
      'status': status,
      'updatedAt': FieldValue.serverTimestamp(),
      if (extra != null) ...extra,
    };

    if (JobStatuses.isCompletedStatus(status)) {
      updates['completedAt'] = FieldValue.serverTimestamp();
    }

    final job = await getById(id);
    if (job != null) {
      var visits = [...job.coalescedVisits];
      if (status == JobStatuses.waitingPart) {
        visits = JobVisit.markLatestScheduledDone(visits);
      } else if (JobStatuses.isCompletedStatus(status)) {
        visits = JobVisit.markAllScheduledDone(visits);
      } else if (JobStatuses.isCancelledStatus(status)) {
        visits = JobVisit.markAllScheduledCancelled(visits);
        updates['needsReview'] = false;
      }
      updates.addAll(
        JobVisit.syncFields(
          visits,
          defaultDuration: job.durationMinutes,
          upcomingOnly: status == JobStatuses.waitingPart,
        ),
      );
    }

    await _ref.doc(id).update(updates);
  }

  /// Обновить приоритет
  static Future<void> updatePriority(String id, String priority) async {
    await _ref.doc(id).update({
      'priority': priority,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Обновить описание
  static Future<void> updateDescription(
    String id,
    String description, {
    String? solution,
  }) async {
    await _ref.doc(id).update({
      'description': description,
      if (solution != null) 'solution': solution,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Обновить документы (invoices, estimates)
  static Future<void> updateDocuments(
    String id,
    List<Map<String, dynamic>> documents,
  ) async {
    await update(id, {
      'documents': documents,
      'paymentStatus': _paymentStatus(documents),
    });
  }

  static String _paymentStatus(List<Map<String, dynamic>> documents) {
    var invoiced = 0.0;
    var paid = 0.0;
    for (final doc in documents) {
      if (Job.isDocumentTrashed(doc)) continue;
      if (!Job.isInvoice(doc)) continue;
      invoiced += Job.documentTotal(doc);
      paid += Job.documentPaid(doc);
    }
    if (invoiced <= 0) return 'none';
    if (paid + 0.009 >= invoiced) return 'paid';
    if (paid > 0) return 'partial';
    return 'unpaid';
  }

  /// Добавить фото
  static Future<void> addAttachment(
    String id,
    Map<String, dynamic> attachment,
  ) async {
    try {
      await _ref.doc(id).update({
        'attachments': FieldValue.arrayUnion([attachment]),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      await OfflineQueueService.enqueueJobUpdate(id, {
        'attachments': [attachment],
      });
    }
  }

  static Future<void> patchCallNotes({
    required String jobId,
    required String callId,
    required String transcription,
    required String summary,
    String? transcriptionRu,
    String? transcriptionEn,
  }) async {
    if (jobId.isEmpty || callId.isEmpty) return;
    try {
      final snap = await _ref.doc(jobId).get();
      final data = snap.data() as Map<String, dynamic>? ?? {};
      final raw = data['attachments'];
      if (raw is! List) return;
      var changed = false;
      final next = raw.map((item) {
        if (item is! Map) return item;
        final map = Map<String, dynamic>.from(item);
        if ((map['callId'] ?? '').toString() != callId) return map;
        changed = true;
        map['transcription'] = transcription;
        if (summary.trim().isNotEmpty) map['summary'] = summary;
        if (transcriptionRu != null) map['transcriptionRu'] = transcriptionRu;
        if (transcriptionEn != null) map['transcriptionEn'] = transcriptionEn;
        return map;
      }).toList();
      if (!changed) return;
      await _ref.doc(jobId).update({
        'attachments': next,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  static Future<void> _blockSourceCall(
    String id, {
    String? sourceCallId,
  }) async {
    try {
      final job = await getById(id);
      await TwilioService.blockJobCreateForJob(
        id,
        sourceCallId: sourceCallId ?? job?.sourceCallId,
      );
    } catch (_) {}
  }

  /// В корзину на 30 дней
  static Future<void> delete(String id) async {
    AppCommands.reactAngry();
    await _blockSourceCall(id);
    final job = await getById(id);
    await _ref.doc(id).update({
      'deletedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    if (job != null) {
      unawaited(
        ClientService.trashOrphanAutoClient(
          clientId: job.clientId,
          discardedJobId: id,
          jobWasUnconfirmedAuto: job.isUnconfirmedAuto,
        ),
      );
    }
  }

  static Future<void> restore(String id) async {
    await _ref.doc(id).update({
      'deletedAt': FieldValue.delete(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    try {
      final job = await getById(id);
      final clientId = (job?.clientId ?? '').trim();
      if (clientId.isEmpty) return;
      final client = await ClientService.getById(clientId);
      if (client != null && client.isDeleted) {
        await ClientService.restore(clientId);
      }
    } catch (_) {}
  }

  static Future<void> deleteForever(String id) async {
    await _blockSourceCall(id);
    final job = await getById(id);
    final messagesSnapshot = await FirestoreService.jobMessagesRef(id).get();
    for (final doc in messagesSnapshot.docs) {
      await doc.reference.delete();
    }
    await _ref.doc(id).delete();
    if (job != null) {
      unawaited(
        ClientService.trashOrphanAutoClient(
          clientId: job.clientId,
          discardedJobId: id,
          jobWasUnconfirmedAuto: job.isUnconfirmedAuto,
        ),
      );
    }
  }

  static Future<void> purgeExpiredTrash() async {
    final cutoff = DateTime.now().subtract(
      const Duration(days: Job.trashKeepDays),
    );
    final snapshot = await _ref.get();
    for (final doc in snapshot.docs) {
      try {
        final job = Job.fromMap(doc.data() as Map<String, dynamic>, doc.id);
        if (job.deletedAt != null && job.deletedAt!.isBefore(cutoff)) {
          await deleteForever(job.id);
          continue;
        }
        final next = <Map<String, dynamic>>[];
        var changed = false;
        for (final item in job.documents) {
          final deleted = Job.documentDeletedAt(item);
          if (deleted != null && deleted.isBefore(cutoff)) {
            changed = true;
            continue;
          }
          next.add(item);
        }
        if (changed) await updateDocuments(job.id, next);
      } catch (_) {}
    }
  }

  static Stream<List<({Job job, int index, Map<String, dynamic> doc})>>
  streamTrashedDocuments() {
    return streamAll().map((jobs) {
      final rows = <({Job job, int index, Map<String, dynamic> doc})>[];
      for (final job in jobs) {
        if (job.isDeleted) continue;
        for (var i = 0; i < job.documents.length; i++) {
          final doc = job.documents[i];
          if (!Job.isDocumentTrashed(doc)) continue;
          rows.add((job: job, index: i, doc: doc));
        }
      }
      rows.sort((a, b) {
        final da = Job.documentDeletedAt(a.doc) ?? DateTime(0);
        final db = Job.documentDeletedAt(b.doc) ?? DateTime(0);
        return db.compareTo(da);
      });
      return rows;
    });
  }

  static Future<void> trashDocument(String jobId, int index) async {
    final job = await getById(jobId);
    if (job == null || index < 0 || index >= job.documents.length) return;
    final next = [
      for (var i = 0; i < job.documents.length; i++)
        if (i == index)
          {...job.documents[i], 'deletedAt': Timestamp.now()}
        else
          job.documents[i],
    ];
    await updateDocuments(jobId, next);
  }

  static Future<void> restoreDocument(String jobId, int index) async {
    final job = await getById(jobId);
    if (job == null || index < 0 || index >= job.documents.length) return;
    final next = [
      for (var i = 0; i < job.documents.length; i++)
        if (i == index)
          ({...job.documents[i]}..remove('deletedAt'))
        else
          job.documents[i],
    ];
    await updateDocuments(jobId, next);
  }

  static Future<void> deleteDocumentForever(String jobId, int index) async {
    final job = await getById(jobId);
    if (job == null || index < 0 || index >= job.documents.length) return;
    final next = [
      for (var i = 0; i < job.documents.length; i++)
        if (i != index) job.documents[i],
    ];
    await updateDocuments(jobId, next);
  }

  static Future<void> deleteAllTrashedDocumentsOnJob(String jobId) async {
    final job = await getById(jobId);
    if (job == null) return;
    final next = [
      for (final doc in job.documents)
        if (!Job.isDocumentTrashed(doc)) doc,
    ];
    if (next.length == job.documents.length) return;
    await updateDocuments(jobId, next);
  }

  /// Отправить сообщение в чат заявки
  static Future<void> sendMessage({
    required String jobId,
    required String text,
    required String targetRole,
    required String sender,
  }) async {
    await FirestoreService.jobMessagesRef(jobId).add({
      'text': text,
      'targetRole': targetRole,
      'sender': sender,
      'timestamp': FieldValue.serverTimestamp(),
    });
  }

  /// Стрим сообщений заявки
  static Stream<QuerySnapshot> streamMessages(String jobId) {
    return FirestoreService.jobMessagesRef(
      jobId,
    ).orderBy('timestamp', descending: true).snapshots();
  }

  static bool isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  /// Активные заявки на конкретный день, по времени визита.
  static List<Job> activeForDay(
    List<Job> jobs,
    DateTime day, {
    bool includeClosed = false,
  }) {
    final filtered = jobs.where((job) {
      if (job.isDeleted) return false;
      if (!includeClosed && JobStatuses.isClosed(job.status)) {
        return false;
      }
      final visit = job.visitOn(day);
      if (visit == null) return false;
      if (!includeClosed && (visit.isCancelled || visit.isDone)) return false;
      return true;
    }).toList();
    filtered.sort((a, b) {
      final left = a.visitOn(day)?.startAt ?? DateTime(0);
      final right = b.visitOn(day)?.startAt ?? DateTime(0);
      return left.compareTo(right);
    });
    return filtered;
  }

  static Future<void> saveVisits(
    String id,
    List<JobVisit> visits, {
    int defaultDuration = 60,
    bool markRescheduled = false,
    String? currentStatus,
  }) {
    final data = Map<String, dynamic>.from(
      JobVisit.syncFields(visits, defaultDuration: defaultDuration),
    );
    if (JobStatuses.shouldWriteRescheduled(
      currentStatus ?? '',
      mark: markRescheduled,
    )) {
      data['status'] = JobStatuses.rescheduled;
    }
    return update(id, data);
  }

  /// Keep the same time slots, put jobs in the new list order.
  static Future<void> reassignTimeSlots(List<JobTimeSlot> ordered) async {
    if (ordered.length < 2) return;
    final slots = ordered
        .map((item) => (item.visit.startAt, item.visit.durationMinutes))
        .toList();
    final byJob = <String, List<JobVisit>>{};
    final durationByJob = <String, int>{};
    for (final item in ordered) {
      byJob.putIfAbsent(item.job.id, () => [...item.job.coalescedVisits]);
      durationByJob[item.job.id] = item.job.durationMinutes;
    }
    for (var i = 0; i < ordered.length; i++) {
      final visits = byJob[ordered[i].job.id];
      if (visits == null) continue;
      final idx = visits.indexWhere((visit) => visit.id == ordered[i].visit.id);
      if (idx < 0) continue;
      visits[idx] = visits[idx].copyWith(
        startAt: slots[i].$1,
        durationMinutes: slots[i].$2,
      );
    }
    for (final id in byJob.keys) {
      await saveVisits(
        id,
        byJob[id]!,
        defaultDuration: durationByJob[id] ?? 60,
      );
    }
  }

  static String normalizeApplianceKey(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'[\s\-_/]'), '');
  }

  /// Прошлые заявки с тем же серийником или моделью.
  static Future<List<Job>> findRelatedAppliances({
    String excludeJobId = '',
    String clientId = '',
    String serialNumber = '',
    String model = '',
    String brand = '',
  }) async {
    final serialKey = normalizeApplianceKey(serialNumber);
    final modelKey = normalizeApplianceKey(model);
    if (serialKey.isEmpty && modelKey.isEmpty) return const [];

    final pool = clientId.isNotEmpty
        ? await streamByClient(clientId).first
        : await loadAllOnce();
    final brandKey = normalizeApplianceKey(brand);

    final matches = pool.where((job) {
      if (excludeJobId.isNotEmpty && job.id == excludeJobId) return false;
      for (final appliance in job.appliances) {
        final serial = normalizeApplianceKey(appliance.serialNumber);
        if (serialKey.isNotEmpty && serial == serialKey) return true;
        final sameModel =
            modelKey.isNotEmpty &&
            normalizeApplianceKey(appliance.model) == modelKey;
        final sameBrand =
            brandKey.isEmpty ||
            normalizeApplianceKey(appliance.brand) == brandKey;
        if (serialKey.isEmpty && sameModel && sameBrand) return true;
      }
      return false;
    }).toList();
    matches.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return matches;
  }
}

class JobTimeSlot {
  final Job job;
  final JobVisit visit;
  const JobTimeSlot({required this.job, required this.visit});
}
