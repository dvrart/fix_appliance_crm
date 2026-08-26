import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/secretary_lesson.dart';
import '../services/ai_service.dart';
import 'firestore_service.dart';
import 'settings_service.dart';
import 'twilio_service.dart';

/// Разборы звонков и правки секретаря: в скрипт только после вашего подтверждения.
class SecretaryLearnService {
  static CollectionReference get _ref => FirestoreService.secretaryLessonsRef;

  static Stream<List<SecretaryLesson>> streamAll() {
    return _ref.snapshots().map((snap) {
      final list = snap.docs
          .map(
            (doc) => SecretaryLesson.fromMap(
              doc.data() as Map<String, dynamic>,
              doc.id,
            ),
          )
          .toList();
      list.sort((a, b) {
        final at = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bt = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bt.compareTo(at);
      });
      return list;
    });
  }

  static Stream<List<SecretaryLesson>> streamPending() {
    return streamAll().map(
      (items) => items.where((item) => item.isPending).toList(),
    );
  }

  static Stream<List<SecretaryLesson>> streamForCall(String callSid) {
    if (callSid.trim().isEmpty) {
      return Stream.value(const <SecretaryLesson>[]);
    }
    return _ref.where('callSid', isEqualTo: callSid).snapshots().map((snap) {
      final list = snap.docs
          .map(
            (doc) => SecretaryLesson.fromMap(
              doc.data() as Map<String, dynamic>,
              doc.id,
            ),
          )
          .toList();
      list.sort((a, b) {
        final at = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bt = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bt.compareTo(at);
      });
      return list;
    });
  }

  static Future<SecretaryLesson?> findForCall(String callSid) async {
    if (callSid.isEmpty) return null;
    final snap = await _ref.where('callSid', isEqualTo: callSid).limit(8).get();
    SecretaryLesson? report;
    for (final doc in snap.docs) {
      final lesson = SecretaryLesson.fromMap(
        doc.data() as Map<String, dynamic>,
        doc.id,
      );
      if (lesson.isReport) return lesson;
      report ??= lesson;
    }
    return report;
  }

  static Future<void> approve(
    SecretaryLesson lesson, {
    String note = '',
    bool rejectOthers = false,
  }) async {
    var rule = lesson.ruleEn.trim();
    final owner = note.trim();
    if (owner.isNotEmpty) {
      final fromOwner = await AiService.englishPhoneRule(owner);
      if (fromOwner.isNotEmpty) rule = fromOwner;
    }
    await _ref.doc(lesson.id).set({
      'status': SecretaryLesson.approved,
      'masterNote': owner,
      'ruleEn': rule,
      'reviewedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    if (rejectOthers) {
      await rejectOtherPending(exceptId: lesson.id);
    }
    await syncLearnedRules();
  }

  static Future<void> reject(SecretaryLesson lesson, {String note = ''}) async {
    await _ref.doc(lesson.id).set({
      'status': SecretaryLesson.rejected,
      'masterNote': note.trim(),
      'reviewedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    await syncLearnedRules();
  }

  static Future<void> markNoted(SecretaryLesson lesson, {String note = ''}) async {
    await _ref.doc(lesson.id).set({
      'status': SecretaryLesson.noted,
      'masterNote': note.trim(),
      'reviewedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> dismissPending() async {
    final snap = await _ref.get();
    final batch = FirebaseFirestore.instance.batch();
    var writes = 0;
    for (final doc in snap.docs) {
      final lesson = SecretaryLesson.fromMap(
        doc.data() as Map<String, dynamic>,
        doc.id,
      );
      if (!lesson.isPending) continue;
      batch.set(doc.reference, {
        'status': SecretaryLesson.noted,
        'reviewedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      writes++;
      if (writes >= 400) break;
    }
    if (writes > 0) await batch.commit();
  }

  static Future<void> rejectOtherPending({
    required String exceptId,
  }) async {
    final snap = await _ref.get();
    final batch = FirebaseFirestore.instance.batch();
    var writes = 0;
    for (final doc in snap.docs) {
      if (doc.id == exceptId) continue;
      final data = doc.data() as Map<String, dynamic>;
      if ((data['status'] ?? '') != SecretaryLesson.pending) continue;
      batch.set(doc.reference, {
        'status': SecretaryLesson.rejected,
        'masterNote': 'Мастер: это не надо, выучи только подтверждённое.',
        'reviewedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      writes += 1;
    }
    if (writes > 0) await batch.commit();
  }

  static Future<SecretaryLesson> saveReport({
    required Map<String, String> report,
    String callSid = '',
    String fromNumber = '',
    String transcript = '',
    Map<String, dynamic>? extracted,
    String source = 'master',
    String ownerNote = '',
  }) async {
    final problem = (report['problemRu'] ?? '').trim();
    final severity = (report['severity'] ?? '').trim().toLowerCase();
    final isIssue =
        severity == 'fail' || severity == 'issue' || problem.isNotEmpty;
    final ref = _ref.doc();
    await ref.set({
      'kind': SecretaryLesson.kindReport,
      'titleRu': (report['titleRu'] ?? 'Разбор звонка').trim(),
      'detailRu': (report['suggestedFixRu'] ?? '').trim(),
      'whatHappenedRu': (report['whatHappenedRu'] ?? '').trim(),
      'clungToRu': (report['clungToRu'] ?? '').trim(),
      'problemRu': problem,
      'okRu': (report['okRu'] ?? '').trim(),
      'suggestedFixRu': (report['suggestedFixRu'] ?? '').trim(),
      'ruleEn': (report['ruleEn'] ?? '').trim(),
      'evidence': (report['evidence'] ?? '').trim(),
      'severity': isIssue ? (severity == 'fail' ? 'fail' : 'issue') : 'ok',
      'transcriptExcerpt': transcript.trim(),
      'extracted': extracted ?? {},
      'callSid': callSid,
      'fromNumber': fromNumber,
      'source': source,
      'status': isIssue ? SecretaryLesson.pending : SecretaryLesson.noted,
      'masterNote': ownerNote.trim(),
      'createdAt': FieldValue.serverTimestamp(),
    });
    final snap = await ref.get();
    return SecretaryLesson.fromMap(
      snap.data() as Map<String, dynamic>? ?? {},
      ref.id,
    );
  }

  static Future<void> saveManualRule({
    required String problem,
    required String nextTime,
    String whatHappened = '',
    String clungTo = '',
    String callSid = '',
    String fromNumber = '',
  }) async {
    final rule = await AiService.englishPhoneRule(
      nextTime.trim().isNotEmpty ? nextTime : problem,
    );
    await _ref.doc().set({
      'kind': SecretaryLesson.kindManual,
      'titleRu': problem.trim().isEmpty
          ? 'Правка хозяина'
          : problem.trim().split('\n').first,
      'detailRu': nextTime.trim(),
      'whatHappenedRu': whatHappened.trim(),
      'clungToRu': clungTo.trim(),
      'problemRu': problem.trim(),
      'suggestedFixRu': nextTime.trim(),
      'ruleEn': rule,
      'source': 'master',
      'status': SecretaryLesson.approved,
      'masterNote': nextTime.trim(),
      'callSid': callSid,
      'fromNumber': fromNumber,
      'createdAt': FieldValue.serverTimestamp(),
      'reviewedAt': FieldValue.serverTimestamp(),
    });
    await syncLearnedRules();
  }

  static Future<SecretaryLesson> reviewTranscript({
    required String callSid,
    required String transcript,
    String fromNumber = '',
    Map<String, dynamic>? extracted,
    String ownerNote = '',
  }) async {
    final existing = await findForCall(callSid);
    if (existing != null && existing.isReport && ownerNote.trim().isEmpty) {
      return existing;
    }
    final conversation = transcript.trim();
    if (conversation.isEmpty) {
      throw Exception('Нет текста разговора');
    }
    final report = await AiService.reviewSecretaryCall(
      conversation: conversation,
      extracted: extracted,
      ownerNote: ownerNote,
    );
    return saveReport(
      report: report,
      callSid: callSid,
      fromNumber: fromNumber,
      transcript: conversation,
      extracted: extracted,
      ownerNote: ownerNote,
    );
  }

  static Future<SecretaryLesson> reviewCall(CallRecord call, {String ownerNote = ''}) async {
    return reviewTranscript(
      callSid: call.id,
      transcript: await loadCallTranscript(call),
      fromNumber: call.isIncoming ? call.fromNumber : call.toNumber,
      extracted: call.extractedData,
      ownerNote: ownerNote,
    );
  }

  static Future<String> loadCallTranscript(CallRecord call) async {
    try {
      final snap = await FirestoreService.callsRef.doc(call.id).get();
      final data = snap.data() as Map<String, dynamic>? ?? {};
      final history = data['aiReception'] is Map
          ? (((data['aiReception'] as Map)['history'] as List?) ?? const [])
              .map((item) {
                if (item is! Map) return '';
                final role = item['role'] == 'assistant' ? 'Secretary' : 'Caller';
                return '$role: ${item['text'] ?? ''}';
              })
              .where((line) => line.trim().isNotEmpty)
              .join('\n')
          : '';
      var best = '';
      for (final candidate in [
        data['transcriptionEn'],
        data['transcription'],
        data['transcriptionRu'],
        history,
        call.transcription,
      ]) {
        final text = (candidate ?? '').toString().trim();
        if (text.length > best.length) best = text;
      }
      return best;
    } catch (_) {
      return (call.transcription ?? '').trim();
    }
  }

  static Future<void> syncLearnedRules() async {
    final snap = await _ref.get();
    final rules = <Map<String, dynamic>>[];
    for (final doc in snap.docs) {
      final data = doc.data() as Map<String, dynamic>;
      if ((data['status'] ?? '') != SecretaryLesson.approved) continue;
      var rule = (data['ruleEn'] ?? '').toString().trim();
      final note = (data['masterNote'] ?? '').toString().trim();
      if (rule.isEmpty && note.isNotEmpty) rule = note;
      if (rule.isEmpty) continue;
      if (note.isNotEmpty && !rule.contains(note)) {
        rule = '$rule Owner note: $note';
      }
      rules.add({
        'id': doc.id,
        'titleRu': (data['titleRu'] ?? '').toString(),
        'ruleEn': rule,
      });
    }
    await FirestoreService.aiVoiceRef.set({
      'learnedRules': rules,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static CollectionReference get _coachRef => FirestoreService.secretaryCoachRef;

  static Stream<List<SecretaryCoachMessage>> streamCoach() {
    return _coachRef.snapshots().map((snap) {
      final list = [
        for (final doc in snap.docs)
          SecretaryCoachMessage.fromMap(
            doc.data() as Map<String, dynamic>,
            doc.id,
          ),
      ];
      list.sort((a, b) {
        final at = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bt = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return at.compareTo(bt);
      });
      return list;
    });
  }

  static Future<void> ensureCoachWelcome() async {
    final snap = await _coachRef.limit(1).get();
    if (snap.docs.isNotEmpty) return;
    await _coachRef.doc().set({
      'role': 'secretary',
      'text':
          'Напишите здесь, как мне вести входящие звонки. Можно переписать правила своими словами. Например: если сказали другой адрес — не клади трубку, спроси день и время и поставь визит.',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> postPendingLesson(SecretaryLesson lesson) async {
    if (lesson.id.isEmpty) return;
    final existing = await _coachRef
        .where('lessonId', isEqualTo: lesson.id)
        .limit(1)
        .get();
    if (existing.docs.isNotEmpty) return;
    final problem = lesson.problemRu.trim().isNotEmpty
        ? lesson.problemRu.trim()
        : lesson.titleRu.trim();
    final who = lesson.fromNumber.trim();
    await _coachRef.doc().set({
      'role': 'secretary',
      'lessonId': lesson.id,
      'callSid': lesson.callSid,
      'text': [
        if (who.isNotEmpty) 'Звонок $who.',
        if (problem.isNotEmpty) problem,
        'Напишите, как надо в следующий раз — запомню в скрипт.',
      ].join(' '),
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> sendCoachMessage(String raw) async {
    final text = raw.trim();
    if (text.isEmpty) return;
    await _coachRef.doc().set({
      'role': 'owner',
      'text': text,
      'createdAt': FieldValue.serverTimestamp(),
    });
    final pending = await streamPending().first;
    final profile = await SettingsService.loadAiVoiceProfile();
    final pendingProblem = pending.isEmpty
        ? ''
        : [
            pending.first.problemRu,
            pending.first.suggestedFixRu,
          ].where((line) => line.trim().isNotEmpty).join('\n');
    Map<String, String> coach;
    try {
      coach = await AiService.coachSecretaryTurn(
        ownerText: text,
        extraRules: profile.extraRules,
        learnedRules: profile.learnedRules,
        pendingProblem: pendingProblem,
      );
    } catch (_) {
      coach = {
        'replyRu':
            'Запомнила вашу правку. Со следующего звонка буду так делать.',
        'ruleEn': text,
        'rewriteExtraRules': '',
      };
    }
    final rewrite = (coach['rewriteExtraRules'] ?? '').trim();
    if (rewrite.isNotEmpty) {
      await SettingsService.setAiVoiceExtraRules(rewrite);
    }
    final ruleEn = (coach['ruleEn'] ?? '').trim();
    if (pending.isNotEmpty) {
      await approve(pending.first, note: text);
    } else if (ruleEn.isNotEmpty) {
      await saveManualRule(problem: pendingProblem, nextTime: text);
    }
    await _coachRef.doc().set({
      'role': 'secretary',
      'text': (coach['replyRu'] ?? '').trim().isEmpty
          ? 'Запомнила. Со следующего звонка буду так делать.'
          : coach['replyRu']!.trim(),
      'createdAt': FieldValue.serverTimestamp(),
    });
  }
}

class SecretaryCoachMessage {
  final String id;
  final String role;
  final String text;
  final String lessonId;
  final String callSid;
  final DateTime? createdAt;

  const SecretaryCoachMessage({
    required this.id,
    required this.role,
    required this.text,
    this.lessonId = '',
    this.callSid = '',
    this.createdAt,
  });

  bool get isOwner => role == 'owner';

  factory SecretaryCoachMessage.fromMap(Map<String, dynamic> map, String id) {
    DateTime? created;
    final raw = map['createdAt'];
    if (raw is Timestamp) created = raw.toDate();
    if (raw is DateTime) created = raw;
    return SecretaryCoachMessage(
      id: id,
      role: (map['role'] ?? '').toString(),
      text: (map['text'] ?? '').toString(),
      lessonId: (map['lessonId'] ?? '').toString(),
      callSid: (map['callSid'] ?? '').toString(),
      createdAt: created,
    );
  }
}
