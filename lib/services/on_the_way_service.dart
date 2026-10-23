import 'package:flutter/foundation.dart';

import '../models/job.dart';

class OnTheWayOffer {
  final Job fromJob;
  final Job nextJob;

  const OnTheWayOffer({required this.fromJob, required this.nextJob});
}

/// Заглушка: отслеживание отъезда на 2 км (уведомление/смена статуса/SMS «я в пути») отключено.
class OnTheWayService extends ChangeNotifier {
  static final OnTheWayService instance = OnTheWayService._();
  OnTheWayService._();

  OnTheWayOffer? pending;
  Job? pendingStatus;

  Future<void> sync(List<Job> allJobs) async {}

  Future<void> start() async {}

  Future<void> stop() async {
    pending = null;
    pendingStatus = null;
  }

  Future<void> dismissPending() async {
    pending = null;
  }

  Future<void> dismissStatusPrompt() async {
    pendingStatus = null;
  }

  Future<bool> sendPendingSms() async => false;
}
