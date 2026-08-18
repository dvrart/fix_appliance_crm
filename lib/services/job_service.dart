import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'firestore_service.dart';
import '../core/constants.dart';
import '../models/job.dart';
import 'offline_queue_service.dart';

/// Сервис для работы с заявками
class JobService {
  static final _ref = FirestoreService.jobsRef;

  /// Стрим всех заявок
  static Stream<List<Job>> streamAll() {
    return _ref.snapshots().map((snapshot) {
      final jobs = <Job>[];
      for (final doc in snapshot.docs) {
        try {
          jobs.add(Job.fromMap(doc.data() as Map<String, dynamic>, doc.id));
        } catch (_) {}
      }
      return jobs;
    });
  }

  /// Стрим заявок по статусу
  static Stream<List<Job>> streamByStatus(String status) {
    return _ref
        .where('status', isEqualTo: status)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => Job.fromMap(doc.data() as Map<String, dynamic>, doc.id))
          .toList();
    });
  }

  /// Стрим заявок для календаря (только с датой)
  static Stream<List<Job>> streamScheduled() {
    return _ref
        .where('scheduledAt', isNull: false)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => Job.fromMap(doc.data() as Map<String, dynamic>, doc.id))
          .toList();
    });
  }

  /// Стрим заявок клиента
  static Stream<List<Job>> streamByClient(String clientId) {
    return _ref
        .where('clientId', isEqualTo: clientId)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => Job.fromMap(doc.data() as Map<String, dynamic>, doc.id))
          .toList();
    });
  }

  /// Стрим заявок, которые ИИ создал и которые ещё не проверили
  static Stream<List<Job>> streamNeedsReview() {
    return _ref
        .where('needsReview', isEqualTo: true)
        .snapshots()
        .map((snapshot) {
      final jobs = <Job>[];
      for (final doc in snapshot.docs) {
        try {
          jobs.add(Job.fromMap(doc.data() as Map<String, dynamic>, doc.id));
        } catch (_) {}
      }
      jobs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return jobs;
    });
  }

  static Future<void> markReviewed(String id) async {
    await update(id, {'needsReview': false});
  }

  static Future<List<Job>> loadAllOnce() async {
    final snapshot = await _ref.get();
    final jobs = <Job>[];
    for (final doc in snapshot.docs) {
      try {
        jobs.add(Job.fromMap(doc.data() as Map<String, dynamic>, doc.id));
      } catch (_) {}
    }
    return jobs;
  }

  /// Получить заявку по ID
  static Future<Job?> getById(String id) async {
    final doc = await _ref.doc(id).get();
    if (!doc.exists) return null;
    return Job.fromMap(doc.data() as Map<String, dynamic>, doc.id);
  }

  /// Создать заявку
  static Future<String> create(Job job) async {
    final docRef = await _ref.add({
      ...job.toMap(),
      'createdAt': FieldValue.serverTimestamp(),
    });
    return docRef.id;
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

    if (status == JobStatuses.completed) {
      updates['completedAt'] = FieldValue.serverTimestamp();
    }

    final job = await getById(id);
    if (job != null) {
      var visits = [...job.coalescedVisits];
      if (status == JobStatuses.waitingPart) {
        visits = JobVisit.markLatestScheduledDone(visits);
      } else if (status == JobStatuses.completed) {
        visits = JobVisit.markAllScheduledDone(visits);
      }
      updates.addAll(
        JobVisit.syncFields(visits, defaultDuration: job.durationMinutes),
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
  static Future<void> updateDescription(String id, String description) async {
    await _ref.doc(id).update({
      'description': description,
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

  /// Удалить заявку
  static Future<void> delete(String id) async {
    // Удаляем подколлекцию сообщений
    final messagesSnapshot = await FirestoreService.jobMessagesRef(id).get();
    for (final doc in messagesSnapshot.docs) {
      await doc.reference.delete();
    }
    // Удаляем саму заявку
    await _ref.doc(id).delete();
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
    return FirestoreService.jobMessagesRef(jobId)
        .orderBy('timestamp', descending: true)
        .snapshots();
  }

  static bool isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  /// Активные заявки на конкретный день, по времени визита.
  static List<Job> activeForDay(List<Job> jobs, DateTime day) {
    final filtered = jobs.where((job) {
      if (job.status == JobStatuses.completed ||
          job.status == JobStatuses.cancelled) {
        return false;
      }
      return job.hasVisitOn(day);
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
    if (markRescheduled &&
        currentStatus != null &&
        JobStatuses.canMarkRescheduled(currentStatus)) {
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
      await saveVisits(id, byJob[id]!, defaultDuration: durationByJob[id] ?? 60);
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
        final sameModel = modelKey.isNotEmpty &&
            normalizeApplianceKey(appliance.model) == modelKey;
        final sameBrand =
            brandKey.isEmpty || normalizeApplianceKey(appliance.brand) == brandKey;
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
