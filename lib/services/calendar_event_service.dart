import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

import '../core/constants.dart';
import '../models/calendar_event.dart';
import 'firestore_service.dart';
import 'network_status_service.dart';

class CalendarEventService {
  static CollectionReference get _ref =>
      FirestoreService.companyRef.collection('calendar_events');

  static Stream<List<CalendarEvent>> stream() {
    return _ref.snapshots().map((snap) {
      final out = <CalendarEvent>[];
      for (final doc in snap.docs) {
        try {
          out.add(
            CalendarEvent.fromMap(
              Map<String, dynamic>.from(doc.data() as Map),
              doc.id,
            ),
          );
        } catch (_) {}
      }
      out.sort((a, b) => a.startAt.compareTo(b.startAt));
      return out;
    });
  }

  static Future<String> save(CalendarEvent event) async {
    final ref = event.id.isEmpty ? _ref.doc() : _ref.doc(event.id);
    await settleWrite(
      ref.set({
        ...event.toMap(),
        if (event.id.isEmpty) 'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true)),
    );
    return ref.id;
  }

  static Future<void> delete(String id) async {
    if (id.isEmpty) return;
    await settleWrite(_ref.doc(id).delete());
  }

  static Future<String> uploadPhoto({
    required String eventId,
    required String localPath,
  }) async {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final ref = FirebaseStorage.instance.ref().child(
      'companies/$kCompanyId/calendar_events/$eventId/photo_$stamp.jpg',
    );
    final upload = ref.putFile(File(localPath));
    try {
      await upload.timeout(const Duration(seconds: 25));
    } on TimeoutException {
      await upload.cancel();
      rethrow;
    }
    return ref.getDownloadURL().timeout(const Duration(seconds: 15));
  }
}
