import 'package:cloud_firestore/cloud_firestore.dart';

class SecretaryLesson {
  static const pending = 'pending';
  static const approved = 'approved';
  static const rejected = 'rejected';
  static const noted = 'noted';

  static const kindLesson = 'lesson';
  static const kindReport = 'report';
  static const kindManual = 'manual';

  final String id;
  final String kind;
  final String titleRu;
  final String detailRu;
  final String whatHappenedRu;
  final String clungToRu;
  final String problemRu;
  final String okRu;
  final String suggestedFixRu;
  final String ruleEn;
  final String evidence;
  final String severity;
  final String transcriptExcerpt;
  final Map<String, dynamic> extracted;
  final String callSid;
  final String fromNumber;
  final String source;
  final String status;
  final String masterNote;
  final DateTime? createdAt;

  const SecretaryLesson({
    required this.id,
    this.kind = kindLesson,
    required this.titleRu,
    this.detailRu = '',
    this.whatHappenedRu = '',
    this.clungToRu = '',
    this.problemRu = '',
    this.okRu = '',
    this.suggestedFixRu = '',
    this.ruleEn = '',
    this.evidence = '',
    this.severity = '',
    this.transcriptExcerpt = '',
    this.extracted = const {},
    this.callSid = '',
    this.fromNumber = '',
    this.source = 'auto',
    this.status = pending,
    this.masterNote = '',
    this.createdAt,
  });

  bool get isPending => status == pending;
  bool get isReport => kind == kindReport || kind == kindManual;
  bool get isIssue =>
      severity == 'fail' || severity == 'issue' || problemRu.trim().isNotEmpty;

  String agentPack() {
    final when = createdAt?.toIso8601String() ?? '';
    return [
      'SECRETARY ERROR',
      'callSid: $callSid',
      'from: $fromNumber',
      if (when.isNotEmpty) 'when: $when',
      'severity: ${severity.isEmpty ? (isIssue ? 'issue' : 'ok') : severity}',
      'title: $titleRu',
      if (problemRu.trim().isNotEmpty) 'problem: ${problemRu.trim()}',
      if (whatHappenedRu.trim().isNotEmpty)
        'whatHappened: ${whatHappenedRu.trim()}',
      if (clungToRu.trim().isNotEmpty) 'stuckOn: ${clungToRu.trim()}',
      if (okRu.trim().isNotEmpty) 'ok: ${okRu.trim()}',
      if (suggestedFixRu.trim().isNotEmpty)
        'suggestedFix: ${suggestedFixRu.trim()}',
      if (ruleEn.trim().isNotEmpty) 'ruleEn: ${ruleEn.trim()}',
      if (extracted.isNotEmpty) 'extracted: $extracted',
      if (transcriptExcerpt.trim().isNotEmpty) ...[
        'transcript:',
        transcriptExcerpt.trim(),
      ],
    ].join('\n');
  }

  factory SecretaryLesson.fromMap(Map<String, dynamic> map, String id) {
    DateTime? created;
    final raw = map['createdAt'];
    if (raw is Timestamp) created = raw.toDate();
    if (raw is DateTime) created = raw;
    final extractedRaw = map['extracted'];
    return SecretaryLesson(
      id: id,
      kind: (map['kind'] ?? kindLesson).toString(),
      titleRu: (map['titleRu'] ?? '').toString(),
      detailRu: (map['detailRu'] ?? '').toString(),
      whatHappenedRu: (map['whatHappenedRu'] ?? '').toString(),
      clungToRu: (map['clungToRu'] ?? '').toString(),
      problemRu: (map['problemRu'] ?? '').toString(),
      okRu: (map['okRu'] ?? '').toString(),
      suggestedFixRu: (map['suggestedFixRu'] ?? map['detailRu'] ?? '').toString(),
      ruleEn: (map['ruleEn'] ?? '').toString(),
      evidence: (map['evidence'] ?? '').toString(),
      severity: (map['severity'] ?? '').toString(),
      transcriptExcerpt: (map['transcriptExcerpt'] ?? '').toString(),
      extracted: extractedRaw is Map
          ? Map<String, dynamic>.from(extractedRaw)
          : const {},
      callSid: (map['callSid'] ?? '').toString(),
      fromNumber: (map['fromNumber'] ?? '').toString(),
      source: (map['source'] ?? 'auto').toString(),
      status: (map['status'] ?? pending).toString(),
      masterNote: (map['masterNote'] ?? '').toString(),
      createdAt: created,
    );
  }
}
