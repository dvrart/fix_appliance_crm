import 'package:cloud_firestore/cloud_firestore.dart';
import '../core/constants.dart';

class JobChangeEvent {
  final String id;
  final DateTime at;
  final String by; // owner, secretary, sms, email, stripe, client
  final String event; // created, status_changed, visit_added, visit_moved, visit_confirmed, payment_recorded, etc.
  final Map<String, dynamic> data; // from, to, slot, amount, etc.

  const JobChangeEvent({
    required this.id,
    required this.at,
    required this.by,
    required this.event,
    required this.data,
  });

  factory JobChangeEvent.fromMap(Map<String, dynamic> map, String docId) {
    DateTime at;
    final raw = map['at'];
    if (raw is Timestamp) {
      at = raw.toDate();
    } else if (raw is String) {
      at = DateTime.tryParse(raw) ?? DateTime.now();
    } else {
      at = DateTime.now();
    }
    return JobChangeEvent(
      id: docId,
      at: at,
      by: (map['by'] ?? 'owner').toString(),
      event: (map['event'] ?? '').toString(),
      data: Map<String, dynamic>.from(map),
    );
  }
}

class ChangeLogService {
  static CollectionReference _changesRef(String jobId) {
    return FirebaseFirestore.instance
        .collection('companies')
        .doc(kCompanyId)
        .collection('jobs')
        .doc(jobId)
        .collection('changes');
  }

  static Stream<List<JobChangeEvent>> streamChanges(String jobId) {
    if (jobId.isEmpty) return const Stream.empty();
    return _changesRef(jobId)
        .orderBy('at', descending: false)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => JobChangeEvent.fromMap(
                  doc.data() as Map<String, dynamic>,
                  doc.id,
                ))
            .toList());
  }
}
