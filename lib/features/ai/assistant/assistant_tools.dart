import 'package:intl/intl.dart';

import '../../../core/constants.dart';
import '../../../core/utils/formatters.dart';
import '../../../models/job.dart';
import '../../../services/app_time_service.dart';
import '../../../services/client_service.dart';
import '../../../services/job_service.dart';
import '../../../services/message_translate_service.dart';
import '../../../services/service_guide_service.dart';
import '../../../services/settings_service.dart';
import '../../../services/sms_service.dart';
import 'assistant_actions.dart';

class AssistantTools {
  static Map<String, dynamic> _jobSummary(Job job, {bool detailed = false}) {
    final summary = <String, dynamic>{
      'id': job.id,
      'client_id': job.clientId,
      'client_name': job.clientName,
      'phone': job.contactPhone,
      'address': job.workAddress,
      'city': job.city ?? '',
      'appliance': '${job.applianceType} ${job.applianceBrand}'.trim(),
      'problem': job.description,
      'status': job.status,
      'priority': job.priority,
      'scheduled_at': job.scheduledAt?.toIso8601String(),
      'needs_review': job.needsReview,
    };
    if (!detailed) return summary;
    return {
      ...summary,
      'contact_name': job.contactName,
      'packing_notes': job.packingNotes,
      'tracking': {
        'number': job.trackingNumber,
        'carrier': job.trackingCarrier,
        'status': job.trackingStatus,
      },
      'appliances': job.appliances
          .map(
            (item) => {
              'type': item.type,
              'brand': item.brand,
              'model': item.model,
              'serial': item.serialNumber,
              'issue': item.issue,
            },
          )
          .toList(),
      'visits': job.coalescedVisits
          .map(
            (visit) => {
              'start': visit.startAt.toIso8601String(),
              'outcome': visit.outcome,
              'confirm': visit.smsConfirmStatus,
              'note': visit.note,
            },
          )
          .toList(),
      'documents': job.documents.take(8).map((doc) {
        return {
          'type': '${doc['type'] ?? doc['kind'] ?? ''}',
          'number': '${doc['number'] ?? doc['docNumber'] ?? ''}',
          'total': doc['total'],
          'status': '${doc['status'] ?? ''}',
        };
      }).toList(),
    };
  }

  static Future<Job?> resolveJob(String? query, {bool includeClosed = false}) async {
    final jobs = await JobService.loadAllOnce();
    final pool = includeClosed
        ? jobs
        : jobs.where((j) => !JobStatuses.isClosed(j.status)).toList();

    final q = (query ?? '').trim().toLowerCase();
    if (q.isEmpty ||
        q.contains('следующ') ||
        q.contains('ближайш') ||
        q == 'next') {
      final now = DateTime.now();
      final upcoming = pool
          .where((j) => j.scheduledAt != null && !j.scheduledAt!.isBefore(now))
          .toList()
        ..sort((a, b) => a.scheduledAt!.compareTo(b.scheduledAt!));
      if (upcoming.isNotEmpty) return upcoming.first;

      final today = pool.where((j) {
        final d = j.scheduledAt;
        return d != null &&
            d.year == now.year &&
            d.month == now.month &&
            d.day == now.day;
      }).toList()
        ..sort((a, b) => (a.scheduledAt ?? a.createdAt)
            .compareTo(b.scheduledAt ?? b.createdAt));
      if (today.isNotEmpty) return today.first;
      if (pool.isNotEmpty) {
        pool.sort((a, b) => (a.scheduledAt ?? a.createdAt)
            .compareTo(b.scheduledAt ?? b.createdAt));
        return pool.first;
      }
      return null;
    }

    final digits = q.replaceAll(RegExp(r'\D'), '');
    for (final job in pool) {
      if (job.id == query) return job;
      final haystack = [
        job.clientName,
        job.contactName,
        job.applianceType,
        job.applianceBrand,
        job.description,
        job.workAddress,
        job.contactPhone,
      ].join(' ').toLowerCase();
      if (haystack.contains(q)) return job;
      if (digits.length >= 4 &&
          ClientService.normalizePhone(job.contactPhone).contains(digits)) {
        return job;
      }
    }
    return null;
  }

  static Future<Map<String, dynamic>> handle(
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'list_jobs':
        return _listJobs(args);
      case 'get_job':
        return _getJob(args);
      case 'send_sms':
        return _sendSms(args);
      case 'reschedule_visit':
        return _rescheduleVisit(args);
      case 'create_job':
        return _createJob(args);
      case 'search_clients':
        return _searchClients(args);
      case 'lookup_service_guide':
        return ServiceGuideService.lookup(
          query: (args['query'] as String?) ?? '',
          brand: (args['brand'] as String?) ?? '',
          appliance: (args['appliance'] as String?) ?? '',
          code: (args['code'] as String?) ?? '',
          kind: (args['kind'] as String?) ?? '',
        );
      case 'open_job':
        return _openJob(args);
      case 'open_client':
        return _openClient(args);
      case 'open_route':
        AssistantActions.enqueue(const AssistantUiAction(type: 'open_route'));
        return {'ok': true, 'opened': 'route'};
      case 'navigate_to_job':
        return _navigateToJob(args);
      case 'call_client':
        return _callClient(args);
      case 'write_client':
        return _writeClient(args);
      case 'update_settings':
        return AssistantSettingsApply.apply(args);
      case 'open_settings':
        AssistantActions.enqueue(const AssistantUiAction(type: 'open_settings'));
        return {'ok': true, 'opened': 'settings'};
      default:
        return {'error': 'Неизвестная функция $name'};
    }
  }

  static Future<Map<String, dynamic>> _listJobs(Map<String, dynamic> args) async {
    final jobs = await JobService.loadAllOnce();
    final now = DateTime.now();
    final when = (args['when'] as String?)?.toLowerCase() ?? '';
    final includeClosed = when == 'all' || when == 'closed';
    var list = includeClosed
        ? [...jobs]
        : jobs.where((j) => !JobStatuses.isClosed(j.status)).toList();

    if (when == 'today') {
      list = list.where((j) {
        final d = j.scheduledAt;
        return d != null &&
            d.year == now.year &&
            d.month == now.month &&
            d.day == now.day;
      }).toList();
    } else if (when == 'upcoming') {
      list = list
          .where((j) => j.scheduledAt != null && !j.scheduledAt!.isBefore(now))
          .toList();
    } else if (when == 'closed') {
      list = jobs.where((j) => JobStatuses.isClosed(j.status)).toList();
    }

    list.sort((a, b) => (a.scheduledAt ?? a.createdAt)
        .compareTo(b.scheduledAt ?? b.createdAt));
    final limited = list.take(24).map(_jobSummary).toList();
    return {
      'count': limited.length,
      'jobs': limited,
      'now': DateFormat('yyyy-MM-dd HH:mm').format(now),
    };
  }

  static Future<Map<String, dynamic>> _getJob(Map<String, dynamic> args) async {
    final job = await resolveJob(
      args['query'] as String?,
      includeClosed: true,
    );
    if (job == null) {
      return {'found': false, 'message': 'Заявка не найдена'};
    }
    return {'found': true, 'job': _jobSummary(job, detailed: true)};
  }

  static Future<Map<String, dynamic>> _sendSms(Map<String, dynamic> args) async {
    var job = await resolveJob(
      args['job_query'] as String?,
      includeClosed: true,
    );
    if (job == null) {
      job = await resolveJob(args['query'] as String?, includeClosed: true);
    }
    if (job == null) {
      return {'ok': false, 'error': 'Не нашёл, кому отправлять SMS'};
    }
    final phone = job.contactPhone;
    if (phone.trim().isEmpty) {
      return {'ok': false, 'error': 'У заявки нет телефона'};
    }

    final templates = await SettingsService.loadSmsTemplates();
    final rawTemplate = (args['template'] as String?) ?? 'on_way';
    final templateKey = switch (rawTemplate) {
      'parts' || 'part_ordered' => 'part_ordered',
      'done' || 'job_done' => 'job_done',
      _ => 'on_way',
    };
    var body = (args['text'] as String?)?.trim() ?? '';
    if (body.isEmpty) {
      body = templates[templateKey]?.trim() ??
          templates['on_way'] ??
          'Hello, this is your technician. I am on my way.';
    }
    final russian = MessageTranslateService.looksRussian(body) ? body : '';
    if (russian.isNotEmpty) {
      body = await MessageTranslateService.toEnglish(body);
    }

    final ok = await SmsService.sendSms(
      to: phone,
      body: body,
      clientId: job.clientId,
      bodyRu: russian.isEmpty ? null : russian,
    );
    if (ok) {
      await JobService.sendMessage(
        jobId: job.id,
        text: body,
        targetRole: job.hasJobSite ? 'Арендатор' : 'Владелец',
        sender: 'company',
      );
    }
    return {
      'ok': ok,
      'client_name': job.clientName,
      'phone': phone,
      'text': body,
    };
  }

  static DateTime? _parseVisitSlot(String date, String time) {
    final parsedTime = _parseClock(time);
    if (parsedTime == null) return null;
    final parsedDate = _parseDay(date);
    if (parsedDate == null) return null;
    return AppTimeService.atWall(
      parsedDate.year,
      parsedDate.month,
      parsedDate.day,
      parsedTime.$1,
      parsedTime.$2,
    );
  }

  static (int, int)? _parseClock(String raw) {
    final t = raw.trim().toLowerCase();
    if (t == 'noon' || t == 'полдень') return (12, 0);
    if (t == 'midnight' || t == 'полночь') return (0, 0);
    final hm = RegExp(r'^(\d{1,2})(?:[:.](\d{2}))?(?:\s*(am|pm))?$').firstMatch(t);
    if (hm == null) return null;
    var hour = int.parse(hm[1]!);
    final minute = int.parse(hm[2] ?? '0');
    final ampm = hm[3];
    if (ampm == 'pm' && hour < 12) hour += 12;
    if (ampm == 'am' && hour == 12) hour = 0;
    if (hour > 23 || minute > 59) return null;
    return (hour, minute);
  }

  static DateTime? _parseDay(String raw) {
    final t = raw.trim().toLowerCase();
    final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(t);
    if (iso != null) {
      return DateTime(
        int.parse(iso[1]!),
        int.parse(iso[2]!),
        int.parse(iso[3]!),
      );
    }
    final dmy = RegExp(r'^(\d{1,2})[./](\d{1,2})[./](\d{2,4})$').firstMatch(t);
    if (dmy != null) {
      var year = int.parse(dmy[3]!);
      if (year < 100) year += 2000;
      return DateTime(year, int.parse(dmy[2]!), int.parse(dmy[1]!));
    }
    const weekdays = <String, int>{
      'monday': DateTime.monday,
      'tuesday': DateTime.tuesday,
      'wednesday': DateTime.wednesday,
      'thursday': DateTime.thursday,
      'friday': DateTime.friday,
      'saturday': DateTime.saturday,
      'sunday': DateTime.sunday,
      'понедельник': DateTime.monday,
      'вторник': DateTime.tuesday,
      'среда': DateTime.wednesday,
      'среду': DateTime.wednesday,
      'четверг': DateTime.thursday,
      'пятница': DateTime.friday,
      'пятницу': DateTime.friday,
      'суббота': DateTime.saturday,
      'субботу': DateTime.saturday,
      'воскресенье': DateTime.sunday,
    };
    final now = AppTimeService.nowInZone();
    if (t.contains('today') || t == 'сегодня') {
      return DateTime(now.year, now.month, now.day);
    }
    if (t.contains('tomorrow') || t == 'завтра') {
      final next = now.add(const Duration(days: 1));
      return DateTime(next.year, next.month, next.day);
    }
    for (final entry in weekdays.entries) {
      if (!t.contains(entry.key)) continue;
      final forceNext = t.contains('next') || t.contains('следующ');
      var days = (entry.value - now.weekday + 7) % 7;
      if (days == 0 && forceNext) days = 7;
      final next = now.add(Duration(days: days));
      return DateTime(next.year, next.month, next.day);
    }
    return DateTime.tryParse(t);
  }

  static Future<Map<String, dynamic>> _rescheduleVisit(
    Map<String, dynamic> args,
  ) async {
    final job = await resolveJob(args['job_query'] as String?);
    if (job == null) {
      return {'ok': false, 'error': 'Заявка не найдена'};
    }
    final next = _parseVisitSlot(
      (args['date'] as String?) ?? '',
      (args['time'] as String?) ?? '',
    );
    if (next == null) {
      return {'ok': false, 'error': 'Нужны date=YYYY-MM-DD и time=HH:mm'};
    }
    final visits = [...job.coalescedVisits];
    final now = DateTime.now();
    final idx = visits.indexWhere(
      (visit) => visit.isScheduled && !visit.startAt.isBefore(now),
    );
    if (idx >= 0) {
      visits[idx] = visits[idx].copyWith(
        startAt: next,
        smsConfirmStatus: JobVisit.confirmPending,
        smsDialog: '',
      );
    } else if (visits.isNotEmpty) {
      visits[0] = visits[0].copyWith(
        startAt: next,
        smsConfirmStatus: JobVisit.confirmPending,
        smsDialog: '',
      );
    } else {
      visits.add(JobVisit.create(startAt: next));
    }
    await JobService.update(job.id, {
      ...JobVisit.syncFields(visits, defaultDuration: job.durationMinutes),
      'status': JobStatuses.call,
    });
    final when = DateFormat('yyyy-MM-dd HH:mm').format(next);
    return {
      'ok': true,
      'client_name': job.clientName,
      'scheduled_at': when,
      'date': Formatters.formatDateEn(next),
      'time': Formatters.formatTime(next),
    };
  }

  static Future<Map<String, dynamic>> _createJob(Map<String, dynamic> args) async {
    final name = (args['client_name'] as String?)?.trim() ?? '';
    final phone = (args['client_phone'] as String?)?.trim() ?? '';
    final address = (args['address'] as String?)?.trim() ?? '';
    final city = (args['city'] as String?)?.trim() ?? '';
    final appliance = (args['appliance_type'] as String?)?.trim() ?? 'Техника';
    final brand = (args['brand'] as String?)?.trim() ?? '';
    final problem = (args['problem'] as String?)?.trim() ?? '';
    if (name.isEmpty && phone.isEmpty) {
      return {'ok': false, 'error': 'Нужны имя или телефон клиента'};
    }

    var clientId = '';
    final email = (args['email'] as String?)?.trim() ??
        (args['client_email'] as String?)?.trim() ??
        '';
    final existing = await ClientService.findExisting(phone: phone, email: email);
    clientId = existing?.id ?? '';
    if (clientId.isEmpty) {
      clientId = await ClientService.createOrUpdate(
        fullName: name.isEmpty ? 'Клиент' : name,
        phone: phone,
        address: [address, city].where((s) => s.isNotEmpty).join(', '),
        email: email.contains('@') ? email : existing?.email,
      );
    }

    DateTime scheduledAt = DateTime.now().add(const Duration(hours: 1));
    final dateStr = args['scheduled_date'] as String?;
    final timeStr = args['scheduled_time'] as String?;
    if (dateStr != null && dateStr.isNotEmpty) {
      final parsed = DateTime.tryParse(dateStr);
      if (parsed != null) {
        var hour = 9;
        var minute = 0;
        if (timeStr != null && timeStr.contains(':')) {
          final parts = timeStr.split(':');
          hour = int.tryParse(parts[0]) ?? 9;
          minute = int.tryParse(parts[1]) ?? 0;
        }
        scheduledAt = DateTime(parsed.year, parsed.month, parsed.day, hour, minute);
      }
    }

    final job = Job(
      id: '',
      clientId: clientId,
      clientName: name.isEmpty ? 'Клиент' : name,
      clientPhone: phone,
      clientAddress: [address, city].where((s) => s.isNotEmpty).join(', '),
      appliances: [
        JobAppliance(type: appliance, brand: brand, issue: problem),
      ],
      description: problem,
      status: JobStatuses.call,
      scheduledAt: scheduledAt,
      createdAt: DateTime.now(),
      city: city,
      needsReview: false,
    );
    final jobId = await JobService.create(job);
    final created = await JobService.getById(jobId);
    if (created != null) {
      AssistantActions.queueOpenJob(created);
    }
    return {
      'ok': true,
      'job_id': jobId,
      'client_name': job.clientName,
      'scheduled_at': scheduledAt.toIso8601String(),
      'opened': true,
    };
  }

  static Future<Map<String, dynamic>> _searchClients(
    Map<String, dynamic> args,
  ) async {
    final query = (args['query'] as String?) ?? '';
    final clients = await ClientService.search(query);
    return {
      'count': clients.length,
      'clients': clients
          .map(
            (c) => {
              'id': c.id,
              'name': c.fullName,
              'phone': c.phone,
              'email': c.email ?? '',
              'address': c.address,
              'notes': c.notes ?? '',
              'company': c.companyName ?? '',
            },
          )
          .toList(),
    };
  }

  static Future<Map<String, dynamic>> _openJob(Map<String, dynamic> args) async {
    final job = await resolveJob(
      args['query'] as String?,
      includeClosed: true,
    );
    if (job == null) {
      return {'ok': false, 'error': 'Заявка не найдена'};
    }
    AssistantActions.queueOpenJob(job);
    return {'ok': true, 'opened': true, 'job': _jobSummary(job)};
  }

  static Future<Map<String, dynamic>> _openClient(Map<String, dynamic> args) async {
    final query = (args['query'] as String?) ?? '';
    var client = await ClientService.search(query).then(
      (list) => list.isEmpty ? null : list.first,
    );
    if (client == null) {
      final job = await resolveJob(query, includeClosed: true);
      if (job != null && job.clientId.isNotEmpty) {
        client = await ClientService.getById(job.clientId);
      }
    }
    if (client == null) {
      return {'ok': false, 'error': 'Клиент не найден'};
    }
    AssistantActions.enqueue(
      AssistantUiAction(
        type: 'open_client',
        payload: {'client_id': client.id},
      ),
    );
    return {
      'ok': true,
      'opened': true,
      'client': {'id': client.id, 'name': client.fullName, 'phone': client.phone},
    };
  }

  static Future<Map<String, dynamic>> _navigateToJob(Map<String, dynamic> args) async {
    final job = await resolveJob(args['query'] as String?, includeClosed: true);
    if (job == null || job.workAddress.trim().isEmpty) {
      return {'ok': false, 'error': 'Нет адреса для навигации'};
    }
    AssistantActions.enqueue(
      AssistantUiAction(
        type: 'navigate',
        payload: {'address': job.workAddress},
      ),
    );
    return {'ok': true, 'address': job.workAddress, 'client_name': job.clientName};
  }

  static Future<Map<String, dynamic>> _callClient(Map<String, dynamic> args) async {
    final job = await resolveJob(args['query'] as String?, includeClosed: true);
    final phone = (args['phone'] as String?)?.trim().isNotEmpty == true
        ? (args['phone'] as String).trim()
        : (job?.contactPhone ?? '');
    if (phone.isEmpty) {
      return {'ok': false, 'error': 'Нет телефона'};
    }
    AssistantActions.enqueue(
      AssistantUiAction(
        type: 'call_client',
        payload: {
          'phone': phone,
          'name': job?.contactName ?? args['query'],
          'job_id': job?.id,
        },
      ),
    );
    return {'ok': true, 'calling': phone, 'client_name': job?.clientName};
  }

  static Future<Map<String, dynamic>> _writeClient(Map<String, dynamic> args) async {
    final job = await resolveJob(args['query'] as String?, includeClosed: true);
    var client = job == null || job.clientId.isEmpty
        ? null
        : await ClientService.getById(job.clientId);
    if (client == null) {
      final found = await ClientService.search((args['query'] as String?) ?? '');
      client = found.isEmpty ? null : found.first;
    }
    final phone = job?.contactPhone ?? client?.phone ?? '';
    final email = client?.email;
    if (phone.trim().isEmpty && (email == null || !email.contains('@'))) {
      return {'ok': false, 'error': 'Нет телефона или email'};
    }
    AssistantActions.enqueue(
      AssistantUiAction(
        type: 'open_conversation',
        payload: {
          'phone': phone,
          'email': email,
          'name': job?.contactName ?? client?.fullName,
          'client_id': job?.clientId ?? client?.id,
        },
      ),
    );
    return {'ok': true, 'opened': 'conversation'};
  }
}

/// Parse a spoken command so the app still acts if Gemini only talks.
class AssistantIntents {
  static const mutating = {
    'send_sms',
    'open_job',
    'open_client',
    'call_client',
    'write_client',
    'open_route',
    'navigate_to_job',
    'reschedule_visit',
    'create_job',
    'open_settings',
  };

  static ({String name, Map<String, dynamic> args})? parse(String raw) {
    final t = raw.trim().toLowerCase();
    if (t.length < 4) return null;

    final query = _queryOf(t);

    if (_has(t, ['экран', 'screen']) &&
        _has(t, [
          'что',
          'посмотри',
          'смотри',
          'look',
          'видиш',
          'видишь',
          'открыто',
          'тут',
          'здесь',
        ])) {
      return (name: 'look_at_screen', args: {});
    }
    if (_has(t, ['посмотри', 'смотри', 'look at']) &&
        _has(t, ['сюда', 'тут', 'здесь', 'это', 'this', 'here'])) {
      return (name: 'look_at_screen', args: {});
    }
    if (_has(t, ['открой', 'открыть', 'open']) &&
        _has(t, ['клиент', 'client'])) {
      return (name: 'open_client', args: {'query': query});
    }
    if (_has(t, ['открой', 'открыть', 'open']) &&
        _has(t, ['заявк', 'карточк', 'работ', 'job', 'card'])) {
      return (name: 'open_job', args: {'query': query});
    }
    if (_has(t, ['позвон', 'набер', 'call'])) {
      return (name: 'call_client', args: {'query': query});
    }
    if (_has(t, ['маршрут', 'route', 'навигац', 'навигатор', 'maps'])) {
      if (_has(t, ['пролож', 'открой', 'open', 'построй', 'веди', 'навиг'])) {
        return (name: 'open_route', args: {});
      }
    }
    if (_has(t, ['смс', 'sms', 'сообщен', 'text', 'напиш']) &&
        _has(t, ['отправ', 'send', 'напиш', 'пути', 'way', 'ехал', 'еду'])) {
      return (
        name: 'send_sms',
        args: {
          'job_query': query,
          'template': 'on_way',
        },
      );
    }
    return null;
  }

  static bool _has(String text, List<String> needles) {
    for (final n in needles) {
      if (text.contains(n)) return true;
    }
    return false;
  }

  static String _queryOf(String t) {
    final cleaned = t
        .replaceAll(
          RegExp(
            r'\b(открой|открыть|open|пожалуйста|please|карточку|карточк[ауие]?|заявк[уиеа]?|клиента?|client|job|card|отправь|отправить|send|смс|sms|позвони|позвонить|call|что|я|в|пути|the|a)\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.length < 2) return 'next';
    return cleaned;
  }
}
