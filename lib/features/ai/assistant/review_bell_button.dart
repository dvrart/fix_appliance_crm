import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../core/sms_text.dart';
import '../../../models/job.dart';
import '../../../services/job_service.dart';
import '../../../services/sms_service.dart';
import '../../../services/twilio_service.dart';
import '../../../shared/app_nav.dart';
import '../../../shared/widgets/confirm_action_sheet.dart';
import '../../calls/call_review_page.dart';
import '../../jobs/job_details/job_details_screen.dart';
import '../../messages/conversation_screen.dart';

/// Визит, до начала которого осталось меньше [InboxSelection.soonWindow].
class SoonVisit {
  final Job job;
  final JobVisit visit;

  const SoonVisit(this.job, this.visit);
}

/// Отбор для панели уведомлений («Колокольчик»).
///
/// Собирает текущие события (новые звонки, непрочитанные сообщения,
/// недоставленные SMS и неподтверждённые заявки) и привязывает каждое
/// к рабочей карточке [Job], если она есть у клиента.
///
/// Секции «Ждёт решения» здесь больше нет (решение FIX, 21.10.2026):
/// колокольчик не предлагает завести заявку и не держит подтверждение
/// визита. SMS, которое сервер придумал, но не отправил, по-прежнему
/// ждёт кнопку «Отправить / Не отправлять» — но в самой переписке, куда
/// ведёт push `outbox`.
///
/// Сюда же переехало то, что раньше жило в шапке календаря: машинка
/// доставки и плашка «N без даты визита». Плюс напоминание о визите,
/// до которого осталось меньше двух часов.
class InboxSelection {
  /// Звонки, сообщения и сбои доставки.
  final List<SmsMessage> messages;
  final List<SmsMessage> failedSms;
  final List<CallRecord> calls;

  /// Заявки от ИИ: их надо подтвердить.
  final List<Job> jobs;

  /// Визиты и доставка: скоро выезжать, ждём запчасть, нет даты визита.
  final List<SoonVisit> soonVisits;
  final List<Job> delivery;
  final List<Job> unscheduled;

  /// Все живые заявки — для поиска привязанной рабочей карточки.
  final List<Job> allJobs;

  /// За сколько до визита напоминать. Серверное напоминание мастеру
  /// (крон `sendOwnerReminders`) приходит за 1.5 часа — берём чуть шире,
  /// чтобы строка в колокольчике появлялась не позже push-а.
  static const Duration soonWindow = Duration(hours: 2);

  const InboxSelection({
    this.messages = const [],
    this.failedSms = const [],
    this.calls = const [],
    this.jobs = const [],
    this.soonVisits = const [],
    this.delivery = const [],
    this.unscheduled = const [],
    this.allJobs = const [],
  });

  static String _emailJobDedupeKey(Job job) {
    if (job.intakeSource != 'email') return '';
    final from = job.sourceEmailFrom.trim().toLowerCase();
    final when = job.createdAt.toUtc();
    final minute =
        '${when.year.toString().padLeft(4, '0')}'
        '${when.month.toString().padLeft(2, '0')}'
        '${when.day.toString().padLeft(2, '0')}'
        '${when.hour.toString().padLeft(2, '0')}'
        '${when.minute.toString().padLeft(2, '0')}';
    final desc = job.description
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ');
    final name = job.clientName.trim().toLowerCase();
    return '${from.isEmpty ? name : from}|$minute|$desc';
  }

  static InboxSelection of({
    List<Job> jobs = const [],
    List<CallRecord> calls = const [],
    List<SmsMessage> failedSms = const [],
    List<SmsMessage> unreadMessages = const [],
    DateTime? callsCutoff,
    DateTime? now,
  }) {
    final allLiveJobs = <Job>[];
    final allSeenIds = <String>{};
    for (final job in jobs) {
      if (job.isDeleted) continue;
      if (!allSeenIds.add(job.id)) continue;
      allLiveJobs.add(job);
    }

    final liveJobs = <Job>[];
    final seenJobIds = <String>{};
    final seenEmailDedupe = <String>{};
    for (final job in allLiveJobs) {
      if (!job.needsReview) continue;
      if (JobStatuses.isClosed(job.status)) continue;
      final emailKey = _emailJobDedupeKey(job);
      if (emailKey.isNotEmpty &&
          emailKey != '||' &&
          !seenEmailDedupe.add(emailKey)) {
        continue;
      }
      if (!seenJobIds.add(job.id)) continue;
      liveJobs.add(job);
    }
    liveJobs.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    final activeJobIds = {
      for (final job in allLiveJobs)
        if (!JobStatuses.isClosed(job.status)) job.id,
    };
    final liveCallIds = {
      for (final job in liveJobs)
        if ((job.sourceCallId ?? '').trim().isNotEmpty)
          job.sourceCallId!.trim(),
    };
    final liveEmailIds = {
      for (final job in liveJobs)
        if ((job.sourceEmailId ?? '').trim().isNotEmpty)
          job.sourceEmailId!.trim(),
    };

    final openCalls = <CallRecord>[];
    final seenCalls = <String>{};
    for (final call in calls) {
      if (call.reviewed || call.isDeleted) continue;
      if (!call.isIncoming) continue;
      if (const [
        'ringing',
        'in-progress',
        'queued',
        'initiated',
      ].contains(call.status)) {
        continue;
      }
      if (!seenCalls.add(call.id)) continue;
      final createdJobId = (call.createdJobId ?? '').trim();
      if (createdJobId.isNotEmpty &&
          (seenJobIds.contains(createdJobId) ||
              !activeJobIds.contains(createdJobId))) {
        continue;
      }
      if (liveCallIds.contains(call.id) ||
          (call.callSid.trim().isNotEmpty &&
              liveCallIds.contains(call.callSid.trim()))) {
        continue;
      }
      if (callsCutoff != null &&
          call.aiStatus != 'done' &&
          call.aiStatus != 'processing' &&
          !call.answeredByAi) {
        final start = call.startTime;
        if (start != null && start.isBefore(callsCutoff)) continue;
      }
      openCalls.add(call);
    }

    // SMS и письма, похожие на заявку, больше не выделяются в отдельное
    // предложение «В заявку» — они идут обычным непрочитанным сообщением.
    final unread = <SmsMessage>[];
    final seenUnreadIds = <String>{};
    for (final message in unreadMessages) {
      if (message.isDeleted || message.isOutbound || message.read) continue;
      final linkedJobId = (message.jobId ?? '').trim();
      if (message.isEmail &&
          !message.crmThread &&
          (liveEmailIds.contains(message.id) ||
              (linkedJobId.isNotEmpty && seenJobIds.contains(linkedJobId)))) {
        continue;
      }
      if (!seenUnreadIds.add(message.id)) continue;
      unread.add(message);
    }

    List<SmsMessage> live(List<SmsMessage> items) => [
          for (final message in items)
            if (!message.isDeleted) message,
        ];

    // Машинка доставки, плашка «без даты визита» и напоминание о скором
    // визите считаются по тем же живым заявкам — отдельный поток не нужен.
    final nowAt = now ?? DateTime.now();
    final soonEdge = nowAt.add(soonWindow);
    final soonVisits = <SoonVisit>[];
    final deliveryJobs = <Job>[];
    final unscheduledJobs = <Job>[];
    for (final job in allLiveJobs) {
      if (JobStatuses.isClosed(job.status)) continue;
      if (job.isUnscheduled) unscheduledJobs.add(job);
      if (job.status == JobStatuses.waitingPart) deliveryJobs.add(job);
      for (final visit in job.coalescedVisits) {
        if (!visit.isActiveSlot) continue;
        if (visit.startAt.isBefore(nowAt)) continue;
        if (visit.startAt.isAfter(soonEdge)) continue;
        soonVisits.add(SoonVisit(job, visit));
      }
    }
    soonVisits.sort((a, b) => a.visit.startAt.compareTo(b.visit.startAt));
    deliveryJobs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    unscheduledJobs.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return InboxSelection(
      messages: unread,
      failedSms: live(failedSms),
      calls: openCalls,
      jobs: liveJobs,
      soonVisits: soonVisits,
      delivery: deliveryJobs,
      unscheduled: unscheduledJobs,
      allJobs: allLiveJobs,
    );
  }

  Job? _resolveById(String rawId) {
    final id = rawId.trim();
    if (id.isEmpty) return null;
    Job? found;
    for (final job in allJobs) {
      if (job.id == id) {
        found = job;
        break;
      }
    }
    if (found == null) return null;
    if (found.isMergedDuplicate) {
      final targetId = found.mergedIntoJobId.trim();
      for (final job in allJobs) {
        if (job.id == targetId && !job.isDeleted) return job;
      }
    }
    return found;
  }

  static DateTime _jobSortTime(Job job) {
    return job.latestVisit?.startAt ?? job.scheduledAt ?? job.createdAt;
  }

  static Job? _pickBestJob(Iterable<Job> candidates) {
    Job? best;
    for (final job in candidates) {
      if (job.isDeleted || job.isMergedDuplicate) continue;
      if (best == null) {
        best = job;
        continue;
      }
      final bestOpen = !JobStatuses.isClosed(best.status);
      final jobOpen = !JobStatuses.isClosed(job.status);
      if (jobOpen != bestOpen) {
        if (jobOpen) best = job;
        continue;
      }
      if (_jobSortTime(job).isAfter(_jobSortTime(best))) {
        best = job;
      }
    }
    return best;
  }

  /// Находит рабочую карточку [Job], к которой относится сообщение.
  Job? jobForMessage(SmsMessage message) {
    final direct = _resolveById(message.jobId ?? '');
    if (direct != null) return direct;

    final msgId = message.id.trim();
    if (msgId.isNotEmpty) {
      for (final job in allJobs) {
        if ((job.sourceEmailId ?? '').trim() == msgId) {
          return _resolveById(job.id) ?? job;
        }
      }
    }

    final clientId = (message.clientId ?? '').trim();
    final peer = message.isOutbound ? message.to : message.from;
    final phone = SmsService.normalizePhone(peer);
    final email = SmsService.normalizeEmail(message.counterpartEmail);

    final matches = <Job>[];
    for (final job in allJobs) {
      if (job.isDeleted || job.isMergedDuplicate) continue;
      if (clientId.isNotEmpty && job.clientId.trim() == clientId) {
        matches.add(job);
        continue;
      }
      if (phone.length >= 10) {
        final clientPhone = SmsService.normalizePhone(job.clientPhone);
        final contactPhone = SmsService.normalizePhone(job.contactPhone);
        final sitePhone = SmsService.normalizePhone(job.jobSitePhone ?? '');
        if (clientPhone == phone ||
            contactPhone == phone ||
            sitePhone == phone) {
          matches.add(job);
          continue;
        }
      }
      if (email.contains('@') && !message.isWebsiteFormMail) {
        final sourceEmail = SmsService.normalizeEmail(job.sourceEmailFrom);
        final siteEmail = SmsService.normalizeEmail(job.jobSiteEmail ?? '');
        if (sourceEmail == email || siteEmail == email) {
          matches.add(job);
        }
      }
    }
    return _pickBestJob(matches);
  }

  /// Находит рабочую карточку [Job], к которой относится звонок.
  Job? jobForCall(CallRecord call) {
    final direct = _resolveById(call.createdJobId ?? '');
    if (direct != null) return direct;

    final callId = call.id.trim();
    final callSid = call.callSid.trim();
    for (final job in allJobs) {
      final src = (job.sourceCallId ?? '').trim();
      if (src.isEmpty) continue;
      if (src == callId || (callSid.isNotEmpty && src == callSid)) {
        return _resolveById(job.id) ?? job;
      }
    }

    final clientId = (call.clientId ?? '').trim();
    final peer = call.isIncoming ? call.fromNumber : call.toNumber;
    final phone = SmsService.normalizePhone(peer);

    final matches = <Job>[];
    for (final job in allJobs) {
      if (job.isDeleted || job.isMergedDuplicate) continue;
      if (clientId.isNotEmpty && job.clientId.trim() == clientId) {
        matches.add(job);
        continue;
      }
      if (phone.length >= 10) {
        final clientPhone = SmsService.normalizePhone(job.clientPhone);
        final contactPhone = SmsService.normalizePhone(job.contactPhone);
        final sitePhone = SmsService.normalizePhone(job.jobSitePhone ?? '');
        if (clientPhone == phone ||
            contactPhone == phone ||
            sitePhone == phone) {
          matches.add(job);
        }
      }
    }
    return _pickBestJob(matches);
  }

  int get attentionCount =>
      failedSms.length + calls.length + messages.length;

  int get confirmCount => jobs.length;

  int get visitsCount =>
      soonVisits.length + delivery.length + unscheduled.length;

  int get total => attentionCount + confirmCount + visitsCount;

  bool get isEmpty => total == 0;
}

/// Колокольчик в правом верхнем углу календаря — на месте, где раньше
/// ехала машинка доставки. Доставка переехала внутрь панели.
class ReviewBellButton extends StatelessWidget {
  final Color color;
  final double iconSize;

  const ReviewBellButton({
    super.key,
    this.color = Colors.white,
    this.iconSize = 28,
  });

  @override
  Widget build(BuildContext context) {
    return _ReviewInboxStreams(
      builder: (jobs, calls, unreadMessages, failedSms, callsCutoff) {
        final count = InboxSelection.of(
          jobs: jobs,
          calls: calls,
          unreadMessages: unreadMessages,
          failedSms: failedSms,
          callsCutoff: callsCutoff,
        ).total;
        return IconButton(
          tooltip: context.tr('Уведомления', 'Notifications'),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 40),
          onPressed: () {
            HapticFeedback.selectionClick();
            showInbox(context);
          },
          icon: Badge(
            isLabelVisible: count > 0,
            backgroundColor: AppColors.accent,
            textColor: Colors.black,
            label: Text('$count'),
            child: Icon(
              count == 0
                  ? Icons.notifications_none
                  : Icons.notifications_active,
              color: color,
              size: iconSize,
            ),
          ),
        );
      },
    );
  }

  static Future<void> showInbox(BuildContext hostContext) {
    return showModalBottomSheet<void>(
      context: hostContext,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.52,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          builder: (context, scrollController) {
            return ReviewInboxPanel(
              hostContext: hostContext,
              sheetContext: sheetContext,
              scrollController: scrollController,
            );
          },
        );
      },
    );
  }
}

/// Кнопка в строке: решение принимается здесь, не открывая экран.
class _InboxAction {
  final String label;
  final IconData icon;
  final Color color;
  final bool filled;
  final bool iconOnly;
  final Future<void> Function() run;

  const _InboxAction({
    required this.label,
    required this.icon,
    required this.color,
    required this.run,
    this.filled = false,
    this.iconOnly = false,
  });
}

class _InboxEntry {
  final String key;
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final String originLabel;
  final String applianceType;
  final Job? job;
  final DateTime? when;
  final VoidCallback? onTap;
  final List<_InboxAction> actions;

  /// Чем карточка уходит из списка по кнопке «Убрать разобранное».
  /// У решений этого нет: молча потерять их нельзя.
  final Future<void> Function()? onClear;

  const _InboxEntry({
    required this.key,
    required this.icon,
    required this.color,
    required this.title,
    this.subtitle = '',
    this.originLabel = '',
    this.applianceType = '',
    this.job,
    this.when,
    this.onTap,
    this.actions = const [],
    this.onClear,
  });
}

String _textFrom(Map<String, dynamic>? data, List<String> keys) {
  if (data == null) return '';
  for (final key in keys) {
    final value = (data[key] ?? '').toString().trim();
    if (value.isNotEmpty) return value;
  }
  return '';
}

String _ownerName(Map<String, dynamic>? data, String fallback) {
  final raw = _textFrom(data, const ['client_name', 'clientName', 'name']);
  final name = SmsText.stripClientWord(raw);
  return name.isEmpty ? fallback : name;
}

String _applianceOf(Map<String, dynamic>? data) {
  return _textFrom(data, const [
    'appliance_type',
    'applianceType',
    'kind_of_appliance',
  ]);
}

String _oneLine(String raw, {String? clientName}) {
  var text = raw;
  if (RegExp(r'\{name\}', caseSensitive: false).hasMatch(text)) {
    text = SmsText.fillName(text, clientName);
  }
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

Map<String, dynamic>? _callExtracted(CallRecord call) {
  final top = call.extractedData;
  if (top != null && top.isNotEmpty) return top;
  final nested = call.aiReception?['extracted'];
  if (nested is Map) return Map<String, dynamic>.from(nested);
  return null;
}

String _callSubtitle(BuildContext context, CallRecord call) {
  if (call.serviceDeclined) {
    final reason = call.declineReason.trim();
    if (reason.isNotEmpty) return reason;
    return context.tr(
      'секретарь отказала — заявки нет',
      'secretary declined — no job',
    );
  }
  if (call.aiStatus == 'processing') {
    return context.tr(
      'ИИ разбирает запись…',
      'AI is processing the recording…',
    );
  }
  final extracted = _callExtracted(call);
  final appliance = _applianceOf(extracted);
  final issue = _textFrom(
    extracted,
    const ['issue', 'problem', 'description'],
  );
  if (issue.isNotEmpty) {
    return appliance.isNotEmpty ? '$appliance · $issue' : issue;
  }
  final summary = (call.summary ?? '').trim();
  if (summary.isNotEmpty) return summary;
  final transcript = (call.transcriptionRu ?? call.transcription ?? '').trim();
  if (transcript.isNotEmpty) return transcript;
  if (call.answeredByAi) {
    return context.tr(
      'разобран секретарём, без заявки',
      'handled by AI secretary, no job',
    );
  }
  if (const ['no-answer', 'busy', 'canceled', 'cancelled']
      .contains(call.status)) {
    return context.tr('клиент не дозвонился', 'missed incoming call');
  }
  return '';
}

class ReviewInboxPanel extends StatefulWidget {
  final BuildContext hostContext;
  final BuildContext sheetContext;
  final ScrollController? scrollController;

  const ReviewInboxPanel({
    super.key,
    required this.hostContext,
    required this.sheetContext,
    this.scrollController,
  });

  @override
  State<ReviewInboxPanel> createState() => ReviewInboxPanelState();
}

class ReviewInboxPanelState extends State<ReviewInboxPanel> {
  bool _clearing = false;
  final Set<String> _busy = <String>{};

  Future<void> _closeInboxThen(Future<void> Function() open) async {
    final host = widget.hostContext;
    final sheet = widget.sheetContext;
    final scaffold = Scaffold.maybeOf(sheet) ?? Scaffold.maybeOf(host);
    if (scaffold != null &&
        (scaffold.isEndDrawerOpen || scaffold.isDrawerOpen)) {
      scaffold.closeEndDrawer();
      if (scaffold.isDrawerOpen) scaffold.closeDrawer();
    } else if (sheet.mounted && Navigator.of(sheet).canPop()) {
      Navigator.pop(sheet);
    }
    await Future<void>.delayed(const Duration(milliseconds: 280));
    if (!host.mounted) return;
    await open();
  }

  /// Кнопка в строке: пока сервер думает, строка показывает это и второй
  /// раз не нажимается. Панель при этом не закрывается — решение принято
  /// на месте, и следующее уже видно.
  Future<void> _run(String key, Future<void> Function() action) async {
    if (!_busy.add(key)) return;
    setState(() {});
    try {
      await action();
    } finally {
      _busy.remove(key);
      if (mounted) setState(() {});
    }
  }

  void _openCall(CallRecord call) {
    unawaited(
      _closeInboxThen(() async {
        final id = call.id;
        unawaited(TwilioService.markReviewed(id, call: call));
        await CallReviewPage.open(widget.hostContext, callId: id, call: call);
      }),
    );
  }

  void _openMessageConversation(SmsMessage message, {Job? job}) {
    unawaited(
      _closeInboxThen(() async {
        final host = widget.hostContext;
        final website = message.isWebsiteFormMail;
        final email = message.counterpartEmail;
        final phone = message.isEmail
            ? (job?.contactPhone ?? '')
            : (message.isOutbound ? message.to.trim() : message.from.trim());
        final clientId = message.clientId ?? job?.clientId;
        final contactName = job?.contactName.trim().isNotEmpty == true
            ? job!.contactName.trim()
            : (website ? kWebsiteInboxTitle : null);
        if (!message.isOutbound && !message.read) {
          unawaited(
            SmsService.markConversationRead(
              message.isEmail ? '' : phone,
              email: message.isEmail ? email : null,
              clientId: clientId,
              websiteInbox: website,
            ),
          );
        }
        await ConversationScreen.open(
          host,
          phoneNumber: website ? '' : phone,
          email: website ? null : (email.contains('@') ? email : null),
          clientId: website ? null : clientId,
          contactName: contactName,
          websiteInbox: website,
          initialChannel: message.isEmail
              ? ConversationChannel.email
              : ConversationChannel.sms,
        );
      }),
    );
  }

  // ——— Звонки и сообщения ———

  List<_InboxEntry> _attentionEntries(InboxSelection selection) {
    final unknown = context.tr('Клиент', 'Client');
    final entries = <_InboxEntry>[];

    for (final message in selection.messages) {
      final job = selection.jobForMessage(message);
      final extracted = message.extractedData;
      final isEmail = message.isEmail;
      final website = message.isWebsiteFormMail;
      final peer = isEmail
          ? (message.counterpartEmail.isNotEmpty
              ? message.counterpartEmail
              : message.from.trim())
          : message.from.trim();
      final fallbackTitle = website
          ? kWebsiteInboxTitle
          : (job?.contactName.trim().isNotEmpty == true
              ? job!.contactName.trim()
              : (peer.isEmpty ? unknown : peer));
      final title = _ownerName(extracted, fallbackTitle);
      final bodyText = _oneLine(message.displayBody, clientName: title);
      final subject = _oneLine(message.subject, clientName: title);
      final subtitle = isEmail && subject.isNotEmpty
          ? (bodyText.isNotEmpty && bodyText != subject
              ? '$subject — $bodyText'
              : subject)
          : (bodyText.isNotEmpty
              ? bodyText
              : context.tr('Фото или вложение', 'Photo or attachment'));
      entries.add(
        _InboxEntry(
          key: 'msg:${message.id}',
          icon: website
              ? Icons.language
              : (isEmail ? Icons.email_outlined : Icons.sms_outlined),
          color: isEmail ? const Color(0xFF2E7D32) : const Color(0xFF0277BD),
          title: title,
          subtitle: subtitle,
          originLabel: website
              ? context.tr('Письмо с сайта', 'Website email')
              : (isEmail
                  ? context.tr('Новое письмо', 'New email')
                  : context.tr('Новое SMS', 'New SMS')),
          applianceType: job?.applianceType ?? _applianceOf(extracted),
          job: job,
          when: message.createdAt,
          onTap: () => _openMessageConversation(message, job: job),
          actions: [
            _InboxAction(
              label: context.tr('Прочитано', 'Mark read'),
              icon: Icons.check,
              color: const Color(0xFF64748B),
              iconOnly: true,
              run: () => SmsService.markEmailSeen(message.id),
            ),
          ],
          onClear: () => SmsService.markEmailSeen(message.id),
        ),
      );
    }

    for (final message in selection.failedSms) {
      final phone = message.to.trim();
      final job = selection.jobForMessage(message);
      final title = job?.contactName.trim().isNotEmpty == true
          ? job!.contactName.trim()
          : (phone.isEmpty ? unknown : phone);
      entries.add(
        _InboxEntry(
          key: 'failed:${message.id}',
          icon: Icons.sms_failed,
          color: const Color(0xFFC62828),
          title: title,
          subtitle: _oneLine(message.failureReason, clientName: title),
          originLabel: context.tr('SMS не дошло', 'SMS not delivered'),
          applianceType: job?.applianceType ?? '',
          job: job,
          when: message.createdAt,
          onTap: () {
            unawaited(SmsService.dismissFailure(message.id));
            _openMessageConversation(message, job: job);
          },
          actions: [
            _InboxAction(
              label: context.tr('Убрать', 'Dismiss'),
              icon: Icons.check,
              color: const Color(0xFF64748B),
              iconOnly: true,
              run: () => SmsService.dismissFailure(message.id),
            ),
          ],
          onClear: () => SmsService.dismissFailure(message.id),
        ),
      );
    }

    for (final call in selection.calls) {
      final extracted = _callExtracted(call);
      final phone = call.isIncoming ? call.fromNumber : call.toNumber;
      final job = selection.jobForCall(call);
      final declined = call.serviceDeclined;
      final missed = const ['no-answer', 'busy', 'canceled', 'cancelled']
          .contains(call.status);
      final fallbackName = job?.contactName.trim().isNotEmpty == true
          ? job!.contactName.trim()
          : (phone.isEmpty ? unknown : phone);
      final title = _ownerName(extracted, fallbackName);
      final originLabel = declined
          ? context.tr('Звонок · отказ', 'Call · declined')
          : (call.aiStatus == 'processing'
              ? context.tr('Звонок', 'Call')
              : (call.answeredByAi
                  ? context.tr('Звонок · ИИ', 'Call · AI')
                  : (missed
                      ? context.tr('Пропущенный звонок', 'Missed call')
                      : context.tr('Входящий звонок', 'Incoming call'))));
      entries.add(
        _InboxEntry(
          key: 'call:${call.id}',
          icon: declined
              ? Icons.phone_disabled
              : (missed ? Icons.phone_missed : Icons.phone_in_talk),
          color: declined
              ? const Color(0xFF616161)
              : (missed ? const Color(0xFFC62828) : const Color(0xFFEF6C00)),
          title: title,
          subtitle: _oneLine(_callSubtitle(context, call), clientName: title),
          originLabel: originLabel,
          applianceType: declined
              ? ''
              : (_applianceOf(extracted).isNotEmpty
                  ? _applianceOf(extracted)
                  : (job?.applianceType ?? '')),
          job: job,
          when: call.startTime,
          onTap: () => _openCall(call),
          actions: [
            _InboxAction(
              label: context.tr('Убрать', 'Dismiss'),
              icon: Icons.check,
              color: const Color(0xFF64748B),
              iconOnly: true,
              run: () => TwilioService.markReviewed(call.id),
            ),
          ],
          onClear: () => TwilioService.markReviewed(call.id),
        ),
      );
    }

    entries.sort(_byTimeDesc);
    return entries;
  }

  // ——— Подтвердить заявки ———

  List<_InboxEntry> _confirmEntries(InboxSelection selection) {
    final host = widget.hostContext;
    final unknown = context.tr('Клиент', 'Client');
    final entries = <_InboxEntry>[];
    for (final job in selection.jobs) {
      final name = job.contactName.trim().isNotEmpty
          ? job.contactName.trim()
          : (job.clientName.trim().isNotEmpty
                ? job.clientName.trim()
                : (job.contactPhone.trim().isNotEmpty
                      ? job.contactPhone.trim()
                      : unknown));
      final fromWebsite = job.intakeSource == 'website';
      final fromEmail = job.intakeSource == 'email' || fromWebsite;
      final fromPhone = job.intakeSource == 'phone';
      final appliance =
          (job.primaryAppliance?.displayName ?? job.applianceType).trim();
      final detail = job.description.trim().isNotEmpty
          ? job.description.trim()
          : job.workAddress.trim();
      final jobSummary = _oneLine(
        [
          if (appliance.isNotEmpty) appliance,
          if (detail.isNotEmpty) detail,
        ].join(' · '),
        clientName: name,
      );
      void openJob() {
        unawaited(
          _closeInboxThen(() async {
            await AppNav.openCard(
              host,
              rootNavigator: true,
              key: AppNav.jobKey(job.id),
              builder: (_) => JobDetailsScreen(
                jobId: job.id,
                clientId: job.clientId,
                jobData: job.toMap(),
              ),
            );
          }),
        );
      }
      entries.add(
        _InboxEntry(
          key: 'job:${job.id}',
          icon: fromWebsite
              ? Icons.language
              : fromEmail
                  ? Icons.email_outlined
                  : fromPhone
                      ? Icons.phone_in_talk
                      : Icons.assignment_late,
          color: fromEmail ? const Color(0xFF2E7D32) : const Color(0xFF1565C0),
          title: name,
          subtitle: jobSummary,
          applianceType: job.applianceType,
          job: job,
          when: job.createdAt,
          originLabel: fromWebsite
              ? context.tr('Заявка · Сайт', 'Job · Website')
              : fromEmail
                  ? context.tr('Заявка · Почта', 'Job · Email')
                  : fromPhone
                      ? context.tr('Заявка · Звонок', 'Job · Call')
                      : context.tr('Заявка · SMS', 'Job · SMS'),
          onTap: openJob,
          actions: [
            _InboxAction(
              label: context.tr('Подтвердить', 'Confirm'),
              icon: Icons.check,
              color: const Color(0xFF2E7D32),
              iconOnly: true,
              run: () => JobService.markReviewed(job.id),
            ),
          ],
          onClear: () => JobService.markReviewed(job.id),
        ),
      );
    }
    entries.sort(_byTimeDesc);
    return entries;
  }

  // ——— Визиты и доставка ———

  void _openJob(Job job) {
    unawaited(
      _closeInboxThen(() async {
        await AppNav.openCard(
          widget.hostContext,
          rootNavigator: true,
          key: AppNav.jobKey(job.id),
          builder: (_) => JobDetailsScreen(
            jobId: job.id,
            clientId: job.clientId,
            jobData: job.toMap(),
          ),
        );
      }),
    );
  }

  String _jobName(Job job, String unknown) {
    if (job.contactName.trim().isNotEmpty) return job.contactName.trim();
    if (job.clientName.trim().isNotEmpty) return job.clientName.trim();
    if (job.contactPhone.trim().isNotEmpty) return job.contactPhone.trim();
    return unknown;
  }

  /// Строки, которые раньше жили в шапке календаря: скоро выезжать,
  /// ждём запчасть (машинка) и заявки без даты визита.
  ///
  /// Решения тут не принимаются, поэтому у строк нет ни кнопок, ни
  /// [_InboxEntry.onClear]: «Убрать разобранное» их не трогает, они
  /// уходят сами, когда визит поставлен, запчасть приехала или время
  /// визита прошло.
  List<_InboxEntry> _visitEntries(InboxSelection selection) {
    final unknown = context.tr('Клиент', 'Client');
    final entries = <_InboxEntry>[];

    for (final soon in selection.soonVisits) {
      final job = soon.job;
      final name = _jobName(job, unknown);
      final appliance =
          (job.primaryAppliance?.displayName ?? job.applianceType).trim();
      final address = job.workAddress.trim();
      entries.add(
        _InboxEntry(
          key: 'soon:${job.id}:${soon.visit.id}',
          icon: Icons.alarm_on,
          color: const Color(0xFFD84315),
          title: name,
          subtitle: _oneLine(
            [
              if (appliance.isNotEmpty) appliance,
              if (address.isNotEmpty) address,
            ].join(' · '),
            clientName: name,
          ),
          originLabel: context.tr('Скоро визит', 'Visit soon'),
          applianceType: job.applianceType,
          job: job,
          when: soon.visit.startAt,
          onTap: () => _openJob(job),
        ),
      );
    }

    for (final job in selection.delivery) {
      final name = _jobName(job, unknown);
      final appliance =
          (job.primaryAppliance?.displayName ?? job.applianceType).trim();
      final detail = job.description.trim();
      entries.add(
        _InboxEntry(
          key: 'part:${job.id}',
          icon: Icons.local_shipping,
          color: const Color(0xFF00695C),
          title: name,
          subtitle: _oneLine(
            [
              if (appliance.isNotEmpty) appliance,
              if (detail.isNotEmpty) detail,
            ].join(' · '),
            clientName: name,
          ),
          originLabel: context.tr('Ждём запчасть', 'Waiting for a part'),
          applianceType: job.applianceType,
          job: job,
          when: job.createdAt,
          onTap: () => _openJob(job),
        ),
      );
    }

    for (final job in selection.unscheduled) {
      final name = _jobName(job, unknown);
      final appliance =
          (job.primaryAppliance?.displayName ?? job.applianceType).trim();
      final detail = job.description.trim().isNotEmpty
          ? job.description.trim()
          : job.workAddress.trim();
      entries.add(
        _InboxEntry(
          key: 'noDate:${job.id}',
          icon: Icons.event_busy,
          color: const Color(0xFF1565C0),
          title: name,
          subtitle: _oneLine(
            [
              if (appliance.isNotEmpty) appliance,
              if (detail.isNotEmpty) detail,
            ].join(' · '),
            clientName: name,
          ),
          originLabel: context.tr('Без даты визита', 'No visit date'),
          applianceType: job.applianceType,
          job: job,
          when: job.createdAt,
          onTap: () => _openJob(job),
        ),
      );
    }

    return entries;
  }

  static int _byTimeDesc(_InboxEntry a, _InboxEntry b) {
    return (b.when ?? DateTime(0)).compareTo(a.when ?? DateTime(0));
  }

  Future<void> _clear(List<_InboxEntry> clearable) async {
    if (clearable.isEmpty || _clearing) return;
    final ok = await showConfirmCancelSheet(
      context,
      title: context.tr('Убрать разобранное', 'Clear handled'),
      message: context.tr(
        'Звонки, сообщения и сбои уйдут из списка, заявки станут подтверждёнными. '
        'Визиты и доставка останутся — они уходят сами.',
        'Calls, messages and failures leave the list, jobs become confirmed. '
        'Visits and delivery stay — they clear themselves.',
      ),
      confirmLabel: context.tr('Убрать', 'Clear'),
      cancelLabel: context.tr('Отмена', 'Cancel'),
    );
    if (!ok || !mounted) return;
    setState(() => _clearing = true);
    try {
      await Future.wait([for (final entry in clearable) entry.onClear!()]);
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Widget _empty() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 56, 28, 24),
      child: Column(
        children: [
          const Icon(
            Icons.check_circle_outline,
            size: 48,
            color: Color(0xFF9AA5B1),
          ),
          const SizedBox(height: 12),
          Text(
            context.tr('Решений не ждут', 'Nothing waiting for you'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: AppColors.ink,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            context.tr(
              'Звонки и сообщения — на вкладке «Связь»: новое помечено цифрой.',
              'Calls and messages live on the Связь tab — new items are counted there.',
            ),
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.inkMuted, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title, Color color, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 6),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 14,
                letterSpacing: 0.2,
                color: AppColors.ink,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 12,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _ReviewInboxStreams(
      builder: (jobs, calls, unreadMessages, failedSms, callsCutoff) {
        final selection = InboxSelection.of(
          jobs: jobs,
          calls: calls,
          unreadMessages: unreadMessages,
          failedSms: failedSms,
          callsCutoff: callsCutoff,
        );
        final attention = _attentionEntries(selection);
        final confirm = _confirmEntries(selection);
        final visits = _visitEntries(selection);
        final clearable = [
          for (final entry in [...attention, ...confirm])
            if (entry.onClear != null) entry,
        ];

        return SafeArea(
          bottom: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.tr('Уведомления', 'Notifications'),
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 22,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: clearable.isEmpty || _clearing
                          ? null
                          : () => _clear(clearable),
                      child: _clearing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              context.tr(
                                'Убрать разобранное',
                                'Clear handled',
                              ),
                            ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: CustomScrollView(
                  controller: widget.scrollController,
                  slivers: [
                    if (selection.isEmpty)
                      SliverToBoxAdapter(child: _empty()),
                    if (visits.isNotEmpty) ...[
                      SliverToBoxAdapter(
                        child: _sectionHeader(
                          context.tr(
                            'Визиты и доставка',
                            'Visits and delivery',
                          ),
                          const Color(0xFF00695C),
                          visits.length,
                        ),
                      ),
                      _rows(visits),
                    ],
                    if (attention.isNotEmpty) ...[
                      SliverToBoxAdapter(
                        child: _sectionHeader(
                          context.tr(
                            'Звонки и сообщения',
                            'Calls and messages',
                          ),
                          const Color(0xFFC62828),
                          attention.length,
                        ),
                      ),
                      _rows(attention),
                    ],
                    if (confirm.isNotEmpty) ...[
                      SliverToBoxAdapter(
                        child: _sectionHeader(
                          context.tr(
                            'Подтвердить заявки',
                            'Confirm the jobs',
                          ),
                          const Color(0xFF1565C0),
                          confirm.length,
                        ),
                      ),
                      _rows(confirm),
                    ],
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _rows(List<_InboxEntry> entries) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 0),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final entry = entries[index];
            return _InboxRow(
              entry: entry,
              busy: _busy.contains(entry.key),
              onAction: (action) => _run(entry.key, action.run),
            );
          },
          childCount: entries.length,
        ),
      ),
    );
  }
}

/// Лаконичная строка уведомления: слева значок события, в центре имя
/// клиента и в одну строчку суть уведомления, справа — быстрая кнопка.
class _InboxRow extends StatelessWidget {
  final _InboxEntry entry;
  final bool busy;
  final void Function(_InboxAction action) onAction;

  const _InboxRow({
    required this.entry,
    required this.busy,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final when = entry.when;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: busy ? null : entry.onTap,
          borderRadius: BorderRadius.circular(10),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: entry.color.withValues(alpha: 0.4),
                width: 1,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: entry.color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(entry.icon, size: 17, color: entry.color),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                entry.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13.5,
                                  height: 1.15,
                                  color: AppColors.ink,
                                ),
                              ),
                            ),
                            if (when != null) ...[
                              const SizedBox(width: 6),
                              Text(
                                DateFormat(
                                  'd MMM, HH:mm',
                                  AppLocale.instance.dateLocale,
                                ).format(when.toLocal()),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppColors.inkMuted,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: entry.originLabel,
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: entry.color,
                                ),
                              ),
                              if (entry.subtitle.isNotEmpty)
                                TextSpan(
                                  text: ' · ${entry.subtitle}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w500,
                                    color: AppColors.inkMuted,
                                  ),
                                ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5, height: 1.2),
                        ),
                      ],
                    ),
                  ),
                  if (entry.actions.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < entry.actions.length; i++) ...[
                          if (i > 0) const SizedBox(width: 4),
                          _button(entry.actions[i]),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _button(_InboxAction action) {
    final onPressed = busy ? null : () => onAction(action);
    if (action.iconOnly) {
      return SizedBox(
        width: 30,
        height: 30,
        child: IconButton(
          onPressed: onPressed,
          tooltip: action.label,
          padding: EdgeInsets.zero,
          style: IconButton.styleFrom(
            foregroundColor: action.color,
            backgroundColor: action.color.withValues(alpha: 0.1),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          icon: busy
              ? SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: action.color,
                  ),
                )
              : Icon(action.icon, size: 17),
        ),
      );
    }
    final child = busy
        ? SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: action.filled ? Colors.white : action.color,
            ),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(action.icon, size: 14),
              const SizedBox(width: 4),
              Text(
                action.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ],
          );
    const padding = EdgeInsets.symmetric(horizontal: 9, vertical: 6);
    if (action.filled) {
      return FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: action.color,
          foregroundColor: Colors.white,
          padding: padding,
          minimumSize: const Size(0, 30),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: child,
      );
    }
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: action.color,
        side: BorderSide(color: action.color.withValues(alpha: 0.5)),
        padding: padding,
        minimumSize: const Size(0, 30),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: child,
    );
  }
}

/// Потоки колокольчика. Создаются один раз на `State`: при каждом
/// перестроении подписываться заново нельзя — это замеряет
/// `runtime_performance_test`.
class _ReviewInboxStreams extends StatefulWidget {
  final Widget Function(
    List<Job> jobs,
    List<CallRecord> calls,
    List<SmsMessage> unreadMessages,
    List<SmsMessage> failedSms,
    DateTime callsCutoff,
  ) builder;

  const _ReviewInboxStreams({required this.builder});

  @override
  State<_ReviewInboxStreams> createState() => _ReviewInboxStreamsState();
}

class _ReviewInboxStreamsState extends State<_ReviewInboxStreams> {
  late final _jobs = JobService.streamAll();
  late final _calls = TwilioService.streamNewIncomingCalls();
  late final _unreadMessages = SmsService.streamUnreadInbound();
  late final _failedSms = SmsService.streamFailedOutbound();
  late final DateTime _callsCutoff = DateTime.now().subtract(
    const Duration(hours: 24),
  );

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Job>>(
      stream: _jobs,
      builder: (context, jobsSnap) {
        return StreamBuilder<List<CallRecord>>(
          stream: _calls,
          builder: (context, callsSnap) {
            return StreamBuilder<List<SmsMessage>>(
              stream: _unreadMessages,
              builder: (context, unreadSnap) {
                return StreamBuilder<List<SmsMessage>>(
                  stream: _failedSms,
                  builder: (context, failedSnap) {
                    return widget.builder(
                      jobsSnap.data ?? const <Job>[],
                      callsSnap.data ?? const <CallRecord>[],
                      unreadSnap.data ?? const <SmsMessage>[],
                      failedSnap.data ?? const <SmsMessage>[],
                      _callsCutoff,
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}
