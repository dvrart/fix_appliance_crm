import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/constants.dart';
import '../../../models/job.dart';
import '../../../services/services.dart';
import '../../../core/l10n/app_locale.dart';

/// Контроллер состояния для JobDetailsScreen
/// Вынесен отдельно, чтобы вкладки могли обращаться к общему состоянию
class JobDetailsController extends ChangeNotifier {
  final String jobId;
  final String clientId;
  final Map<String, dynamic> jobData;

  JobDetailsController({
    required this.jobId,
    required this.clientId,
    required this.jobData,
  }) {
    _initFromJobData();
    _listenJobDocuments();
    _loadTaxDefault();
    _calculateTravelTime();
    _loadClientEmail();
  }

  late bool needsReview;

  // Состояние
  late String currentStatus;
  late String currentPriority;
  late String currentDescription;
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
  bool _disposed = false;

  List<Map<String, dynamic>> attachments = [];
  bool isUploadingImage = false;

  String travelTime = '';
  bool isLoadingTime = true;

  String activeChatRole = 'client';
  String chatSendMethod = 'SMS';
  String clientEmail = '';

  DateTime? scheduledAt;
  int durationMinutes = 60;
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
      scheduledAt: _parseDate(data['scheduledAt']) ?? _parseDate(data['scheduledDate']),
      durationMinutes: (data['durationMinutes'] as num?)?.toInt() ?? durationMinutes,
    );
  }

  void _applyVisitFields(List<JobVisit> next) {
    visits = [...next]..sort((a, b) => a.startAt.compareTo(b.startAt));
    final synced = JobVisit.syncFields(visits, defaultDuration: durationMinutes);
    scheduledAt = synced['scheduledAt'] as DateTime?;
    durationMinutes = (synced['durationMinutes'] as int?) ?? durationMinutes;
  }

  void _initFromJobData() {
    currentStatus = jobData['status'] ?? 'Новая';
    currentPriority = jobData['priority'] ?? '🟢 Обычный';
    currentDescription = jobData['description'] ?? 'Нет описания';

    scheduledAt = _parseDate(jobData['scheduledAt']) ?? _parseDate(jobData['scheduledDate']);
    durationMinutes = (jobData['durationMinutes'] as num?)?.toInt() ?? 60;
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
    _jobSubscription = FirestoreService.jobsRef.doc(jobId).snapshots().listen((snap) {
      if (!snap.exists) return;
      final data = snap.data() as Map<String, dynamic>?;
      if (data == null) return;
      if (data['documents'] != null) {
        documents = List<Map<String, dynamic>>.from(
          (data['documents'] as List).map((e) => Map<String, dynamic>.from(e as Map)),
        );
      }
      needsReview = data['needsReview'] == true;
      currentStatus = data['status'] ?? currentStatus;
      durationMinutes = (data['durationMinutes'] as num?)?.toInt() ?? durationMinutes;
      packingNotes = data['packingNotes'] ?? packingNotes;
      trackingNumber = (data['trackingNumber'] ?? trackingNumber).toString();
      amazonOrderId = (data['amazonOrderId'] ?? amazonOrderId).toString();
      trackingStatus = (data['trackingStatus'] ?? trackingStatus).toString();
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
      jobData['hasJobSite'] = hasJobSite;
      jobData['jobSiteAddress'] = jobSiteAddress;
      if (data['attachments'] != null) {
        attachments = List<Map<String, dynamic>>.from(data['attachments']);
      }
      if (!_disposed) notifyListeners();
    });
  }

  Future<void> _loadTaxDefault() async {
    final config = await SettingsService.loadConfig();
    builderTaxRate = SettingsService.readDefaultTaxRate(config);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _jobSubscription?.cancel();
    super.dispose();
  }

  /// Адрес для навигации
  String get workAddress => hasJobSite
      ? jobSiteAddress
      : (jobData['clientAddress'] ?? 'Не указан'.tr);

  /// Контактное имя на месте
  String get contactName => hasJobSite
      ? jobSiteName
      : (jobData['clientName'] ?? 'Неизвестно'.tr);

  /// Контактный телефон
  String get contactPhone => hasJobSite
      ? jobSitePhone
      : (jobData['clientPhone'] ?? '');

  List<JobChatContact> get chatContacts {
    final client = JobChatContact(
      id: 'client',
      label: 'Клиент'.tr,
      name: (jobData['clientName'] ?? 'Клиент'.tr).toString().trim(),
      phone: (jobData['clientPhone'] ?? '').toString().trim(),
      email: clientEmail,
    );
    final site = JobChatContact(
      id: 'site',
      label: 'На объекте'.tr,
      name: jobSiteName.trim().isEmpty ? 'Контакт на адресе'.tr : jobSiteName.trim(),
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

  Future<void> _loadClientEmail() async {
    if (clientId.isEmpty) return;
    try {
      final client = await ClientService.getById(clientId);
      if (_disposed) return;
      clientEmail = (client?.email ?? '').trim();
      notifyListeners();
    } catch (_) {}
  }

  // === Методы обновления ===

  Future<void> markReviewed() async {
    needsReview = false;
    notifyListeners();
    await JobService.markReviewed(jobId);
  }

  Future<void> updateStatus(String status, {Map<String, dynamic>? extra}) async {
    currentStatus = status;
    notifyListeners();
    await JobService.updateStatus(jobId, status, extra: extra);
  }

  Future<void> updatePriority(String priority) async {
    currentPriority = priority;
    notifyListeners();
    await JobService.updatePriority(jobId, priority);
  }

  Future<void> updateDescription(String description) async {
    currentDescription = description;
    notifyListeners();
    await JobService.updateDescription(jobId, description);
  }

  /// Изменить дату/время ближайшего визита (или снять все визиты, если [newValue] == null)
  Future<void> updateScheduledAt(DateTime? newValue) async {
    if (newValue == null) {
      await saveVisits(const []);
      return;
    }
    if (visits.isEmpty) {
      await saveVisits([
        JobVisit.create(startAt: newValue, durationMinutes: durationMinutes),
      ]);
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

  Future<void> saveVisits(List<JobVisit> next, {bool markRescheduled = false}) async {
    _applyVisitFields(next);
    notifyListeners();
    await JobService.saveVisits(
      jobId,
      visits,
      defaultDuration: durationMinutes,
      markRescheduled: markRescheduled,
      currentStatus: currentStatus,
    );
  }

  Future<void> addVisit(JobVisit visit) => saveVisits([...visits, visit]);

  Future<void> updateVisit(JobVisit visit) {
    JobVisit? previous;
    for (final item in visits) {
      if (item.id == visit.id) {
        previous = item;
        break;
      }
    }
    final dayChanged = previous != null &&
        !JobVisit.isSameDay(previous.startAt, visit.startAt);
    return saveVisits(
      [
        for (final item in visits)
          item.id == visit.id
              ? (dayChanged ? visit.copyWith(clearSms: true) : visit)
              : item,
      ],
      markRescheduled: dayChanged,
    );
  }

  Future<void> removeVisit(String visitId) {
    return saveVisits(visits.where((v) => v.id != visitId).toList());
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
      await updateVisit(planned.first.copyWith(durationMinutes: durationMinutes));
      return;
    }
    notifyListeners();
    await JobService.update(jobId, {'durationMinutes': durationMinutes});
  }

  Future<void> updatePackingNotes(String notes) async {
    packingNotes = notes;
    notifyListeners();
    await JobService.update(jobId, {'packingNotes': notes});
  }

  Future<void> updateTracking({
    required String number,
    required String amazonId,
  }) async {
    trackingNumber = number.trim();
    amazonOrderId = amazonId.trim();
    notifyListeners();
    await JobService.update(jobId, {
      'trackingNumber': trackingNumber,
      'amazonOrderId': amazonOrderId,
      'trackingCarrier': amazonOrderId.isNotEmpty ? 'amazon' : 'other',
    });
  }

  Future<void> updateWorkAddress({
    required String street,
    required String city,
    required String postal,
  }) async {
    final full = [street, city, postal].where((s) => s.isNotEmpty).join(', ');
    if (hasJobSite) {
      jobSiteAddress = full;
      jobData['jobSiteAddress'] = full;
      notifyListeners();
      await JobService.update(jobId, {'jobSiteAddress': full});
    } else {
      jobData['clientAddress'] = full;
      notifyListeners();
      await JobService.update(jobId, {'clientAddress': full});
      if (clientId.isNotEmpty) {
        await ClientService.updateAddress(
          clientId,
          street: street,
          city: city,
          postal: postal,
        );
      }
    }
    isLoadingTime = true;
    notifyListeners();
    await _calculateTravelTime();
  }

  Future<void> saveDocuments() async {
    await JobService.updateDocuments(jobId, documents);
  }

  void setFinanceMode(String mode) {
    financeMode = mode;
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
      await WarehouseService.applyDocumentStock(documents[index], reverse: true);
      documents.removeAt(index);
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

  double calcSubtotal(List<dynamic> items) {
    double total = 0;
    for (var item in items) {
      final qty = (item['qty'] ?? 1).toDouble();
      final price = (item['price'] ?? 0).toDouble();
      total += qty * price;
    }
    return total;
  }

  double calcTax(double subtotal, double rate) {
    return subtotal * rate;
  }

  double calcTotal(double subtotal, double tax) {
    return subtotal + tax;
  }

  double calcPaid(List<dynamic> payments) {
    double total = 0;
    for (var p in payments) {
      total += (p['amount'] ?? 0).toDouble();
    }
    return total;
  }

  double calcDue(double total, double paid) {
    return (total - paid).clamp(0, double.infinity);
  }

  Color getPriorityColor() {
    if (currentPriority.contains('Срочн') || currentPriority.contains('🔴')) {
      return Colors.red;
    }
    if (currentPriority.contains('Средн') || currentPriority.contains('🟡')) {
      return Colors.orange;
    }
    return Colors.green;
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
