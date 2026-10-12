import 'dart:async';

import 'package:flutter/material.dart';
import '../../../shared/widgets/confirm_action_sheet.dart';
import 'package:intl/intl.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../models/job.dart';
import '../../../services/job_service.dart';
import '../../../services/local_notification_service.dart';
import '../../../services/sms_service.dart';
import '../../../services/twilio_service.dart';
import '../../../shared/app_nav.dart';
import '../../../shared/widgets/appliance_picture.dart';
import '../../calls/call_review_page.dart';
import '../../jobs/email_offer_page.dart';
import '../../jobs/job_details/job_details_screen.dart';
import '../../jobs/sms_offer_page.dart';
import '../../messages/conversation_screen.dart';

/// Что колокольчик обязан показать — и ничего сверх этого.
///
/// Здесь нет ни входящих звонков «к сведению», ни просто непрочитанных
/// писем: про них говорят счётчики на вкладке «Связь». В колокольчике
/// остаётся только то, где без мастера дело не двинется, поэтому его
/// цифра читается однозначно — «столько решений ждут меня» — и доходит
/// до нуля. Пока сюда валились все события подряд, она не доходила
/// никогда и на неё перестали смотреть.
///
/// Отбор отделён от виджета нарочно: по нему считают бейдж, рисуют панель
/// и проверяет тест, и разойтись они не могут.
class InboxSelection {
  /// Ждут решения мастера.
  final List<SmsMessage> awaiting;
  final List<SmsMessage> smsOffers;
  final List<SmsMessage> emailOffers;

  /// Сломалось и само не починится.
  final List<SmsMessage> failedSms;
  final List<CallRecord> calls;

  /// Заявки от ИИ: их надо подтвердить.
  final List<Job> jobs;

  const InboxSelection({
    this.awaiting = const [],
    this.smsOffers = const [],
    this.emailOffers = const [],
    this.failedSms = const [],
    this.calls = const [],
    this.jobs = const [],
  });

  static InboxSelection of({
    List<Job> jobs = const [],
    List<CallRecord> calls = const [],
    List<SmsMessage> emailOffers = const [],
    List<SmsMessage> smsOffers = const [],
    List<SmsMessage> failedSms = const [],
    List<SmsMessage> awaitingSms = const [],
  }) {
    final liveJobs = <Job>[];
    final seenJobIds = <String>{};
    for (final job in jobs) {
      if (!job.needsReview || job.isDeleted) continue;
      if (JobStatuses.isClosed(job.status)) continue;
      if (!seenJobIds.add(job.id)) continue;
      liveJobs.add(job);
    }

    // Звонок, из которого уже родилась заявка, в колокольчике не нужен:
    // решение принимают по заявке, а сам звонок лежит в «Связи».
    final openCalls = <CallRecord>[];
    final seenCalls = <String>{};
    for (final call in calls) {
      if (call.reviewed || call.isDeleted) continue;
      if (!seenCalls.add(call.id)) continue;
      if ((call.createdJobId ?? '').trim().isNotEmpty) continue;
      openCalls.add(call);
    }

    // Из писем остаются только те, где сервер ждёт ответа «заявка или
    // нет». Просто непрочитанное письмо — это переписка, а не решение.
    final offers = [
      for (final message in emailOffers)
        if (message.emailOfferPending && !message.isDeleted) message,
    ];

    List<SmsMessage> live(List<SmsMessage> items) => [
          for (final message in items)
            if (!message.isDeleted) message,
        ];

    return InboxSelection(
      awaiting: live(awaitingSms),
      smsOffers: live(smsOffers),
      emailOffers: offers,
      failedSms: live(failedSms),
      calls: openCalls,
      jobs: liveJobs,
    );
  }

  int get decideCount => awaiting.length + smsOffers.length + emailOffers.length;

  int get attentionCount => failedSms.length + calls.length;

  int get confirmCount => jobs.length;

  int get total => decideCount + attentionCount + confirmCount;

  bool get isEmpty => total == 0;
}

class ReviewBellButton extends StatelessWidget {
  const ReviewBellButton({super.key});

  @override
  Widget build(BuildContext context) {
    return _ReviewInboxStreams(
      builder: (jobs, calls, emailOffers, smsOffers, failedSms, awaitingSms) {
        final count = InboxSelection.of(
          jobs: jobs,
          calls: calls,
          emailOffers: emailOffers,
          smsOffers: smsOffers,
          failedSms: failedSms,
          awaitingSms: awaitingSms,
        ).total;
        return IconButton(
          tooltip: context.tr('Уведомления', 'Notifications'),
          onPressed: () => showInbox(context),
          icon: Badge(
            isLabelVisible: count > 0,
            backgroundColor: Colors.orange,
            label: Text('$count'),
            child: Icon(
              count == 0
                  ? Icons.notifications_none
                  : Icons.notifications_active,
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
      backgroundColor: const Color(0xFFF4F6F8),
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

class ReviewInboxDrawer extends StatelessWidget {
  final BuildContext hostContext;
  final GlobalKey<ReviewInboxPanelState> panelKey;
  final VoidCallback onClose;

  const ReviewInboxDrawer({
    super.key,
    required this.hostContext,
    required this.panelKey,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return Drawer(
      width: width,
      backgroundColor: const Color(0xFFF4F6F8),
      shape: const RoundedRectangleBorder(),
      clipBehavior: Clip.hardEdge,
      child: RepaintBoundary(
        child: ReviewInboxPanel(
          key: panelKey,
          hostContext: hostContext,
          sheetContext: context,
          showCloseStrip: true,
          onClose: onClose,
        ),
      ),
    );
  }
}

class _InboxCloseBar extends StatefulWidget {
  final VoidCallback onClose;

  const _InboxCloseBar({required this.onClose});

  @override
  State<_InboxCloseBar> createState() => _InboxCloseBarState();
}

class _InboxCloseBarState extends State<_InboxCloseBar> {
  double _dragDx = 0;
  bool _closing = false;

  void _close() {
    if (_closing) return;
    _closing = true;
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => _dragDx = 0,
      onPointerMove: (event) => _dragDx += event.delta.dx,
      onPointerUp: (_) {
        if (_dragDx > 36) _close();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => _dragDx = 0,
        onHorizontalDragUpdate: (details) => _dragDx += details.delta.dx,
        onHorizontalDragEnd: (details) {
          final velocity = details.primaryVelocity ?? 0;
          if (velocity > 180 || _dragDx > 28) {
            _close();
          }
        },
        onTap: _close,
        child: ColoredBox(
          color: const Color(0xFFF4F6F8),
          child: SizedBox(width: double.infinity, height: 64 + bottom),
        ),
      ),
    );
  }
}

class ReviewBellPickleIcon extends StatelessWidget {
  final Color color;
  final double size;
  final AlignmentGeometry badgeAlignment;

  const ReviewBellPickleIcon({
    super.key,
    this.color = Colors.white,
    this.size = 22,
    this.badgeAlignment = Alignment.topRight,
  });

  @override
  Widget build(BuildContext context) {
    return _ReviewInboxStreams(
      builder: (jobs, calls, emailOffers, smsOffers, failedSms, awaitingSms) {
        final count = InboxSelection.of(
          jobs: jobs,
          calls: calls,
          emailOffers: emailOffers,
          smsOffers: smsOffers,
          failedSms: failedSms,
          awaitingSms: awaitingSms,
        ).total;
        return Badge(
          isLabelVisible: count > 0,
          alignment: badgeAlignment,
          backgroundColor: const Color(0xFFE11D48),
          label: Text(
            '$count',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w900,
              color: Colors.white,
            ),
          ),
          child: Icon(
            count == 0 ? Icons.notifications_none : Icons.notifications_active,
            color: count == 0 ? color : const Color(0xFF9A1B1B),
            size: size,
          ),
        );
      },
    );
  }
}

/// Кнопка под строкой: решение принимается здесь, не открывая экран.
class _InboxAction {
  final String label;
  final IconData icon;
  final Color color;
  final bool filled;
  final Future<void> Function() run;

  const _InboxAction({
    required this.label,
    required this.icon,
    required this.color,
    required this.run,
    this.filled = false,
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
  final name = _textFrom(data, const ['client_name', 'clientName', 'name']);
  return name.isEmpty ? fallback : name;
}

String _applianceOf(Map<String, dynamic>? data) {
  return _textFrom(data, const [
    'appliance_type',
    'applianceType',
    'kind_of_appliance',
  ]);
}

Map<String, dynamic>? _callExtracted(CallRecord call) {
  final top = call.extractedData;
  if (top != null && top.isNotEmpty) return top;
  final nested = call.aiReception?['extracted'];
  if (nested is Map) return Map<String, dynamic>.from(nested);
  return null;
}

class ReviewInboxPanel extends StatefulWidget {
  final BuildContext hostContext;
  final BuildContext sheetContext;
  final ScrollController? scrollController;
  final bool showCloseStrip;
  final VoidCallback? onClose;

  const ReviewInboxPanel({
    super.key,
    required this.hostContext,
    required this.sheetContext,
    this.scrollController,
    this.showCloseStrip = false,
    this.onClose,
  });

  @override
  State<ReviewInboxPanel> createState() => ReviewInboxPanelState();
}

class ReviewInboxPanelState extends State<ReviewInboxPanel> {
  bool _clearing = false;
  final Set<String> _busy = <String>{};

  void onHostOpened() {}
  void onHostClosed() {}

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

  void _toast(String text) {
    final messenger = ScaffoldMessenger.maybeOf(widget.hostContext);
    messenger?.showSnackBar(SnackBar(content: Text(text)));
  }

  void _openCall(CallRecord call) {
    unawaited(
      _closeInboxThen(() async {
        final id = call.id;
        final phone = call.isIncoming ? call.fromNumber : call.toNumber;
        unawaited(TwilioService.markReviewed(id));
        unawaited(
          LocalNotificationService.dismissInboxPayload({
            'type': 'call',
            'callSid': id,
            'callId': id,
            'from': phone,
          }),
        );
        await CallReviewPage.open(widget.hostContext, callId: id, call: call);
      }),
    );
  }

  // ——— Ждёт решения ———

  List<_InboxEntry> _decideEntries(InboxSelection selection) {
    final host = widget.hostContext;
    final unknown = context.tr('Клиент', 'Client');
    final entries = <_InboxEntry>[];

    // Сообщения, которые сервер придумал, но не отправил. Текст виден
    // целиком: «Отправить или нет» вслепую не решают.
    for (final message in selection.awaiting) {
      final phone = message.to.trim();
      final key = 'outbox:${message.id}';
      entries.add(
        _InboxEntry(
          key: key,
          icon: Icons.schedule_send_rounded,
          color: const Color(0xFFF59E0B),
          title: phone.isEmpty ? unknown : phone,
          subtitle: message.displayBody.trim(),
          originLabel: context.tr('Ждёт отправки', 'Waiting to be sent'),
          when: message.createdAt,
          onTap: () {
            unawaited(
              _closeInboxThen(() async {
                await ConversationScreen.open(
                  host,
                  phoneNumber: phone,
                  clientId: message.clientId,
                );
              }),
            );
          },
          actions: [
            _InboxAction(
              label: context.tr('Отправить', 'Send'),
              icon: Icons.send_rounded,
              color: const Color(0xFF2E7D32),
              filled: true,
              run: () async {
                // Текст берём до ожидания: решение может прилететь уже
                // после того, как панель закрыли.
                final failed = context.tr(
                  'Не удалось отправить — откройте переписку',
                  'Could not send — open the conversation',
                );
                final sent = await SmsService.decideOutbox(
                  message.id,
                  send: true,
                );
                if (!sent && mounted) _toast(failed);
              },
            ),
            _InboxAction(
              label: context.tr('Не отправлять', 'Do not send'),
              icon: Icons.block,
              color: const Color(0xFFC62828),
              run: () => SmsService.decideOutbox(message.id, send: false),
            ),
          ],
        ),
      );
    }

    for (final offer in selection.smsOffers) {
      final extracted = offer.extractedData;
      final phone = offer.from;
      entries.add(
        _InboxEntry(
          key: 'sms:${offer.id}',
          icon: Icons.sms,
          color: const Color(0xFF0277BD),
          title: _ownerName(extracted, phone.isEmpty ? unknown : phone),
          subtitle: offer.displayBody.trim(),
          originLabel: context.tr('SMS о ремонте', 'Repair SMS'),
          applianceType: _applianceOf(extracted),
          when: offer.createdAt,
          onTap: () {
            unawaited(
              _closeInboxThen(() async {
                await SmsOfferPage.open(
                  host,
                  messageId: offer.id,
                  message: offer,
                );
              }),
            );
          },
          actions: [
            _InboxAction(
              label: context.tr('Создать заявку', 'Create a job'),
              icon: Icons.add_task,
              color: const Color(0xFF0277BD),
              filled: true,
              run: () async {
                await _closeInboxThen(() async {
                  await SmsOfferPage.open(
                    host,
                    messageId: offer.id,
                    message: offer,
                  );
                });
              },
            ),
            _InboxAction(
              label: context.tr('Не заявка', 'Not a job'),
              icon: Icons.close,
              color: const Color(0xFF616161),
              run: () => SmsService.dismissSmsOffer(offer.id),
            ),
          ],
        ),
      );
    }

    for (final offer in selection.emailOffers) {
      final extracted = offer.extractedData;
      final from = offer.counterpartEmail.isNotEmpty
          ? offer.counterpartEmail
          : offer.from;
      final website = offer.isWebsiteFormMail;
      final subject = offer.subject.trim();
      entries.add(
        _InboxEntry(
          key: 'email:${offer.id}',
          icon: website ? Icons.language : Icons.mark_email_unread_outlined,
          color: const Color(0xFF2E7D32),
          title: website
              ? kWebsiteInboxTitle
              : _ownerName(extracted, from.isEmpty ? unknown : from),
          subtitle: subject.isNotEmpty ? subject : offer.displayBody.trim(),
          originLabel: website
              ? context.tr('Заявка с сайта', 'Website request')
              : context.tr('Письмо о ремонте', 'Repair email'),
          applianceType: _applianceOf(extracted),
          when: offer.createdAt,
          onTap: () {
            unawaited(
              _closeInboxThen(() async {
                await EmailOfferPage.open(
                  host,
                  messageId: offer.id,
                  message: offer,
                );
              }),
            );
          },
          actions: [
            _InboxAction(
              label: context.tr('Создать заявку', 'Create a job'),
              icon: Icons.add_task,
              color: const Color(0xFF2E7D32),
              filled: true,
              run: () async {
                await _closeInboxThen(() async {
                  await EmailOfferPage.open(
                    host,
                    messageId: offer.id,
                    message: offer,
                  );
                });
              },
            ),
            _InboxAction(
              label: context.tr('Не заявка', 'Not a job'),
              icon: Icons.close,
              color: const Color(0xFF616161),
              run: () => SmsService.dismissEmailOffer(offer.id),
            ),
          ],
        ),
      );
    }

    entries.sort(_byTimeDesc);
    return entries;
  }

  // ——— Надо разобраться ———

  List<_InboxEntry> _attentionEntries(InboxSelection selection) {
    final host = widget.hostContext;
    final unknown = context.tr('Клиент', 'Client');
    final entries = <_InboxEntry>[];

    for (final message in selection.failedSms) {
      final phone = message.to.trim();
      entries.add(
        _InboxEntry(
          key: 'failed:${message.id}',
          icon: Icons.sms_failed,
          color: const Color(0xFFC62828),
          title: phone.isEmpty ? unknown : phone,
          subtitle: message.failureReason,
          originLabel: context.tr('SMS не дошло', 'SMS not delivered'),
          when: message.createdAt,
          onTap: () {
            unawaited(
              _closeInboxThen(() async {
                unawaited(SmsService.dismissFailure(message.id));
                await ConversationScreen.open(
                  host,
                  phoneNumber: phone,
                  clientId: message.clientId,
                );
              }),
            );
          },
          actions: [
            _InboxAction(
              label: context.tr('Открыть переписку', 'Open the chat'),
              icon: Icons.chat_bubble_outline,
              color: const Color(0xFFC62828),
              filled: true,
              run: () async {
                await _closeInboxThen(() async {
                  unawaited(SmsService.dismissFailure(message.id));
                  await ConversationScreen.open(
                    host,
                    phoneNumber: phone,
                    clientId: message.clientId,
                  );
                });
              },
            ),
            _InboxAction(
              label: context.tr('Убрать', 'Dismiss'),
              icon: Icons.done,
              color: const Color(0xFF616161),
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
      final declined = call.serviceDeclined;
      final reason = call.declineReason.trim();
      entries.add(
        _InboxEntry(
          key: 'call:${call.id}',
          icon: declined ? Icons.phone_disabled : Icons.phone_in_talk,
          color: declined
              ? const Color(0xFF616161)
              : const Color(0xFFEF6C00),
          title: _ownerName(extracted, phone.isEmpty ? unknown : phone),
          subtitle: declined
              ? (reason.isNotEmpty
                  ? reason
                  : context.tr(
                      'Секретарь отказала — заявки нет',
                      'Secretary declined — no job',
                    ))
              : context.tr(
                  'Звонок разобран, заявка не создана',
                  'Call handled, no job created',
                ),
          originLabel: context.tr('Звонок без заявки', 'Call without a job'),
          applianceType: declined ? '' : _applianceOf(extracted),
          when: call.startTime,
          onTap: () => _openCall(call),
          actions: [
            _InboxAction(
              label: context.tr('Послушать', 'Listen'),
              icon: Icons.play_arrow_rounded,
              color: const Color(0xFFEF6C00),
              filled: true,
              run: () async {
                _openCall(call);
              },
            ),
            _InboxAction(
              label: context.tr('Убрать', 'Dismiss'),
              icon: Icons.done,
              color: const Color(0xFF616161),
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
      final name = job.contactName.trim().isEmpty
          ? (job.clientName.trim().isEmpty ? unknown : job.clientName.trim())
          : job.contactName.trim();
      final fromWebsite = job.intakeSource == 'website';
      final fromEmail = job.intakeSource == 'email' || fromWebsite;
      final fromPhone = job.intakeSource == 'phone';
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
          applianceType: job.applianceType,
          when: job.createdAt,
          originLabel: fromWebsite
              ? context.tr('Сайт', 'Website')
              : fromEmail
                  ? context.tr('Почта', 'Email')
                  : fromPhone
                      ? context.tr('Телефон', 'Phone')
                      : context.tr('SMS', 'SMS'),
          onTap: () {
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
          },
          onClear: () => JobService.markReviewed(job.id),
        ),
      );
    }
    entries.sort(_byTimeDesc);
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
        'Звонки и сбои уйдут из списка, заявки станут подтверждёнными. '
        'То, что ждёт решения, останется.',
        'Calls and failures leave the list, jobs become confirmed. '
        'Anything waiting for your decision stays.',
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
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: Color(0xFF334155),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            context.tr(
              'Звонки и сообщения — на вкладке «Связь»: новое помечено цифрой.',
              'Calls and messages live on the Связь tab — new items are counted there.',
            ),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black54, fontSize: 14),
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
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 14,
                letterSpacing: 0.2,
                color: Color(0xFF334155),
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
      builder: (jobs, calls, emailOffers, smsOffers, failedSms, awaitingSms) {
        final selection = InboxSelection.of(
          jobs: jobs,
          calls: calls,
          emailOffers: emailOffers,
          smsOffers: smsOffers,
          failedSms: failedSms,
          awaitingSms: awaitingSms,
        );
        final decide = _decideEntries(selection);
        final attention = _attentionEntries(selection);
        final confirm = _confirmEntries(selection);
        final clearable = [
          for (final entry in [...attention, ...confirm])
            if (entry.onClear != null) entry,
        ];
        final width = MediaQuery.sizeOf(context).width;
        final columns = width >= 520 ? 4 : 3;

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
                    if (decide.isNotEmpty) ...[
                      SliverToBoxAdapter(
                        child: _sectionHeader(
                          context.tr('Ждёт решения', 'Waiting for you'),
                          const Color(0xFFF59E0B),
                          decide.length,
                        ),
                      ),
                      _rows(decide),
                    ],
                    if (attention.isNotEmpty) ...[
                      SliverToBoxAdapter(
                        child: _sectionHeader(
                          context.tr('Надо разобраться', 'Needs a look'),
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
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(10, 2, 10, 0),
                        sliver: SliverGrid(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: columns,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                            childAspectRatio: 0.70,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            (context, index) =>
                                _BellCard(entry: confirm[index]),
                            childCount: confirm.length,
                          ),
                        ),
                      ),
                    ],
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                ),
              ),
              if (widget.showCloseStrip && widget.onClose != null)
                _InboxCloseBar(onClose: widget.onClose!),
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

/// Строка решения: кто, что сказал и две кнопки. Карточка-плитка этого не
/// умела — текст в неё не влезал, и «Отправить или нет» приходилось решать,
/// открыв переписку.
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
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: busy ? null : entry.onTap,
          borderRadius: BorderRadius.circular(12),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: entry.color.withValues(alpha: 0.55)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _leading(),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    entry.originLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 0.3,
                                      color: entry.color,
                                    ),
                                  ),
                                ),
                                if (when != null)
                                  Text(
                                    DateFormat(
                                      'd MMM, HH:mm',
                                      AppLocale.instance.dateLocale,
                                    ).format(when.toLocal()),
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF64748B),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              entry.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 15,
                                color: Color(0xFF111111),
                              ),
                            ),
                            if (entry.subtitle.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                entry.subtitle,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  height: 1.25,
                                  color: Color(0xFF334155),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (entry.actions.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        for (final action in entry.actions) ...[
                          _button(action),
                          const SizedBox(width: 8),
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

  Widget _leading() {
    final appliance = entry.applianceType.trim();
    if (appliance.isNotEmpty) {
      return SizedBox(
        width: 48,
        height: 48,
        child: AppliancePicture(type: appliance, fillSlot: true),
      );
    }
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: entry.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(entry.icon, size: 24, color: entry.color),
    );
  }

  Widget _button(_InboxAction action) {
    final child = busy
        ? SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: action.filled ? Colors.white : action.color,
            ),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(action.icon, size: 16),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  action.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          );
    final onPressed = busy ? null : () => onAction(action);
    const padding = EdgeInsets.symmetric(horizontal: 12, vertical: 8);
    if (action.filled) {
      return FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: action.color,
          foregroundColor: Colors.white,
          padding: padding,
          minimumSize: const Size(0, 36),
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
        minimumSize: const Size(0, 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: child,
    );
  }
}

/// Плитка с картинкой техники: ею остались только заявки на подтверждение.
/// Их бывает много, и по картинке они узнаются быстрее, чем по строке.
class _BellCard extends StatelessWidget {
  final _InboxEntry entry;

  const _BellCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFFFF4D6),
      elevation: 0,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: entry.onTap,
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: entry.color, width: 2.2),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
            child: Column(
              children: [
                Text(
                  context.tr('НОВОЕ', 'NEW'),
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.6,
                    color: entry.color,
                  ),
                ),
                Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                    height: 1.1,
                    color: Color(0xFF111111),
                  ),
                ),
                if (entry.when != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    DateFormat(
                      'd MMM, HH:mm',
                      AppLocale.instance.dateLocale,
                    ).format(entry.when!.toLocal()),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 10,
                      height: 1.1,
                      color: Color(0xFF616161),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (entry.originLabel.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(entry.icon, size: 12, color: entry.color),
                      const SizedBox(width: 3),
                      Flexible(
                        child: Text(
                          entry.originLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            height: 1.1,
                            fontWeight: FontWeight.w800,
                            color: entry.color,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 4),
                Expanded(
                  child: entry.applianceType.trim().isNotEmpty
                      ? Stack(
                          children: [
                            Positioned.fill(
                              child: AppliancePicture(
                                type: entry.applianceType,
                                fillSlot: true,
                              ),
                            ),
                            Positioned(
                              right: 2,
                              bottom: 2,
                              child: Container(
                                padding: const EdgeInsets.all(3),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: entry.color),
                                ),
                                child: Icon(
                                  entry.icon,
                                  size: 14,
                                  color: entry.color,
                                ),
                              ),
                            ),
                          ],
                        )
                      : Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: entry.color.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            entry.icon,
                            size: 32,
                            color: entry.color,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Потоки колокольчика. Создаются один раз на `State`: при каждом
/// перестроении подписываться заново нельзя — это замеряет
/// `runtime_performance_test`.
///
/// Звонки «в обработке» отсюда убраны вместе с остальным «к сведению»:
/// пока секретарь разбирает запись, это видно на вкладке «Звонки»
/// («ИИ обрабатывает»), а решение появится, когда разбор закончится.
class _ReviewInboxStreams extends StatefulWidget {
  final Widget Function(
    List<Job> jobs,
    List<CallRecord> calls,
    List<SmsMessage> emailOffers,
    List<SmsMessage> smsOffers,
    List<SmsMessage> failedSms,
    List<SmsMessage> awaitingSms,
  ) builder;

  const _ReviewInboxStreams({required this.builder});

  @override
  State<_ReviewInboxStreams> createState() => _ReviewInboxStreamsState();
}

class _ReviewInboxStreamsState extends State<_ReviewInboxStreams> {
  late final _jobs = JobService.streamNeedsReview();
  late final _calls = TwilioService.getPendingReviewCalls();
  late final _emailOffers = SmsService.streamEmailOffers();
  late final _smsOffers = SmsService.streamSmsOffers();
  late final _failedSms = SmsService.streamFailedOutbound();
  late final _awaitingSms = SmsService.streamAwaitingApproval();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Job>>(
      stream: _jobs,
      builder: (context, jobsSnap) {
        return StreamBuilder<List<CallRecord>>(
          stream: _calls,
          builder: (context, callsSnap) {
            return StreamBuilder<List<SmsMessage>>(
              stream: _emailOffers,
              builder: (context, offersSnap) {
                return StreamBuilder<List<SmsMessage>>(
                  stream: _smsOffers,
                  builder: (context, smsOffersSnap) {
                    return StreamBuilder<List<SmsMessage>>(
                      stream: _failedSms,
                      builder: (context, failedSnap) {
                        return StreamBuilder<List<SmsMessage>>(
                          stream: _awaitingSms,
                          builder: (context, awaitingSnap) {
                            return widget.builder(
                              jobsSnap.data ?? const <Job>[],
                              callsSnap.data ?? const <CallRecord>[],
                              offersSnap.data ?? const <SmsMessage>[],
                              smsOffersSnap.data ?? const <SmsMessage>[],
                              failedSnap.data ?? const <SmsMessage>[],
                              awaitingSnap.data ?? const <SmsMessage>[],
                            );
                          },
                        );
                      },
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
