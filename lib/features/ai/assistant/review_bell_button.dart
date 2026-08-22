import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../models/job.dart';
import '../../../models/secretary_lesson.dart';
import '../../../services/job_service.dart';
import '../../../services/sms_service.dart';
import '../../../services/secretary_learn_service.dart';
import '../../../services/twilio_service.dart';
import '../../../shared/widgets/appliance_picture.dart';
import '../../calls/call_review_page.dart';
import '../../jobs/email_offer_page.dart';
import '../../jobs/job_details/job_details_screen.dart';
import '../../settings/pages/secretary_learn_page.dart';

enum _InboxTab { secretary, calls, jobs }

class ReviewBellButton extends StatelessWidget {
  const ReviewBellButton({super.key});

  static List<CallRecord> _inboxCalls(List<CallRecord> pending) {
    return [
      for (final call in pending)
        if ((call.createdJobId ?? '').isEmpty) call,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return _ReviewInboxStreams(
      builder: (jobs, pending, processing, lessons, emailOffers) {
        final inboxCalls = _inboxCalls(pending);
        final count = jobs.length +
            inboxCalls.length +
            processing.length +
            lessons.length +
            emailOffers.length;
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
    showModalBottomSheet<void>(
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
          initialChildSize: 0.78,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          builder: (context, scrollController) {
            return _InboxSheet(
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

class _InboxItem {
  final _InboxTab tab;
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

  const _InboxItem({
    required this.tab,
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

class _InboxSheet extends StatefulWidget {
  final BuildContext hostContext;
  final BuildContext sheetContext;
  final ScrollController scrollController;

  const _InboxSheet({
    required this.hostContext,
    required this.sheetContext,
    required this.scrollController,
  });

  @override
  State<_InboxSheet> createState() => _InboxSheetState();
}

class _InboxSheetState extends State<_InboxSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  bool _clearing = false;
  bool _sawSecretary = false;
  bool _sawCalls = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _tabs.addListener(() {
      if (!mounted) return;
      if (_tabs.indexIsChanging) return;
      _noteSeen(_InboxTab.values[_tabs.index.clamp(0, 2)]);
      setState(() {});
    });
    _noteSeen(_InboxTab.secretary);
  }

  void _noteSeen(_InboxTab tab) {
    if (tab == _InboxTab.secretary) _sawSecretary = true;
    if (tab == _InboxTab.calls) _sawCalls = true;
  }

  @override
  void dispose() {
    if (_sawSecretary) {
      unawaited(SecretaryLearnService.dismissPending());
    }
    if (_sawCalls) {
      unawaited(TwilioService.markAllPendingReviewed());
    }
    _tabs.dispose();
    super.dispose();
  }

  _InboxTab get _currentTab => _InboxTab.values[_tabs.index.clamp(0, 2)];

  List<_InboxItem> _items({
    required List<Job> jobs,
    required List<CallRecord> pending,
    required List<CallRecord> processing,
    required List<SecretaryLesson> lessons,
    required List<SmsMessage> emailOffers,
  }) {
    final host = widget.hostContext;
    final sheet = widget.sheetContext;
    final items = <_InboxItem>[];
    final seenCalls = <String>{};
    final unknown = context.tr('Клиент', 'Client');

    void openCall(String callId, {CallRecord? call}) {
      Navigator.pop(sheet);
      CallReviewPage.open(host, callId: callId, call: call);
    }

    for (final call in processing) {
      seenCalls.add(call.id);
      final extracted = _callExtracted(call);
      final phone = call.isIncoming ? call.fromNumber : call.toNumber;
      items.add(
        _InboxItem(
          tab: _InboxTab.calls,
          icon: Icons.hourglass_top,
          color: const Color(0xFF7B1FA2),
          name: _ownerName(extracted, phone.isEmpty ? unknown : phone),
          applianceType: _applianceOf(extracted),
          when: call.startTime,
          busy: true,
        ),
      );
    }

    for (final lesson in lessons) {
      final sid = lesson.callSid.trim();
      if (sid.isNotEmpty) seenCalls.add(sid);
      final issue = lesson.isIssue;
      items.add(
        _InboxItem(
          tab: _InboxTab.secretary,
          icon: issue ? Icons.report : Icons.record_voice_over,
          color: issue ? const Color(0xFFC62828) : const Color(0xFFEF6C00),
          name: _ownerName(
            lesson.extracted,
            lesson.fromNumber.isNotEmpty ? lesson.fromNumber : unknown,
          ),
          applianceType: _applianceOf(lesson.extracted),
          when: lesson.createdAt,
          onTap: () {
            if (sid.isEmpty) {
              Navigator.pop(sheet);
              Navigator.of(host, rootNavigator: true).push(
                MaterialPageRoute(
                  builder: (_) => const SecretaryLearnPage(),
                ),
              );
              return;
            }
            openCall(sid);
          },
          onClear: () => SecretaryLearnService.markNoted(lesson),
        ),
      );
    }

    for (final call in pending) {
      if (!seenCalls.add(call.id)) continue;
      final extracted = _callExtracted(call);
      final phone = call.isIncoming ? call.fromNumber : call.toNumber;
      final declined = call.serviceDeclined;
      items.add(
        _InboxItem(
          tab: _InboxTab.calls,
          icon: declined ? Icons.phone_disabled : Icons.phone_in_talk,
          color: declined ? const Color(0xFF616161) : const Color(0xFFEF6C00),
          name: declined
              ? '${_ownerName(extracted, phone.isEmpty ? unknown : phone)} · ${context.tr('без заявки', 'no job')}'
              : _ownerName(extracted, phone.isEmpty ? unknown : phone),
          applianceType: declined ? '' : _applianceOf(extracted),
          when: call.startTime,
          onTap: () => openCall(call.id, call: call),
          onClear: () => TwilioService.markReviewed(call.id),
        ),
      );
    }

    for (final offer in emailOffers) {
      final extracted = offer.extractedData;
      final from = offer.counterpartEmail.isNotEmpty
          ? offer.counterpartEmail
          : offer.from;
      items.add(
        _InboxItem(
          tab: _InboxTab.jobs,
          icon: Icons.mark_email_unread_outlined,
          color: const Color(0xFF2E7D32),
          name: _ownerName(extracted, from.isEmpty ? unknown : from),
          applianceType: _applianceOf(extracted),
          when: offer.createdAt,
          originLabel: context.tr('Письмо · создать', 'Email · create'),
          originIcon: Icons.email_outlined,
          onTap: () {
            Navigator.pop(sheet);
            EmailOfferPage.open(host, messageId: offer.id, message: offer);
          },
          onClear: () => SmsService.dismissEmailOffer(offer.id),
        ),
      );
    }

    for (final job in jobs) {
      final name = job.contactName.trim().isEmpty
          ? (job.clientName.trim().isEmpty ? unknown : job.clientName.trim())
          : job.contactName.trim();
      final fromEmail = job.intakeSource == 'email';
      final fromPhone = job.intakeSource == 'phone';
      items.add(
        _InboxItem(
          tab: _InboxTab.jobs,
          icon: fromEmail
              ? Icons.email_outlined
              : fromPhone
                  ? Icons.phone_in_talk
                  : Icons.assignment_late,
          color: fromEmail
              ? const Color(0xFF2E7D32)
              : const Color(0xFF1565C0),
          name: name,
          applianceType: job.applianceType,
          when: job.createdAt,
          originLabel: fromEmail
              ? context.tr('Почта', 'Email')
              : fromPhone
                  ? context.tr('Телефон', 'Phone')
                  : '',
          originIcon: fromEmail
              ? Icons.email_outlined
              : fromPhone
                  ? Icons.phone_in_talk
                  : null,
          onTap: () {
            Navigator.pop(sheet);
            Navigator.of(host).push(
              MaterialPageRoute(
                builder: (_) => JobDetailsScreen(
                  jobId: job.id,
                  clientId: job.clientId,
                  jobData: job.toMap(),
                ),
              ),
            );
          },
          onClear: () => JobService.markReviewed(job.id),
        ),
      );
    }

    return items;
  }

  List<_InboxItem> _visible(List<_InboxItem> items) {
    final tab = _currentTab;
    return [for (final item in items) if (item.tab == tab) item];
  }

  Future<void> _clear(List<_InboxItem> visible) async {
    final clearable = [
      for (final item in visible)
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
      await Future.wait([
        for (final item in clearable) item.onClear!(),
      ]);
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Widget _tabBody(List<_InboxItem> items, int columns) {
    if (items.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 48),
          Text(
            context.tr(
              'Нет уведомлений в этой вкладке',
              'No notifications in this tab',
            ),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black54, fontSize: 16),
          ),
        ],
      );
    }
    return GridView.builder(
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

  Widget _tab({
    required IconData icon,
    required String label,
    required int count,
  }) {
    return Tab(
      icon: Badge(
        isLabelVisible: count > 0,
        backgroundColor: Colors.orange,
        label: Text('$count', style: const TextStyle(fontSize: 10)),
        child: Icon(icon, size: 22),
      ),
      iconMargin: const EdgeInsets.only(bottom: 4),
      text: label,
    );
  }

  @override
  Widget build(BuildContext context) {
    return _ReviewInboxStreams(
      builder: (jobs, pendingAll, processing, lessons, emailOffers) {
        final pending = ReviewBellButton._inboxCalls(pendingAll);
        final items = _items(
          jobs: jobs,
          pending: pending,
          processing: processing,
          lessons: lessons,
          emailOffers: emailOffers,
        );
        final visible = _visible(items);
        final secretaryN =
            items.where((i) => i.tab == _InboxTab.secretary).length;
        final callN = items.where((i) => i.tab == _InboxTab.calls).length;
        final jobN = items.where((i) => i.tab == _InboxTab.jobs).length;
        final width = MediaQuery.sizeOf(context).width;
        final columns = width >= 520 ? 4 : 3;
        final canClear = visible.any((item) => item.onClear != null);

        return SafeArea(
          child: Column(
            children: [
              ListenableBuilder(
                listenable: widget.scrollController,
                builder: (context, child) => child!,
                child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
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
                          : () => _clear(visible),
                      child: _clearing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(context.tr('Очистить', 'Clear')),
                    ),
                  ],
                ),
              ),
              ),
              TabBar(
                controller: _tabs,
                isScrollable: false,
                labelColor: AppColors.primary,
                unselectedLabelColor: Colors.black54,
                indicatorColor: AppColors.primary,
                indicatorWeight: 3,
                labelStyle: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
                tabs: [
                  _tab(
                    icon: Icons.record_voice_over,
                    label: context.tr('Секретарь', 'Secretary'),
                    count: secretaryN,
                  ),
                  _tab(
                    icon: Icons.phone_in_talk,
                    label: context.tr('Звонки', 'Calls'),
                    count: callN,
                  ),
                  _tab(
                    icon: Icons.assignment,
                    label: context.tr('Заявки', 'Jobs'),
                    count: jobN,
                  ),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    _tabBody(
                      items.where((i) => i.tab == _InboxTab.secretary).toList(),
                      columns,
                    ),
                    _tabBody(
                      items.where((i) => i.tab == _InboxTab.calls).toList(),
                      columns,
                    ),
                    _tabBody(
                      items.where((i) => i.tab == _InboxTab.jobs).toList(),
                      columns,
                    ),
                  ],
                ),
              ),
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
      color: Colors.white,
      elevation: 0,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: item.onTap,
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: item.color, width: 1.4),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
            child: Column(
              children: [
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
  ) builder;

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
                        return builder(
                          jobsSnap.data ?? const <Job>[],
                          pendingSnap.data ?? const <CallRecord>[],
                          processingSnap.data ?? const <CallRecord>[],
                          lessonsSnap.data ?? const <SecretaryLesson>[],
                          offersSnap.data ?? const <SmsMessage>[],
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
