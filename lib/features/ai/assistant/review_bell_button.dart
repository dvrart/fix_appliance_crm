import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/app_feedback.dart';
import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../models/job.dart';
import '../../../models/secretary_lesson.dart';
import '../../../services/job_service.dart';
import '../../../services/local_notification_service.dart';
import '../../../services/sms_service.dart';
import '../../../services/secretary_learn_service.dart';
import '../../../services/twilio_service.dart';
import '../../../shared/widgets/appliance_picture.dart';
import '../../calls/call_review_page.dart';
import '../../jobs/email_offer_page.dart';
import '../../jobs/job_details/job_details_screen.dart';
import '../../jobs/sms_offer_page.dart';
import '../../messages/conversation_screen.dart';

class ReviewBellButton extends StatelessWidget {
  const ReviewBellButton({super.key});

  static String? _linkedJobId(CallRecord call) {
    final id = (call.createdJobId ?? '').trim();
    return id.isEmpty ? null : id;
  }

  static int inboxCount({
    required List<Job> jobs,
    required List<CallRecord> pending,
    required List<CallRecord> processing,
    required List<SmsMessage> emailOffers,
    List<SmsMessage> smsOffers = const [],
    List<SecretaryLesson> lessons = const [],
  }) {
    var n = emailOffers.length +
        smsOffers.length +
        lessons.where((l) => l.isPending && l.isIssue).length;
    final seenJobIds = <String>{};
    // Count jobs with needsReview (legacy auto-created or email/website)
    for (final job in jobs) {
      if (job.isDeleted || JobStatuses.isClosed(job.status)) continue;
      seenJobIds.add(job.id);
      n += 1;
    }
    // Count calls — deduplicate with linked jobs
    final seen = <String>{};
    void consider(CallRecord call) {
      if (!seen.add(call.id) || call.reviewed) return;
      final jobId = _linkedJobId(call);
      if (jobId != null) {
        // Call has a linked job — only count if job not already in list
        if (seenJobIds.add(jobId)) n += 1;
        return;
      }
      n += 1;
    }
    for (final call in processing) {
      consider(call);
    }
    for (final call in pending) {
      consider(call);
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    return _ReviewInboxStreams(
      builder: (jobs, pending, processing, lessons, emailOffers, _, smsOffers) {
        final count = inboxCount(
          jobs: jobs,
          pending: pending,
          processing: processing,
          emailOffers: emailOffers,
          smsOffers: smsOffers,
          lessons: lessons,
        );
        return IconButton(
          tooltip: context.tr('Уведомления', 'Notifications'),
          onPressed: () => _openSheet(context),
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

  void _openSheet(BuildContext hostContext) {
    ReviewBellButton.showInbox(hostContext);
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
      builder: (jobs, pending, processing, lessons, emailOffers, _, smsOffers) {
        final count = ReviewBellButton.inboxCount(
          jobs: jobs,
          pending: pending,
          processing: processing,
          emailOffers: emailOffers,
          smsOffers: smsOffers,
          lessons: lessons,
        );
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

class _InboxItem {
  final IconData icon;
  final Color color;
  final String name;
  final String applianceType;
  final DateTime? when;
  final VoidCallback? onTap;
  final bool busy;
  final Future<void> Function()? onClear;
  final String originLabel;
  final IconData? originIcon;
  final bool isNew;

  const _InboxItem({
    required this.icon,
    required this.color,
    required this.name,
    this.applianceType = '',
    this.when,
    this.onTap,
    this.busy = false,
    this.onClear,
    this.originLabel = '',
    this.originIcon,
    this.isNew = true,
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
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!host.mounted) return;
    await open();
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

  void _openLinkedJob(CallRecord call, {Job? job}) {
    final jobId = ReviewBellButton._linkedJobId(call);
    if (jobId == null) {
      _openCall(call);
      return;
    }
    unawaited(
      _closeInboxThen(() async {
        final found = job ?? await JobService.getById(jobId);
        if (found == null) {
          await CallReviewPage.open(
            widget.hostContext,
            callId: call.id,
            call: call,
          );
          return;
        }
        unawaited(TwilioService.markReviewed(call.id));
        await Navigator.of(widget.hostContext, rootNavigator: true).push(
          MaterialPageRoute(
            builder: (_) => JobDetailsScreen(
              jobId: found.id,
              clientId: found.clientId,
              jobData: found.toMap(),
            ),
          ),
        );
      }),
    );
  }

  List<_InboxItem> _items({
    required List<Job> jobs,
    required List<CallRecord> pending,
    required List<CallRecord> processing,
    required List<SecretaryLesson> lessons,
    required List<SmsMessage> emailOffers,
    required List<SmsMessage> smsOffers,
  }) {
    final host = widget.hostContext;
    final items = <_InboxItem>[];
    final seenCalls = <String>{};
    final seenJobIds = <String>{};
    final seenEmailJobs = <String>{};
    final jobsById = {for (final job in jobs) job.id: job};
    final unknown = context.tr('Клиент', 'Client');

    // SMS offers
    for (final offer in smsOffers) {
      final extracted = offer.extractedData;
      final phone = offer.from;
      items.add(
        _InboxItem(
          icon: Icons.sms,
          color: const Color(0xFF0277BD),
          name: _ownerName(extracted, phone.isEmpty ? unknown : phone),
          applianceType: _applianceOf(extracted),
          when: offer.createdAt,
          originLabel: context.tr('SMS · создать', 'SMS · create'),
          originIcon: Icons.sms,
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
          onClear: () => SmsService.dismissSmsOffer(offer.id),
        ),
      );
    }

    // Email offers
    for (final offer in emailOffers) {
      final extracted = offer.extractedData;
      final from = offer.counterpartEmail.isNotEmpty
          ? offer.counterpartEmail
          : offer.from;
      final isOffer = offer.emailOfferPending;
      final website = offer.isWebsiteFormMail;
      items.add(
        _InboxItem(
          icon: isOffer
              ? Icons.mark_email_unread_outlined
              : Icons.email_outlined,
          color: const Color(0xFF2E7D32),
          name: website
              ? kWebsiteInboxTitle
              : _ownerName(extracted, from.isEmpty ? unknown : from),
          applianceType: _applianceOf(extracted),
          when: offer.createdAt,
          originLabel: website
              ? context.tr('Письмо с сайта', 'Website email')
              : isOffer
                  ? context.tr('Письмо · создать', 'Email · create')
                  : context.tr('Письмо', 'Email'),
          originIcon: website ? Icons.language : Icons.email_outlined,
          onTap: () {
            unawaited(
              _closeInboxThen(() async {
                if (isOffer) {
                  await EmailOfferPage.open(
                    host,
                    messageId: offer.id,
                    message: offer,
                  );
                  return;
                }
                unawaited(SmsService.markEmailSeen(offer.id));
                await ConversationScreen.open(
                  host,
                  email: website ? null : from,
                  clientId: website ? null : offer.clientId,
                  contactName: website
                      ? kWebsiteInboxTitle
                      : _ownerName(extracted, from),
                  websiteInbox: website,
                  initialChannel: ConversationChannel.email,
                );
              }),
            );
          },
          onClear: () => isOffer
              ? SmsService.dismissEmailOffer(offer.id)
              : SmsService.markEmailSeen(offer.id),
        ),
      );
    }

    // Jobs with needsReview (email/website/legacy phone)
    for (final job in jobs) {
      if (job.isDeleted || JobStatuses.isClosed(job.status)) continue;
      if (!seenJobIds.add(job.id)) continue;
      if (job.intakeSource == 'email' || job.intakeSource == 'website') {
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
        final key =
            '${from.isEmpty ? job.clientName.trim().toLowerCase() : from}|$minute|$desc';
        if (key != '||' && !seenEmailJobs.add(key)) continue;
      }
      final name = job.contactName.trim().isEmpty
          ? (job.clientName.trim().isEmpty ? unknown : job.clientName.trim())
          : job.contactName.trim();
      final fromWebsite = job.intakeSource == 'website';
      final fromEmail = job.intakeSource == 'email' || fromWebsite;
      final fromPhone = job.intakeSource == 'phone';
      items.add(
        _InboxItem(
          icon: fromWebsite
              ? Icons.language
              : fromEmail
              ? Icons.email_outlined
              : fromPhone
              ? Icons.phone_in_talk
              : Icons.assignment_late,
          color: fromEmail ? const Color(0xFF2E7D32) : const Color(0xFF1565C0),
          name: name,
          applianceType: job.applianceType,
          when: job.createdAt,
          originLabel: fromWebsite
              ? context.tr('Сайт', 'Website')
              : fromEmail
              ? context.tr('Почта', 'Email')
              : fromPhone
              ? context.tr('Телефон', 'Phone')
              : '',
          originIcon: fromWebsite
              ? Icons.language
              : fromEmail
              ? Icons.email_outlined
              : fromPhone
              ? Icons.phone_in_talk
              : null,
          onTap: () {
            unawaited(
              _closeInboxThen(() async {
                await Navigator.of(host, rootNavigator: true).push(
                  MaterialPageRoute(
                    builder: (_) => JobDetailsScreen(
                      jobId: job.id,
                      clientId: job.clientId,
                      jobData: job.toMap(),
                    ),
                  ),
                );
              }),
            );
          },
          onClear: () => JobService.markReviewed(job.id),
        ),
      );
    }

    // Calls (all unreviewed calls — including those linked to legacy jobs)
    void addCall(CallRecord call, {required bool busy}) {
      if (call.reviewed || !seenCalls.add(call.id)) return;
      final extracted = _callExtracted(call);
      final phone = call.isIncoming ? call.fromNumber : call.toNumber;
      final jobId = ReviewBellButton._linkedJobId(call);
      if (jobId != null) {
        // Legacy: call already has a linked job — show the job card
        if (!seenJobIds.add(jobId)) return;
        final job = jobsById[jobId];
        items.add(
          _InboxItem(
            icon: Icons.phone_in_talk,
            color: const Color(0xFF1565C0),
            name: _ownerName(
              extracted,
              job?.contactName.trim().isNotEmpty == true
                  ? job!.contactName.trim()
                  : (phone.isEmpty ? unknown : phone),
            ),
            applianceType: job?.applianceType ?? _applianceOf(extracted),
            when: job?.createdAt ?? call.startTime,
            originLabel: context.tr('Телефон', 'Phone'),
            originIcon: Icons.phone_in_talk,
            busy: busy,
            onTap: () => _openLinkedJob(call, job: job),
            onClear: () => TwilioService.markReviewed(call.id),
          ),
        );
        return;
      }
      final declined = call.serviceDeclined;
      items.add(
        _InboxItem(
          icon: busy
              ? Icons.hourglass_top
              : (declined ? Icons.phone_disabled : Icons.phone_in_talk),
          color: busy
              ? const Color(0xFF7B1FA2)
              : (declined ? const Color(0xFF616161) : const Color(0xFFEF6C00)),
          name: declined
              ? '${_ownerName(extracted, phone.isEmpty ? unknown : phone)} · ${context.tr('без заявки', 'no job')}'
              : _ownerName(extracted, phone.isEmpty ? unknown : phone),
          applianceType: declined ? '' : _applianceOf(extracted),
          when: call.startTime,
          busy: busy,
          onTap: () => _openCall(call),
          onClear: () => TwilioService.markReviewed(call.id),
        ),
      );
    }

    for (final call in processing) {
      addCall(call, busy: true);
    }
    for (final call in pending) {
      addCall(call, busy: false);
    }

    // Secretary lessons (pending issues)
    for (final lesson in lessons) {
      if (!lesson.isPending || !lesson.isIssue) continue;
      final title = lesson.problemRu.trim().isNotEmpty
          ? lesson.problemRu.trim()
          : lesson.titleRu.trim();
      items.add(
        _InboxItem(
          icon: Icons.psychology_outlined,
          color: lesson.severity == 'fail'
              ? const Color(0xFFC62828)
              : const Color(0xFFE65100),
          name: title.isEmpty
              ? context.tr('Ошибка секретаря', 'Secretary error')
              : title,
          when: lesson.createdAt,
          originLabel: context.tr('Секретарь', 'Secretary'),
          originIcon: Icons.phone_in_talk,
          onTap: () {
            unawaited(
              _closeInboxThen(
                () => _SecretaryLessonSheet.show(widget.hostContext, lesson),
              ),
            );
          },
          onClear: () => SecretaryLearnService.reject(lesson),
        ),
      );
    }

    // Sort by time: newest first
    items.sort(
      (a, b) => (b.when ?? DateTime(0)).compareTo(a.when ?? DateTime(0)),
    );
    return items;
  }

  Future<void> _clear(List<_InboxItem> items) async {
    final clearable = [
      for (final item in items)
        if (item.onClear != null) item,
    ];
    if (clearable.isEmpty || _clearing) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.tr('Очистить уведомления', 'Clear notifications')),
        content: Text(
          context.tr(
            'Убрать их с колокольчика? Разборы секретаря в скрипт не попадут.',
            'Remove them from the bell? Secretary reviews will not enter the script.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.tr('Отмена', 'Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.tr('Очистить', 'Clear')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _clearing = true);
    try {
      await Future.wait([for (final item in clearable) item.onClear!()]);
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Widget _body(List<_InboxItem> items, int columns) {
    if (items.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 48),
          Text(
            context.tr(
              'Нет новых уведомлений',
              'No new notifications',
            ),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black54, fontSize: 16),
          ),
        ],
      );
    }
    return GridView.builder(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 24),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.70,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) => _BellCard(item: items[index]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _ReviewInboxStreams(
      builder: (jobs, pendingAll, processing, lessons, emailOffers, _, smsOffers) {
        final items = _items(
          jobs: jobs,
          pending: pendingAll,
          processing: processing,
          lessons: lessons,
          emailOffers: emailOffers,
          smsOffers: smsOffers,
        );
        final width = MediaQuery.sizeOf(context).width;
        final columns = width >= 520 ? 4 : 3;
        final canClear = items.any((item) => item.onClear != null);

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
                      onPressed: !canClear || _clearing
                          ? null
                          : () => _clear(items),
                      child: _clearing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            )
                          : Text(context.tr('Очистить', 'Clear')),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(child: _body(items, columns)),
              if (widget.showCloseStrip && widget.onClose != null)
                _InboxCloseBar(onClose: widget.onClose!),
            ],
          ),
        );
      },
    );
  }
}

class _BellCard extends StatelessWidget {
  final _InboxItem item;

  const _BellCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: item.isNew ? const Color(0xFFFFF4D6) : Colors.white,
      elevation: 0,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: item.onTap,
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: item.color,
              width: item.isNew ? 2.2 : 1.4,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
            child: Column(
              children: [
                if (item.isNew)
                  Text(
                    context.tr('НОВОЕ', 'NEW'),
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.6,
                      color: item.color,
                    ),
                  ),
                Text(
                  item.name,
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
                if (item.when != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    DateFormat(
                      'd MMM, HH:mm',
                      AppLocale.instance.dateLocale,
                    ).format(item.when!.toLocal()),
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
                if (item.originLabel.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        item.originIcon ?? item.icon,
                        size: 12,
                        color: item.color,
                      ),
                      const SizedBox(width: 3),
                      Flexible(
                        child: Text(
                          item.originLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            height: 1.1,
                            fontWeight: FontWeight.w800,
                            color: item.color,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 4),
                Expanded(
                  child: item.applianceType.trim().isNotEmpty
                      ? Stack(
                          children: [
                            Positioned.fill(
                              child: AppliancePicture(
                                type: item.applianceType,
                                fillSlot: true,
                              ),
                            ),
                            if (item.originIcon != null)
                              Positioned(
                                right: 2,
                                bottom: 2,
                                child: Container(
                                  padding: const EdgeInsets.all(3),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: item.color),
                                  ),
                                  child: Icon(
                                    item.originIcon,
                                    size: 14,
                                    color: item.color,
                                  ),
                                ),
                              ),
                          ],
                        )
                      : Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: item.color.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          alignment: Alignment.center,
                          child: item.busy
                              ? SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    color: item.color,
                                  ),
                                )
                              : Icon(item.icon, size: 32, color: item.color),
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

class _ReviewInboxStreams extends StatelessWidget {
  final Widget Function(
    List<Job> jobs,
    List<CallRecord> pending,
    List<CallRecord> processing,
    List<SecretaryLesson> lessons,
    List<SmsMessage> emailOffers,
    List<Job> waitingParts,
    List<SmsMessage> smsOffers,
  )
  builder;

  const _ReviewInboxStreams({required this.builder});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Job>>(
      stream: JobService.streamNeedsReview(),
      builder: (context, jobsSnap) {
        return StreamBuilder<List<CallRecord>>(
          stream: TwilioService.getPendingReviewCalls(),
          builder: (context, pendingSnap) {
            return StreamBuilder<List<CallRecord>>(
              stream: TwilioService.getAiProcessingCalls(),
              builder: (context, processingSnap) {
                return StreamBuilder<List<SecretaryLesson>>(
                  stream: SecretaryLearnService.streamPending(),
                  builder: (context, lessonsSnap) {
                    return StreamBuilder<List<SmsMessage>>(
                      stream: SmsService.streamEmailOffers(),
                      builder: (context, offersSnap) {
                        return StreamBuilder<List<Job>>(
                          stream: JobService.streamByStatus(
                            JobStatuses.waitingPart,
                          ),
                          builder: (context, partsSnap) {
                            return StreamBuilder<List<SmsMessage>>(
                              stream: SmsService.streamSmsOffers(),
                              builder: (context, smsOffersSnap) {
                                return builder(
                                  jobsSnap.data ?? const <Job>[],
                                  pendingSnap.data ?? const <CallRecord>[],
                                  processingSnap.data ?? const <CallRecord>[],
                                  lessonsSnap.data ?? const <SecretaryLesson>[],
                                  offersSnap.data ?? const <SmsMessage>[],
                                  partsSnap.data ?? const <Job>[],
                                  smsOffersSnap.data ?? const <SmsMessage>[],
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
      },
    );
  }
}

/// Листовой виджет с деталями ошибки секретаря: что сделала не так, как надо
/// было, и две кнопки: «Подтвердить» (применить правило) и «Отклонить».
class _SecretaryLessonSheet extends StatefulWidget {
  final SecretaryLesson lesson;

  const _SecretaryLessonSheet({required this.lesson});

  static Future<void> show(BuildContext context, SecretaryLesson lesson) {
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _SecretaryLessonSheet(lesson: lesson),
    );
  }

  @override
  State<_SecretaryLessonSheet> createState() => _SecretaryLessonSheetState();
}

class _SecretaryLessonSheetState extends State<_SecretaryLessonSheet> {
  bool _busy = false;

  Future<void> _approve() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await SecretaryLearnService.approve(widget.lesson);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr(
              'Правило принято — секретарь запомнила',
              'Rule accepted — secretary will remember',
            ),
          ),
          backgroundColor: Colors.green.shade700,
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reject() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await SecretaryLearnService.reject(widget.lesson);
      if (!mounted) return;
      Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lesson = widget.lesson;
    final when = lesson.createdAt;
    final stamp =
        when == null ? '' : DateFormat('dd.MM.yyyy HH:mm').format(when.toLocal());
    final isFail = lesson.severity == 'fail';
    final color =
        isFail ? const Color(0xFFC62828) : const Color(0xFFE65100);
    final problem = lesson.problemRu.trim().isNotEmpty
        ? lesson.problemRu.trim()
        : lesson.titleRu.trim();
    final happened = lesson.whatHappenedRu.trim();
    final fix = lesson.suggestedFixRu.trim();
    final phone = lesson.fromNumber.trim();

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 16,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Ручка
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Заголовок
            Row(
              children: [
                Icon(Icons.psychology_outlined, color: color, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.tr('Ошибка секретаря', 'Secretary error'),
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
            if (phone.isNotEmpty || stamp.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                [if (phone.isNotEmpty) phone, if (stamp.isNotEmpty) stamp]
                    .join(' · '),
                style:
                    const TextStyle(color: Colors.black54, fontSize: 13),
              ),
            ],
            const SizedBox(height: 16),
            // Что пошло не так
            if (problem.isNotEmpty) ...[
              Text(
                context.tr('Что пошло не так', 'What went wrong'),
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: Colors.black54,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                problem,
                style: const TextStyle(
                  fontSize: 15,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
            ],
            // Как это произошло
            if (happened.isNotEmpty) ...[
              Text(
                context.tr('Как это произошло', 'How it happened'),
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: Colors.black54,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                happened,
                style: const TextStyle(fontSize: 14, height: 1.4),
              ),
              const SizedBox(height: 12),
            ],
            // Как надо было
            if (fix.isNotEmpty) ...[
              Text(
                context.tr('Как надо было', 'How it should have been'),
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: Colors.black54,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5E9),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF81C784)),
                ),
                child: Text(
                  fix,
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.45,
                    color: Color(0xFF1B5E20),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ] else
              const SizedBox(height: 20),
            // Кнопки
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _busy ? null : _approve,
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.green.shade700,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            context.tr('Подтвердить', 'Confirm'),
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : _reject,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red.shade700,
                      side: BorderSide(color: Colors.red.shade300),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: Text(
                      context.tr('Отклонить', 'Reject'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
