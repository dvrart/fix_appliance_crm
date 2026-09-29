import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/secretary_lesson.dart';
import '../services/ai_service.dart';
import 'firestore_service.dart';
import 'twilio_service.dart';

/// Разборы звонков телефонного секретаря — папка ошибок, а не обучение.
///
/// **Секретарь отсюда ничему не учится, и это сознательно.** Живой промпт
/// собирается только на сервере (`DEFAULT_VOICE_INSTRUCTIONS` в
/// `functions/voice_relay.js` плюс часы, календарь и карта зоны); правила из
/// приложения в Live не подмешиваются — их уже пробовали подмешивать, и
/// секретарь от этого ломалась.
///
/// Раньше здесь жила видимость обучения: `syncLearnedRules()` при каждом
/// «Подтвердить» записывала в настройки **пустые** `learnedRules`, а
/// `SettingsService.ensureAiVoiceSettings()` затирала их ещё и на каждом
/// старте приложения. Колокольчик при этом показывал «секретарь запомнила».
/// Обещание убрано (21.09.2026), функция удалена. Реально работают два конца:
///
/// * `reject` — сервер (`functions/secretary_learn.js`) читает отклонённые
///   разборы и больше не присылает то же самое;
/// * `approve` / `saveManualRule` — карточка остаётся в папке, владелец
///   копирует её («Скопировать для правки») и присылает в чат, правку пишут
///   на сервере.
///
/// Если когда-нибудь дойдёт до настоящего обучения — хранить принятые правила
/// и подмешивать их в серверный промпт, а не писать в Firestore пустоту.
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

  /// Ошибка подтверждена: карточка остаётся в папке для правки на сервере.
  /// Сама секретарь от этого не меняется — см. описание класса.
  static Future<void> approve(SecretaryLesson lesson, {String note = ''}) async {
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
  }

  /// Это не ошибка. Единственная кнопка, которая реально влияет на секретаря:
  /// сервер читает отклонённые разборы и больше не присылает то же самое.
  static Future<void> reject(SecretaryLesson lesson, {String note = ''}) async {
    await _ref.doc(lesson.id).set({
      'status': SecretaryLesson.rejected,
      'masterNote': note.trim(),
      'reviewedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Вернуть ошибку в статус «Новые» (ожидает разбора).
  static Future<void> resetToPending(SecretaryLesson lesson) async {
    await _ref.doc(lesson.id).set({
      'status': SecretaryLesson.pending,
      'reviewedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Удалить запись разбора.
  static Future<void> delete(SecretaryLesson lesson) async {
    await _ref.doc(lesson.id).delete();
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
      'status': SecretaryLesson.noted,
      'masterNote': nextTime.trim(),
      'callSid': callSid,
      'fromNumber': fromNumber,
      'createdAt': FieldValue.serverTimestamp(),
      'reviewedAt': FieldValue.serverTimestamp(),
    });
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
}
