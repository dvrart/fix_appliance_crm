import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/job.dart';
import '../../services/job_service.dart';
import '../../services/local_notification_service.dart';
import '../../services/morning_briefing_service.dart';

/// Утренние и вечерние уведомления по заявкам.
class FieldAssistantHost extends StatefulWidget {
  final Widget child;

  const FieldAssistantHost({super.key, required this.child});

  @override
  State<FieldAssistantHost> createState() => _FieldAssistantHostState();
}

class _FieldAssistantHostState extends State<FieldAssistantHost> {
  StreamSubscription<List<Job>>? _jobsSub;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await LocalNotificationService.initialize();
    if (!mounted) return;
    _jobsSub = JobService.streamAll().listen((jobs) {
      MorningBriefingService.refresh(jobs);
    });
  }

  @override
  void dispose() {
    _jobsSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
