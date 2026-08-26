import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../models/job.dart';
import '../../services/job_service.dart';
import '../../services/local_notification_service.dart';
import '../../services/morning_briefing_service.dart';
import '../../services/on_the_way_service.dart';
import '../../services/status_service.dart';
import '../../services/twilio_service.dart';

/// Утренние уведомления, статус после отъезда и SMS «я в пути».
class FieldAssistantHost extends StatefulWidget {
  final Widget child;

  const FieldAssistantHost({super.key, required this.child});

  @override
  State<FieldAssistantHost> createState() => _FieldAssistantHostState();
}

class _FieldAssistantHostState extends State<FieldAssistantHost> {
  StreamSubscription<List<Job>>? _jobsSub;
  bool _sending = false;
  bool _pickingStatus = false;

  @override
  void initState() {
    super.initState();
    OnTheWayService.instance.addListener(_onOffer);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await LocalNotificationService.initialize();
    _jobsSub = JobService.streamAll().listen((jobs) {
      MorningBriefingService.refresh(jobs);
      OnTheWayService.instance.sync(jobs);
    });
  }

  void _onOffer() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _jobsSub?.cancel();
    OnTheWayService.instance.removeListener(_onOffer);
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    final ok = await OnTheWayService.instance.sendPendingSms();
    if (!mounted) return;
    setState(() => _sending = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'SMS «я в пути» отправлено'.tr : 'Не удалось отправить SMS'.tr),
        backgroundColor: ok ? Colors.green : Colors.red,
      ),
    );
  }

  Future<void> _pickLeaveStatus(Job job) async {
    if (_pickingStatus) return;
    _pickingStatus = true;
    try {
      final selected = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        useRootNavigator: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (sheetContext) {
          return StreamBuilder<List<String>>(
            stream: StatusService.streamAll(),
            builder: (context, snapshot) {
              final statuses = StatusService.idsForStatusMenu(
                snapshot.data ?? JobStatuses.all,
                current: job.status,
              );
              final maxHeight = MediaQuery.of(context).size.height * 0.7;
              return SafeArea(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxHeight),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Text(
                          'Выберите статус'.tr,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            color: Color(0xFF1A1A1A),
                          ),
                        ),
                      ),
                      Flexible(
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: statuses.length,
                          itemBuilder: (context, index) {
                            final status = statuses[index];
                            final isSelected = job.status == status;
                            return ListTile(
                              leading: Icon(
                                isSelected
                                    ? Icons.check_circle
                                    : Icons.circle_outlined,
                                color: StatusService.colorOf(status),
                              ),
                              title: Text(
                                trAny(StatusService.labelOf(status)),
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF1A1A1A),
                                ),
                              ),
                              selected: isSelected,
                              onTap: () => Navigator.pop(sheetContext, status),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
      if (selected == null || selected == job.status) return;
      await JobService.updateStatus(job.id, selected);
      if (!mounted) return;
      await OnTheWayService.instance.dismissStatusPrompt();
    } finally {
      _pickingStatus = false;
    }
  }

  Widget _banner({required Widget child}) {
    return Positioned(
      left: 12,
      right: 12,
      bottom: 24,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(16),
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (TwilioService.activeCall != null) return widget.child;

    final statusJob = OnTheWayService.instance.pendingStatus;
    final offer = OnTheWayService.instance.pending;
    if (statusJob == null && offer == null) return widget.child;

    return Stack(
      children: [
        widget.child,
        if (statusJob != null)
          _banner(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Нужно изменить статус заявки?'.tr,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  statusJob.contactName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                Text(
                  [
                    statusJob.applianceType,
                    trAny(StatusService.labelOf(statusJob.status)),
                    statusJob.workAddress,
                  ].where((part) => part.toString().trim().isNotEmpty).join(' · '),
                  style: const TextStyle(color: Colors.black54),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    TextButton(
                      onPressed: OnTheWayService.instance.dismissStatusPrompt,
                      child: Text('Нет'.tr),
                    ),
                    const Spacer(),
                    ElevatedButton(
                      onPressed: () => _pickLeaveStatus(statusJob),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: Colors.black,
                      ),
                      child: Text('Да, изменить'.tr),
                    ),
                  ],
                ),
              ],
            ),
          )
        else if (offer != null)
          _banner(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Хотите, я отправлю следующему клиенту уведомление о том, что вы едете?'.tr,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  offer.nextJob.contactName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                Text(
                  [
                    if (offer.nextJob.visitOn(DateTime.now()) != null)
                      DateFormat('H:mm').format(
                        offer.nextJob.visitOn(DateTime.now())!.startAt,
                      )
                    else if (offer.nextJob.scheduledAt != null)
                      DateFormat('H:mm').format(offer.nextJob.scheduledAt!),
                    offer.nextJob.applianceType,
                    offer.nextJob.workAddress,
                  ].where((part) => part.toString().trim().isNotEmpty).join(' · '),
                  style: const TextStyle(color: Colors.black54),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    TextButton(
                      onPressed: OnTheWayService.instance.dismissPending,
                      child: Text('Нет'.tr),
                    ),
                    const Spacer(),
                    ElevatedButton.icon(
                      onPressed: _sending ? null : _send,
                      icon: _sending
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.sms),
                      label: Text('Да, отправить'.tr),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: Colors.black,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}
