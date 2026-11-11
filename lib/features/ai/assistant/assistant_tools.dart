import 'dart:async';

import 'package:intl/intl.dart';

import '../../../core/constants.dart';
import '../../../core/sms_text.dart';
import '../../../core/utils/formatters.dart';
import '../../../models/job.dart';
import '../../../services/app_time_service.dart';
import '../../../services/care_plan_service.dart';
import '../../../services/client_service.dart';
import '../../../services/job_service.dart';
import '../../../services/message_translate_service.dart';
import '../../../services/part_search_service.dart';
import '../../../services/service_guide_service.dart';
import '../../../services/settings_service.dart';
import '../../../services/sms_service.dart';
import '../../../shared/app_nav.dart';
import '../../diagnostics/diagnostics_screen.dart';
import '../../messages/conversation_screen.dart';
import 'assistant_actions.dart';

class AssistantTools {
  static Map<String, dynamic> _jobSummary(
    Job job, {
    bool detailed = false,
    JobVisit? visit,
    DateTime? now,
  }) {
    final instant = (now ?? DateTime.now()).toUtc();
    final scheduledVisit = visit ?? job.nextActiveVisit(now: instant);
    final summary = <String, dynamic>{
      'id': job.id,
      'client_id': job.clientId,
      'client_name': job.clientName,
      'client_phone': job.clientPhone,
      'phone': job.contactPhone,
      'address': job.workAddress,
      'client_address': job.clientAddress,
      if (job.hasJobSite) 'has_job_site': true,
      if ((job.jobSiteAddress ?? '').trim().isNotEmpty)
        'job_site_address': job.jobSiteAddress,
      if ((job.jobSiteName ?? '').trim().isNotEmpty)
        'job_site_name': job.jobSiteName,
      if ((job.jobSitePhone ?? '').trim().isNotEmpty)
        'job_site_phone': job.jobSitePhone,
      'city': job.city ?? '',
      'appliance': '${job.applianceType} ${job.applianceBrand}'.trim(),
      'problem': job.description,
      'status': job.status,
      'priority': job.priority,
      'scheduled_at': scheduledVisit?.startAt.toUtc().toIso8601String(),
      'scheduled_visit_is_upcoming':
          scheduledVisit != null && scheduledVisit.endAt.toUtc().isAfter(instant),
      'needs_review': job.needsReview,
    };
    if (!detailed) return summary;
    final upcomingVisitIds = job.activeVisits
        .where((visit) => visit.endAt.toUtc().isAfter(instant))
        .map((visit) => visit.id)
        .toSet();
    return {
      ...summary,
      'contact_name': job.contactName,
      if (job.solution.trim().isNotEmpty) 'solution': job.solution,
      if (job.expectedParts.isNotEmpty) 'expected_parts': job.expectedParts,
      'packing_notes': job.packingNotes,
      'tracking': {
        'number': job.trackingNumber,
        'carrier': job.trackingCarrier,
        'part': job.trackingPart,
        'status': job.trackingStatus,
        'orders': [
          for (final order in job.trackingOrders) order.toMap(),
        ],
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
      'visit_history': job.coalescedVisits
          .map(
            (visit) => {
              'start': visit.startAt.toUtc().toIso8601String(),
              'is_upcoming': upcomingVisitIds.contains(visit.id),
              'outcome': visit.outcome,
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

  static bool _isNextKeyword(String q) =>
      q == 'next' ||
      q == 'следующая' ||
      q == 'следующий' ||
      q == 'следующему' ||
      q == 'ближайшая' ||
      q == 'ближайший' ||
      q == 'ближайшему' ||
      q.contains('следующ') ||
      q.contains('ближайш');

  static bool _isCurrentScreenKeyword(String q) {
    final clean = q.trim().toLowerCase();
    return clean == 'current' ||
        clean == 'open' ||
        clean == 'screen' ||
        clean == 'chat' ||
        clean == 'this' ||
        clean == 'here' ||
        clean == 'this client' ||
        clean == 'current chat' ||
        clean == 'open chat' ||
        clean == 'текущая' ||
        clean == 'текущий' ||
        clean == 'текущему' ||
        clean == 'открытая' ||
        clean == 'открытый' ||
        clean == 'открытому' ||
        clean == 'открытый чат' ||
        clean == 'открытая переписка' ||
        clean == 'этот клиент' ||
        clean == 'этому клиенту' ||
        clean == 'сюда' ||
        clean == 'в этот чат' ||
        clean == 'эта' ||
        clean == 'эту' ||
        clean == 'этой' ||
        clean == 'этого' ||
        clean == 'этому';
  }

  static Future<Job?> _resolveOpenScreenJob(List<Job> jobs) async {
    final activeChat = ConversationScreen.activeTarget;
    if (activeChat != null) {
      final jid = (activeChat.jobId ?? '').trim();
      if (jid.isNotEmpty) {
        for (final job in jobs) {
          if (job.id == jid) return job;
        }
        final fetched = await JobService.getById(jid);
        if (fetched != null) return fetched;
      }
      final digits = ClientService.normalizePhone(activeChat.phone);
      if (digits.length >= 10) {
        for (final job in jobs) {
          if (!JobStatuses.isClosed(job.status) &&
              (ClientService.normalizePhone(job.contactPhone) == digits ||
                  ClientService.normalizePhone(job.clientPhone) == digits)) {
            return job;
          }
        }
        for (final job in jobs) {
          if (ClientService.normalizePhone(job.contactPhone) == digits ||
              ClientService.normalizePhone(job.clientPhone) == digits) {
            return job;
          }
        }
      }
    }

    final key = AppNav.topCardKey;
    if (key == null || key.isEmpty) return null;
    if (key.startsWith('card:job:')) {
      final jobId = key.substring('card:job:'.length).trim();
      for (final job in jobs) {
        if (job.id == jobId) return job;
      }
      return JobService.getById(jobId);
    }
    final jobMarker = key.indexOf(':job:');
    if (jobMarker >= 0) {
      final jobId = key.substring(jobMarker + 5).trim();
      for (final job in jobs) {
        if (job.id == jobId) return job;
      }
      return JobService.getById(jobId);
    }
    if (key.startsWith('card:client:')) {
      final clientId = key.substring('card:client:'.length).trim();
      for (final job in jobs) {
        if (job.clientId == clientId && !JobStatuses.isClosed(job.status)) {
          return job;
        }
      }
      for (final job in jobs) {
        if (job.clientId == clientId) return job;
      }
    }
    if (key.startsWith('card:chat:')) {
      final rest = key.substring('card:chat:'.length).trim();
      final digits = ClientService.normalizePhone(rest);
      if (digits.length >= 10) {
        for (final job in jobs) {
          if (!JobStatuses.isClosed(job.status) &&
              (ClientService.normalizePhone(job.contactPhone) == digits ||
                  ClientService.normalizePhone(job.clientPhone) == digits)) {
            return job;
          }
        }
        for (final job in jobs) {
          if (ClientService.normalizePhone(job.contactPhone) == digits ||
              ClientService.normalizePhone(job.clientPhone) == digits) {
            return job;
          }
        }
      }
    }
    return null;
  }

  /// Приводит русское или английское имя/слово к единому фонетическому виду
  /// латиницей, чтобы «Майклу» находило «Michael», «Джону» — «John»,
  /// «Брэнтфорд» — «Brantford» и т.д.
  static String _phonetic(String input) {
    var s = input.toLowerCase().trim();
    if (s.isEmpty) return '';
    const aliases = <String, String>{
      'майкл': 'michael',
      'майк': 'mike',
      'джон': 'john',
      'джони': 'johnny',
      'джонатан': 'jonathan',
      'сара': 'sarah',
      'кud': 'kyle',
      'кайл': 'kyle',
      'дэвид': 'david',
      'дейв': 'dave',
      'дэйв': 'dave',
      'алекс': 'alex',
      'александр': 'alexander',
      'стивен': 'steven',
      'стив': 'steve',
      'роберт': 'robert',
      'боб': 'bob',
      'уильям': 'william',
      'билл': 'bill',
      'джеймс': 'james',
      'джим': 'jim',
      'ричард': 'richard',
      'рик': 'rick',
      'чарльз': 'charles',
      'чарли': 'charlie',
      'джозеф': 'joseph',
      'джо': 'joe',
      'томас': 'thomas',
      'том': 'tom',
      'кристофер': 'christopher',
      'крис': 'chris',
      'дэниел': 'daniel',
      'даниэль': 'daniel',
      'дэн': 'dan',
      'пол': 'paul',
      'марк': 'mark',
      'дональд': 'donald',
      'джордж': 'george',
      'кеннет': 'kenneth',
      'стивeн': 'steven',
      'эдвард': 'edward',
      'брайан': 'brian',
      'рональд': 'ronald',
      'энтони': 'anthony',
      'кевин': 'kevin',
      'джейсон': 'jason',
      'мэттью': 'matthew',
      'мэтт': 'matt',
      'гэри': 'gary',
      'тимоти': 'timothy',
      'тим': 'tim',
      'фpэнк': 'frank',
      'фрэнк': 'frank',
      'скотт': 'scott',
      'эрик': 'eric',
      'эндрю': 'andrew',
      'энди': 'andy',
      'реймонд': 'raymond',
      'грегори': 'gregory',
      'грег': 'greg',
      'джошуа': 'joshua',
      'джош': 'josh',
      'жерри': 'jerry',
      'джерри': 'jerry',
      'деннис': 'dennis',
      'уолтер': 'walter',
      'патрик': 'patrick',
      'питер': 'peter',
      'пит': 'pete',
      'гарольд': 'harold',
      'дуглас': 'douglas',
      'генри': 'henry',
      'карл': 'carl',
      'артур': 'arthur',
      'райан': 'ryan',
      'роджер': 'roger',
      'тейлор': 'taylor',
      'мэри': 'mary',
      'патриция': 'patricia',
      'дженнифер': 'jennifer',
      'линда': 'linda',
      'элизабет': 'elizabeth',
      'лиза': 'lisa',
      'барбара': 'barbara',
      'сьюзан': 'susan',
      'сью': 'sue',
      'джессика': 'jessica',
      'карен': 'karen',
      'нэнси': 'nancy',
      'маргарет': 'margaret',
      'сандра': 'sandra',
      'эшли': 'ashley',
      'дороти': 'dorothy',
      'кимберли': 'kimberly',
      'эмили': 'emily',
      'донна': 'donna',
      'мишель': 'michelle',
      'кэрол': 'carol',
      'аманда': 'amanda',
      'мелисса': 'melissa',
      'дебора': 'deborah',
      'стефани': 'stephanie',
      'ребекка': 'rebecca',
      'лора': 'laura',
      'шэрон': 'sharon',
      'синтия': 'cynthia',
      'кэтлин': 'kathleen',
      'эми': 'amy',
      'анна': 'anna',
      'энн': 'anne',
      'хелен': 'helen',
      'кэтрин': 'katherine',
      'кристина': 'christine',
      'рейчел': 'rachel',
      'джанет': 'janet',
      'мария': 'maria',
      'хезер': 'heather',
      'диана': 'diana',
      'джули': 'julie',
      'джойс': 'joyce',
      'виктория': 'victoria',
      'келли': 'kelly',
      'николь': 'nicole',
      'лорен': 'lauren',
      'меган': 'megan',
      'хани': 'hani',
      'смит': 'smith',
      'джонсон': 'johnson',
      'уильямс': 'williams',
      'браун': 'brown',
      'джонс': 'jones',
      'миллер': 'miller',
      'дэвис': 'davis',
      'уилсон': 'wilson',
      'андерсон': 'anderson',
      'мартин': 'martin',
      'томпсон': 'thompson',
      'уайт': 'white',
      'харрис': 'harris',
      'кларк': 'clark',
      'льюис': 'lewis',
      'робинсон': 'robinson',
      'уокер': 'walker',
      'янг': 'young',
      'кинг': 'king',
      'райт': 'wright',
      'грин': 'green',
      'бейкер': 'baker',
      'адамс': 'adams',
      'нельсон': 'nelson',
      'хилл': 'hill',
      'кэмпбелл': 'campbell',
      'митчелл': 'mitchell',
      'робертс': 'roberts',
      'картер': 'carter',
      'филлипс': 'phillips',
      'эванс': 'evans',
      'тернер': 'turner',
      'паркер': 'parker',
      'коллинз': 'collins',
      'эдвардс': 'edwards',
      'стюарт': 'stewart',
      'моррис': 'morris',
      'мерфи': 'murphy',
      'кук': 'cook',
      'роджерс': 'rogers',
      'морган': 'morgan',
      'купер': 'cooper',
      'рид': 'reed',
      'бейли': 'bailey',
      'белл': 'bell',
      'холланд': 'holland',
      'малиновски': 'malinouski',
      'малиновский': 'malinouski',
      'ратбоун': 'rathbone',
      'брэнфорд': 'brantford',
      'брэнтфорд': 'brantford',
      'брантфорд': 'brantford',
      'гамильтон': 'hamilton',
      'хамильтон': 'hamilton',
      'кембридж': 'cambridge',
      'китченер': 'kitchener',
      'ватерлоо': 'waterloo',
      'уотерлу': 'waterloo',
      'гвелф': 'guelph',
      'гуэлф': 'guelph',
      'вудсток': 'woodstock',
      'симко': 'simcoe',
      'берлингтон': 'burlington',
      'оквилл': 'oakville',
      'анкастер': 'ancaster',
      'дандас': 'dundas',
      'каледония': 'caledonia',
      'парис': 'paris',
      'пэрис': 'paris',
      'делхай': 'delhi',
      'ингерсолл': 'ingersoll',
      'тилсонбург': 'tillsonburg',
      'уотерфорд': 'waterford',
      'порт довер': 'port dover',
      'хейгерсвилл': 'hagersville',
      'данвилл': 'dunnville',
      'гримсби': 'grimsby',
      'бимсвилл': 'beamsville',
    };
    for (final entry in aliases.entries) {
      if (s == entry.key) {
        s = entry.value;
        break;
      }
    }
    const cyr = <String, String>{
      'а': 'a',
      'б': 'b',
      'в': 'v',
      'г': 'g',
      'д': 'd',
      'е': 'e',
      'ё': 'e',
      'ж': 'zh',
      'з': 'z',
      'и': 'i',
      'й': 'i',
      'к': 'k',
      'л': 'l',
      'м': 'm',
      'н': 'n',
      'о': 'o',
      'п': 'p',
      'р': 'r',
      'с': 's',
      'т': 't',
      'у': 'u',
      'ф': 'f',
      'х': 'h',
      'ц': 'ts',
      'ч': 'ch',
      'ш': 'sh',
      'щ': 'sh',
      'ъ': '',
      'ы': 'i',
      'ь': '',
      'э': 'e',
      'ю': 'yu',
      'я': 'ya',
    };
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      buf.write(cyr[ch] ?? ch);
    }
    var lat = buf.toString();
    lat = lat
        .replaceAll('ph', 'f')
        .replaceAll('th', 't')
        .replaceAll('ck', 'k')
        .replaceAll('ch', 'k')
        .replaceAll('sh', 's')
        .replaceAll('ou', 'u')
        .replaceAll('oo', 'u')
        .replaceAll('ee', 'i')
        .replaceAll('ea', 'i')
        .replaceAll('ae', 'e')
        .replaceAll('ai', 'e')
        .replaceAll('ay', 'e')
        .replaceAll('ey', 'i')
        .replaceAll('y', 'i')
        .replaceAll('w', 'v')
        .replaceAll('x', 'ks')
        .replaceAll('qu', 'kv')
        .replaceAll('c', 'k')
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    lat = lat.replaceAllMapped(RegExp(r'(.)\1+'), (m) => m.group(1)!);
    return lat;
  }

  /// Отсекает падежные окончания у русских слов («Майклу» → «Майкл», «Саре» → «Сар»).
  static List<String> _wordStems(String word) {
    final w = word.toLowerCase().trim();
    if (w.isEmpty) return const [];
    final out = <String>{w};
    if (RegExp(r'[а-яё]').hasMatch(w) && w.length >= 4) {
      final stripped = w.replaceFirst(
        RegExp(r'(ому|ему|ами|ями|ов|ев|ей|ам|ям|ах|ях|ом|ем|ой|ей|у|ю|е|а|я|ы|и)$'),
        '',
      );
      if (stripped.length >= 3) {
        out.add(stripped);
        out.add('$strippedа');
        out.add('$strippedя');
        out.add('$strippedй');
      }
    }
    return out.toList();
  }

  static int matchScoreForTest(String haystack, String query) =>
      _matchScore(haystack, query);

  static int _matchScore(String haystack, String query) {
    final h = haystack.toLowerCase();
    final q = query.toLowerCase().trim();
    if (q.isEmpty || h.isEmpty) return 0;
    if (h.contains(q)) return 100;

    final queryWords = q
        .split(RegExp(r'[^a-zA-Zа-яА-ЯёЁ0-9]+'))
        .where((w) => w.length >= 2)
        .toList();
    if (queryWords.isEmpty) return 0;

    final hayWords = h
        .split(RegExp(r'[^a-zA-Zа-яА-ЯёЁ0-9]+'))
        .where((w) => w.length >= 2)
        .toList();
    final hayPhonetics = hayWords.map(_phonetic).where((p) => p.isNotEmpty).toList();

    var matchedWords = 0;
    for (final qw in queryWords) {
      var wordMatched = false;
      final stems = _wordStems(qw);
      for (final stem in stems) {
        if (hayWords.any(
          (hw) =>
              hw == stem ||
              (hw.length >= 4 &&
                  stem.length >= 4 &&
                  (hw.startsWith(stem) || stem.startsWith(hw))),
        )) {
          wordMatched = true;
          break;
        }
        final pStem = _phonetic(stem);
        if (pStem.length >= 3 &&
            hayPhonetics.any(
              (hp) =>
                  hp == pStem ||
                  (hp.length >= 4 &&
                      pStem.length >= 4 &&
                      (hp.startsWith(pStem) || pStem.startsWith(hp))),
            )) {
          wordMatched = true;
          break;
        }
      }
      if (!wordMatched) return 0;
      matchedWords++;
    }
    return matchedWords == queryWords.length ? 70 + matchedWords * 5 : 0;
  }

  static Future<Job?> resolveJob(
    String? query, {
    bool includeClosed = false,
    bool fallbackToNextWhenEmpty = true,
  }) async {
    final jobs = await JobService.loadAllOnce();
    final openPool = jobs.where((j) => !JobStatuses.isClosed(j.status)).toList();
    final pool = includeClosed ? jobs : openPool;

    final q = (query ?? '').trim().toLowerCase();
    if (_isCurrentScreenKeyword(q)) {
      // НИКОГДА не проваливаемся в нечёткий поиск по слову «открытая/current»!
      return _resolveOpenScreenJob(jobs);
    }

    if (q.isEmpty || _isNextKeyword(q)) {
      if (q.isEmpty) {
        final openJob = await _resolveOpenScreenJob(jobs);
        if (openJob != null) return openJob;
        if (!fallbackToNextWhenEmpty) return null;
      }
      final now = DateTime.now().toUtc();
      Job? nextJob;
      JobVisit? nextVisit;
      for (final job in openPool) {
        final visit = job.nextActiveVisit(now: now);
        if (visit != null &&
            (nextVisit == null || visit.startAt.isBefore(nextVisit.startAt))) {
          nextJob = job;
          nextVisit = visit;
        }
      }
      return nextJob;
    }

    for (final job in pool) {
      if (job.id == query?.trim()) return job;
    }

    final digits = q.replaceAll(RegExp(r'\D'), '');
    if (digits.length >= 4) {
      for (final list in [
        openPool,
        if (includeClosed) jobs.where((j) => JobStatuses.isClosed(j.status)),
      ]) {
        for (final job in list) {
          if (ClientService.normalizePhone(job.contactPhone).contains(digits) ||
              ClientService.normalizePhone(job.clientPhone).contains(digits)) {
            return job;
          }
        }
      }
    }

    final now = DateTime.now().toUtc();
    Job? bestJob;
    var bestScore = 0;
    for (final job in pool) {
      final nameScore = _matchScore(
        '${job.clientName} ${job.contactName} ${job.jobSiteName ?? ''}',
        q,
      );
      final fullHaystack = [
        job.clientName,
        job.contactName,
        job.jobSiteName ?? '',
        job.workAddress,
        job.clientAddress,
        job.city ?? '',
        job.applianceType,
        job.applianceBrand,
        job.description,
        job.contactPhone,
      ].join(' ');
      final totalScore = nameScore > 0
          ? nameScore + 30
          : _matchScore(fullHaystack, q);
      if (totalScore <= 0) continue;

      var rank = totalScore * 10;
      if (!JobStatuses.isClosed(job.status)) rank += 50;
      final nextVisit = job.nextActiveVisit(now: now);
      if (nextVisit != null) {
        rank += 25;
        if (JobVisit.isSameDay(
          AppTimeService.bookingWallClock(nextVisit.startAt),
          AppTimeService.bookingWallClock(now),
        )) {
          rank += 20;
        }
      }
      if (rank > bestScore) {
        bestScore = rank;
        bestJob = job;
      }
    }
    return bestJob;
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
        var brandArg = (args['brand'] as String?)?.trim() ?? '';
        var appArg = (args['appliance'] as String?)?.trim() ?? '';
        var modelArg = (args['model'] as String?)?.trim() ?? '';
        final techSheetArg = (args['tech_sheet'] as String?)?.trim() ?? '';
        if (brandArg.isEmpty || appArg.isEmpty) {
          final jobs = await JobService.loadAllOnce();
          final openJob = await _resolveOpenScreenJob(jobs);
          if (openJob != null) {
            if (brandArg.isEmpty) brandArg = openJob.applianceBrand;
            if (appArg.isEmpty) appArg = openJob.applianceType;
            if (modelArg.isEmpty) {
              modelArg = openJob.primaryAppliance?.model ?? '';
            }
          }
        }
        return ServiceGuideService.lookup(
          query: (args['query'] as String?) ?? '',
          brand: brandArg,
          appliance: appArg,
          code: (args['code'] as String?) ?? '',
          kind: (args['kind'] as String?) ?? '',
          model: modelArg,
          techSheet: techSheetArg,
        );
      case 'open_diagnostics':
        AssistantActions.enqueue(
          AssistantUiAction(
            type: 'open_diagnostics',
            payload: {
              'query': (args['query'] as String?) ?? '',
              'appliance': (args['appliance'] as String?) ?? 'all',
              'brand': (args['brand'] as String?) ?? 'all',
              'kind': (args['kind'] as String?) ?? 'all',
            },
          ),
        );
        return {'ok': true, 'opened': 'diagnostics'};
      case 'search_parts':
        return _searchParts(args);
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
    final now = DateTime.now().toUtc();
    final today = AppTimeService.bookingWallClock(now);
    final when = (args['when'] as String?)?.toLowerCase() ?? '';
    final includeClosed = when == 'all' || when == 'closed';
    var list = includeClosed
        ? [...jobs]
        : jobs.where((j) => !JobStatuses.isClosed(j.status)).toList();
    final selectedVisits = <String, JobVisit>{};
    for (final job in list) {
      JobVisit? selected;
      if (when == 'today') {
        for (final visit in job.activeVisits) {
          if (!JobVisit.isSameDay(
            AppTimeService.bookingWallClock(visit.startAt),
            today,
          )) {
            continue;
          }
          selected ??= visit;
          if (visit.endAt.toUtc().isAfter(now)) {
            selected = visit;
            break;
          }
        }
      } else {
        selected = job.nextActiveVisit(now: now);
      }
      if (selected != null) selectedVisits[job.id] = selected;
    }

    if (when == 'today' || when == 'upcoming') {
      list = list.where((job) => selectedVisits.containsKey(job.id)).toList();
    } else if (when == 'closed') {
      list = list.where((j) => JobStatuses.isClosed(j.status)).toList();
    }

    list.sort((a, b) => (selectedVisits[a.id]?.startAt ??
            (includeClosed ? a.scheduledAt : null) ??
            a.createdAt)
        .compareTo(selectedVisits[b.id]?.startAt ??
            (includeClosed ? b.scheduledAt : null) ??
            b.createdAt));
    final limited = list
        .take(24)
        .map(
          (job) => _jobSummary(job, visit: selectedVisits[job.id], now: now),
        )
        .toList();
    return {
      'count': limited.length,
      'jobs': limited,
      'now': DateFormat('yyyy-MM-dd HH:mm').format(today),
      'time_zone': AppTimeService.defaultLocation,
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

  static Future<({
    String phone,
    String name,
    String clientId,
    Job? job,
  })?> _resolveOpenScreenSmsRecipient(List<Job> jobs) async {
    // 1. Живая открытая на экране переписка ConversationScreen (включая тех, у кого вообще нет заявки).
    final activeChat = ConversationScreen.activeTarget;
    if (activeChat != null && activeChat.phone.trim().isNotEmpty) {
      final digits = ClientService.normalizePhone(activeChat.phone);
      Job? matchedJob;
      final jid = (activeChat.jobId ?? '').trim();
      if (jid.isNotEmpty) {
        for (final j in jobs) {
          if (j.id == jid) {
            matchedJob = j;
            break;
          }
        }
        matchedJob ??= await JobService.getById(jid);
      }
      if (matchedJob == null && digits.length >= 10) {
        for (final j in jobs) {
          if (!JobStatuses.isClosed(j.status) &&
              (ClientService.normalizePhone(j.contactPhone) == digits ||
                  ClientService.normalizePhone(j.clientPhone) == digits)) {
            matchedJob = j;
            break;
          }
        }
      }
      var name = activeChat.name.trim();
      var cid = (activeChat.clientId ?? '').trim();
      if ((name.isEmpty || cid.isEmpty) && digits.length >= 10) {
        final foundClient = await ClientService.findByPhone(activeChat.phone);
        if (foundClient != null) {
          if (name.isEmpty) name = foundClient.fullName;
          if (cid.isEmpty) cid = foundClient.id;
        }
      }
      if (name.isEmpty && matchedJob != null) {
        name = matchedJob.contactName;
      }
      if (cid.isEmpty && matchedJob != null) {
        cid = matchedJob.clientId;
      }
      return (
        phone: activeChat.phone.trim(),
        name: name,
        clientId: cid,
        job: matchedJob,
      );
    }

    // 2. Проверка верхней карточки в навигаторе (`card:chat:...`, `card:client:...`, `card:job:...`).
    final key = AppNav.topCardKey;
    if (key != null && key.isNotEmpty) {
      if (key.startsWith('card:chat:')) {
        final rest = key.substring('card:chat:'.length).trim();
        final beforeJob = rest.contains(':job:')
            ? rest.substring(0, rest.indexOf(':job:'))
            : rest;
        final digits = ClientService.normalizePhone(beforeJob);
        if (digits.length >= 10) {
          final openJob = await _resolveOpenScreenJob(jobs);
          final foundClient = await ClientService.findByPhone(digits);
          return (
            phone: SmsService.toE164(digits),
            name: openJob?.contactName ?? foundClient?.fullName ?? '',
            clientId: openJob?.clientId ?? foundClient?.id ?? '',
            job: openJob,
          );
        }
      }
      if (key.startsWith('card:client:')) {
        final cid = key.substring('card:client:'.length).trim();
        final c = await ClientService.getById(cid);
        if (c != null && c.phone.trim().isNotEmpty) {
          final openJob = await _resolveOpenScreenJob(jobs);
          return (
            phone: c.phone.trim(),
            name: c.fullName,
            clientId: c.id,
            job: openJob,
          );
        }
      }
      final openJob = await _resolveOpenScreenJob(jobs);
      if (openJob != null && openJob.contactPhone.trim().isNotEmpty) {
        return (
          phone: openJob.contactPhone.trim(),
          name: openJob.contactName,
          clientId: openJob.clientId,
          job: openJob,
        );
      }
    }
    return null;
  }

  static Future<Map<String, dynamic>> _sendSms(Map<String, dynamic> args) async {
    final rawQuery =
        ((args['job_query'] ?? args['query'] ?? args['client_name']) as String?)
            ?.trim() ??
        '';
    final explicitPhone = (args['phone'] as String?)?.trim() ?? '';
    final lowerQuery = rawQuery.toLowerCase();
    final wantsOpenScreen =
        explicitPhone.isEmpty &&
        (rawQuery.isEmpty || _isCurrentScreenKeyword(lowerQuery));

    final allJobs = await JobService.loadAllOnce();

    Job? job;
    var phone = '';
    var recipientName = '';
    var clientId = '';

    if (wantsOpenScreen) {
      final openTarget = await _resolveOpenScreenSmsRecipient(allJobs);
      if (openTarget == null) {
        return {
          'ok': false,
          'error':
              'На экране сейчас не открыта переписка или карточка клиента. Назовите имя клиента или телефон, кому отправить сообщение.',
        };
      }
      phone = openTarget.phone;
      recipientName = openTarget.name;
      clientId = openTarget.clientId;
      job = openTarget.job;
    } else if (_isNextKeyword(lowerQuery)) {
      job = await resolveJob(
        'next',
        includeClosed: false,
        fallbackToNextWhenEmpty: true,
      );
      phone = job?.contactPhone.trim() ?? '';
      recipientName = job?.contactName ?? '';
      clientId = job?.clientId ?? '';
    } else if (rawQuery.isNotEmpty) {
      job = await resolveJob(
        rawQuery,
        includeClosed: true,
        fallbackToNextWhenEmpty: false,
      );
      phone = job?.contactPhone.trim() ?? '';
      recipientName = job?.contactName ?? '';
      clientId = job?.clientId ?? '';
    } else if (explicitPhone.isNotEmpty) {
      job = await resolveJob(
        explicitPhone,
        includeClosed: true,
        fallbackToNextWhenEmpty: false,
      );
      phone = job?.contactPhone.trim() ?? explicitPhone;
      recipientName = job?.contactName ?? '';
      clientId = job?.clientId ?? '';
    }

    // Если назвали клиента по имени, а открытой заявки не нашлось (или имя
    // только в карточке клиента) — ищем в справочнике клиентов, но НИКОГДА
    // не подставляем чужую заявку.
    if (phone.isEmpty &&
        rawQuery.isNotEmpty &&
        !wantsOpenScreen &&
        !_isNextKeyword(lowerQuery)) {
      final clients = await ClientService.loadAllOnce();
      var bestClientScore = 0;
      for (final c in clients) {
        final score = _matchScore(
          '${c.fullName} ${c.address} ${c.phone}',
          rawQuery,
        );
        if (score > bestClientScore && c.phone.trim().isNotEmpty) {
          bestClientScore = score;
          phone = c.phone.trim();
          recipientName = c.fullName;
          clientId = c.id;
        }
      }
      if (phone.isEmpty) {
        return {
          'ok': false,
          'error': 'Клиент «$rawQuery» не найден. Уточните имя или телефон.',
        };
      }
    }

    if (phone.isEmpty && explicitPhone.isNotEmpty) {
      phone = explicitPhone;
    }

    if (phone.trim().isEmpty) {
      return {'ok': false, 'error': 'Не нашёл, кому отправлять SMS'};
    }

    final rawTemplate = (args['template'] as String?)?.trim() ?? '';
    var body = (args['text'] as String?)?.trim() ?? '';
    if (body.isEmpty) {
      if (rawTemplate.isEmpty) {
        return {
          'ok': false,
          'error': 'Уточните, какой именно текст отправить клиенту.',
        };
      }
      final templates = await SettingsService.loadSmsTemplates();
      final templateKey = switch (rawTemplate) {
        'parts' || 'part_ordered' => 'part_ordered',
        'done' || 'job_done' => 'job_done',
        _ => 'on_way',
      };
      body = templates[templateKey]?.trim() ??
          templates['on_way'] ??
          'Hello, this is your technician. I am on my way.';
    }
    body = SmsText.fillName(body, recipientName);
    final russian = MessageTranslateService.looksRussian(body) ? body : '';
    if (russian.isNotEmpty) {
      body = await MessageTranslateService.toEnglish(body);
    }

    final ok = await SmsService.sendSms(
      to: phone,
      body: body,
      clientId: clientId.isEmpty ? null : clientId,
      jobId: job?.id,
      bodyRu: russian.isEmpty ? null : russian,
    );
    if (ok && job != null) {
      await JobService.sendMessage(
        jobId: job.id,
        text: body,
        targetRole: job.hasJobSite ? 'Арендатор' : 'Владелец',
        sender: 'company',
      );
    }
    return {
      'ok': ok,
      'client_name': recipientName.isNotEmpty
          ? recipientName
          : (job?.clientName ?? phone),
      'phone': phone,
      'text': body,
    };
  }

  static DateTime? _parseVisitSlot(String date, String time) {
    final parsedDate = _parseDay(date);
    if (parsedDate == null) return null;
    if (time.trim().isEmpty) {
      return DateTime(parsedDate.year, parsedDate.month, parsedDate.day);
    }
    final parsedTime = _parseClock(time);
    if (parsedTime == null) return null;
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
    final rawQuery = ((args['job_query'] ?? args['query']) as String?)?.trim();
    final job = await resolveJob(
      rawQuery,
      fallbackToNextWhenEmpty: rawQuery == null || rawQuery.isEmpty,
    );
    if (job == null) {
      return {'ok': false, 'error': 'Заявка не найдена'};
    }
    final rawTime = (args['time'] as String?)?.trim() ?? '';
    final next = _parseVisitSlot(
      (args['date'] as String?) ?? '',
      rawTime,
    );
    if (next == null) {
      return {'ok': false, 'error': 'Нужна дата date=YYYY-MM-DD'};
    }
    final visits = [...job.coalescedVisits];
    final now = DateTime.now();
    final idx = visits.indexWhere(
      (visit) => visit.isScheduled && !visit.startAt.isBefore(now),
    );
    if (idx >= 0) {
      visits[idx] = visits[idx].copyWith(startAt: next, smsDialog: '');
    } else if (visits.isNotEmpty) {
      visits[0] = visits[0].copyWith(startAt: next, smsDialog: '');
    } else {
      visits.add(JobVisit.create(startAt: next));
    }
    await JobService.update(job.id, {
      ...JobVisit.syncFields(visits, defaultDuration: job.durationMinutes),
      'status': JobStatuses.call,
    });
    final hasTime = next.hour != 0 || next.minute != 0;
    final when = hasTime
        ? DateFormat('yyyy-MM-dd HH:mm').format(next)
        : DateFormat('yyyy-MM-dd').format(next);
    return {
      'ok': true,
      'client_name': job.clientName,
      'scheduled_at': when,
      'date': Formatters.formatDateEn(next),
      'time': hasTime ? Formatters.formatTime(next) : '',
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

    final effectiveName = SmsText.stripClientWord(name, phone);
    var clientId = '';
    final email = (args['email'] as String?)?.trim() ??
        (args['client_email'] as String?)?.trim() ??
        '';
    final existing = await ClientService.findExisting(phone: phone, email: email);
    clientId = existing?.id ?? '';
    if (clientId.isEmpty) {
      clientId = await ClientService.createOrUpdate(
        fullName: effectiveName,
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
        if (timeStr != null && timeStr.contains(':')) {
          final parts = timeStr.split(':');
          final hour = int.tryParse(parts[0]) ?? 9;
          final minute = int.tryParse(parts[1]) ?? 0;
          scheduledAt = DateTime(parsed.year, parsed.month, parsed.day, hour, minute);
        } else {
          scheduledAt = DateTime(parsed.year, parsed.month, parsed.day);
        }
      }
    }

    final job = Job(
      id: '',
      clientId: clientId,
      clientName: effectiveName,
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

  static Future<Map<String, dynamic>> _searchParts(
    Map<String, dynamic> args,
  ) async {
    var partQuery =
        ((args['part_query'] ?? args['query']) as String?)?.trim() ?? '';
    var partNumber = (args['part_number'] as String?)?.trim() ?? '';
    var applianceType =
        ((args['appliance_type'] ?? args['appliance']) as String?)?.trim() ??
        '';
    var brand = (args['brand'] as String?)?.trim() ?? '';
    var model = (args['model'] as String?)?.trim() ?? '';
    var problem = (args['problem'] as String?)?.trim() ?? '';
    final jobQuery = (args['job_query'] as String?)?.trim() ?? '';

    if (jobQuery.isNotEmpty ||
        model.isEmpty ||
        brand.isEmpty ||
        (partQuery.isEmpty && partNumber.isEmpty)) {
      final job = await resolveJob(
        jobQuery.isEmpty ? 'current' : jobQuery,
        includeClosed: true,
        fallbackToNextWhenEmpty: false,
      );
      if (job != null) {
        JobAppliance? picked;
        final wantedKey = DiagnosticsScreen.normalizeApplianceKey(applianceType);
        if (wantedKey != 'all') {
          for (final a in job.appliances) {
            if (DiagnosticsScreen.normalizeApplianceKey(a.type) == wantedKey) {
              picked = a;
              break;
            }
          }
        }
        picked ??= job.appliances.isNotEmpty ? job.appliances.first : null;

        if (picked != null) {
          if (applianceType.isEmpty) applianceType = picked.type.trim();
          if (brand.isEmpty) brand = picked.brand.trim();
          if (model.isEmpty) model = picked.model.trim();
        }
        if (model.isEmpty) {
          final targetKey = DiagnosticsScreen.normalizeApplianceKey(
            applianceType,
          );
          for (final passport in CarePlanService.appliances) {
            if (!passport.isActive || passport.model.trim().isEmpty) continue;
            final linked = job.applianceIds.contains(passport.id);
            final sameClient =
                job.clientId.isNotEmpty && passport.clientId == job.clientId;
            if (!linked && !sameClient) continue;
            if (targetKey != 'all' &&
                DiagnosticsScreen.normalizeApplianceKey(passport.type) !=
                    targetKey) {
              continue;
            }
            model = passport.model.trim();
            if (brand.isEmpty) brand = passport.brand.trim();
            if (applianceType.isEmpty) applianceType = passport.type.trim();
            break;
          }
        }
        if (partQuery.isEmpty &&
            partNumber.isEmpty &&
            job.expectedParts.isNotEmpty) {
          partQuery = job.expectedParts.first.trim();
        }
        if (problem.isEmpty) {
          problem = [
            if (picked != null && picked.issue.trim().isNotEmpty)
              picked.issue.trim(),
            if (job.solution.trim().isNotEmpty) job.solution.trim(),
            if (job.description.trim().isNotEmpty &&
                job.description.trim() != 'Нет описания')
              job.description.trim(),
          ].join('. ');
        }
      }
    }

    final enough = PartSearchService.hasEnoughInput(
      partQuery: partQuery,
      partNumber: partNumber,
      model: model,
      problem: problem,
    );
    if (!enough) {
      final quick = await PartSearchService.search(
        partQuery: partQuery,
        partNumber: partNumber,
        applianceType: applianceType,
        brand: brand,
        model: model,
        problem: problem,
      );
      return quick.toToolJson();
    }

    final titleParts = <String>[
      if (partNumber.isNotEmpty) partNumber,
      if (partQuery.isNotEmpty) partQuery,
      if (brand.isNotEmpty || model.isNotEmpty) '$brand $model'.trim()
      else if (applianceType.isNotEmpty) applianceType,
    ];
    final session = PartSearchSession(
      queryTitle: titleParts.isEmpty ? 'Поиск запчасти' : titleParts.join(' · '),
    );
    AssistantActions.enqueue(
      const AssistantUiAction(type: 'open_part_search'),
    );
    unawaited(AssistantActions.flush());

    final result = await PartSearchService.search(
      partQuery: partQuery,
      partNumber: partNumber,
      applianceType: applianceType,
      brand: brand,
      model: model,
      problem: problem,
      session: session,
    );
    return result.toToolJson();
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
            r'(^|\s)(открой|открыть|open|пожалуйста|please|карточку|карточк[ауие]?|заявк[уиеа]?|клиента?|client|job|card|отправь|отправить|send|смс|sms|позвони|позвонить|call|что|я|в|пути|the|a)(?=\s|$)',
            caseSensitive: false,
            unicode: true,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.length < 2) return 'next';
    return cleaned;
  }
}
