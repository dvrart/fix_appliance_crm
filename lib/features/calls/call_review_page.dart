import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_feedback.dart';
import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../core/utils/formatters.dart';
import '../../models/secretary_lesson.dart';
import '../../services/firestore_service.dart';
import '../../services/job_service.dart';
import '../../services/message_translate_service.dart';
import '../../services/secretary_learn_service.dart';
import '../../services/twilio_service.dart';
import '../../shared/widgets/call_transcript_chat.dart';
import '../jobs/job_details/editors/call_recording_page.dart';
import '../jobs/job_details/job_details_screen.dart';
import 'call_screen.dart';

/// Запись, расшифровка RU/EN и разбор ошибки секретаря по одному звонку.
class CallReviewPage extends StatelessWidget {
  final String callId;
  final String? contactName;

  const CallReviewPage({
    super.key,
    required this.callId,
    this.contactName,
  });

  static Future<void> open(
    BuildContext context, {
    required String callId,
    String? contactName,
    CallRecord? call,
  }) {
    AppFeedback.pleasant();
    final id = callId.trim().isNotEmpty ? callId : (call?.id ?? '');
    if (id.isEmpty) return Future.value();
    if (call != null) {
      unawaited(JobService.ensureDraftFromCall(call));
    } else {
      unawaited(() async {
        final found = await TwilioService.getById(id);
        if (found != null) await JobService.ensureDraftFromCall(found);
      }());
    }
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => CallReviewPage(
          callId: id,
          contactName: contactName,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<CallRecord?>(
      stream: TwilioService.watchCall(callId),
      builder: (context, callSnap) {
        final call = callSnap.data;
        return StreamBuilder<List<SecretaryLesson>>(
          stream: SecretaryLearnService.streamForCall(callId),
          builder: (context, lessonsSnap) {
            return Scaffold(
              backgroundColor: const Color(0xFFF4F6F8),
              appBar: AppBar(
                title: Text(
                  context.tr('Звонок', 'Call'),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                actions: [
                  if (call != null && !call.isDeleted)
                    IconButton(
                      tooltip: 'Удалить'.tr,
                      onPressed: () async {
                        await TwilioService.delete(call.id);
                        if (context.mounted) Navigator.of(context).pop();
                      },
                      icon: const Icon(Icons.delete_outline, color: Color(0xFFFF8A80)),
                    ),
                ],
              ),
              body: call == null
                  ? Center(
                      child: callSnap.connectionState == ConnectionState.waiting
                          ? const CircularProgressIndicator()
                          : Text('Звонок не найден'.tr),
                    )
                  : _CallReviewBody(
                      call: call,
                      contactName: contactName,
                      lessons: lessonsSnap.data ?? const [],
                    ),
            );
          },
        );
      },
    );
  }
}

class _CallReviewBody extends StatefulWidget {
  final CallRecord call;
  final String? contactName;
  final List<SecretaryLesson> lessons;

  const _CallReviewBody({
    required this.call,
    required this.contactName,
    required this.lessons,
  });

  @override
  State<_CallReviewBody> createState() => _CallReviewBodyState();
}

class _CallReviewBodyState extends State<_CallReviewBody> {
  late String _summary;
  late String _transcriptRu;
  late String _transcriptEn;
  String _lang = 'ru';
  bool _translating = false;

  String get _transcript => _lang == 'en' ? _transcriptEn : _transcriptRu;

  SecretaryLesson? get _report {
    final pending = widget.lessons.where((item) => item.isPending);
    for (final lesson in pending) {
      if (lesson.isReport || lesson.isIssue) return lesson;
    }
    for (final lesson in widget.lessons) {
      if (lesson.isReport) return lesson;
    }
    return widget.lessons.isEmpty ? null : widget.lessons.first;
  }

  @override
  void initState() {
    super.initState();
    _hydrate(widget.call);
    _ensureLanguages();
    unawaited(JobService.ensureDraftFromCall(widget.call));
  }

  @override
  void didUpdateWidget(covariant _CallReviewBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.call;
    final prev = oldWidget.call;
    final grew = (next.transcription ?? '').length >
            (prev.transcription ?? '').length ||
        (next.transcriptionRu ?? '').length >
            (prev.transcriptionRu ?? '').length ||
        (next.transcriptionEn ?? '').length >
            (prev.transcriptionEn ?? '').length ||
        (next.summary ?? '').length > (prev.summary ?? '').length;
    if (next.id != prev.id || grew) {
      _hydrate(next);
      _ensureLanguages();
      unawaited(JobService.ensureDraftFromCall(next));
    }
  }

  void _hydrate(CallRecord call) {
    final attachment = call.toAttachment();
    final stored = callTranscriptText(attachment);
    _summary = (call.summary ?? '').trim();
    _transcriptRu = (call.transcriptionRu ?? stored).trim();
    if (_transcriptRu.isEmpty) _transcriptRu = stored;
    _transcriptEn = (call.transcriptionEn ?? '').trim();
    if (_transcriptEn.isEmpty && MessageTranslateService.looksEnglish(stored)) {
      _transcriptEn = stored;
    }
  }

  Future<void> _ensureLanguages() async {
    final needRu = MessageTranslateService.needsRussian(_transcriptRu) ||
        (_transcriptRu.isEmpty && _transcriptEn.isNotEmpty);
    final needEn = _transcriptEn.isEmpty && _transcriptRu.isNotEmpty;
    final needSummary = MessageTranslateService.needsRussian(_summary);
    if (!needRu && !needEn && !needSummary) return;
    setState(() => _translating = true);
    try {
      var ru = _transcriptRu;
      var en = _transcriptEn;
      var summary = _summary;
      if (needRu) {
        ru = await MessageTranslateService.toRussian(
          ru.isNotEmpty ? ru : en,
        );
      }
      if (needEn) {
        en = await MessageTranslateService.toEnglish(_transcriptRu);
      }
      if (needSummary) {
        summary = await MessageTranslateService.toRussian(_summary);
      }
      if (!mounted) return;
      setState(() {
        _transcriptRu = ru;
        _transcriptEn = en;
        _summary = summary;
        _translating = false;
      });
      await _persist(ru, en, summary);
    } catch (_) {
      if (mounted) setState(() => _translating = false);
    }
  }

  Future<void> _switchLang(String lang) async {
    if (_lang == lang) return;
    setState(() => _lang = lang);
    if (lang == 'en' && _transcriptEn.isEmpty && _transcriptRu.isNotEmpty) {
      setState(() => _translating = true);
      try {
        final en = await MessageTranslateService.toEnglish(_transcriptRu);
        if (!mounted) return;
        setState(() {
          _transcriptEn = en;
          _translating = false;
        });
        await _persist(_transcriptRu, en, _summary);
      } catch (_) {
        if (mounted) setState(() => _translating = false);
      }
    }
    if (lang == 'ru' && _transcriptRu.isEmpty && _transcriptEn.isNotEmpty) {
      setState(() => _translating = true);
      try {
        final ru = await MessageTranslateService.toRussian(_transcriptEn);
        if (!mounted) return;
        setState(() {
          _transcriptRu = ru;
          _translating = false;
        });
        await _persist(ru, _transcriptEn, _summary);
      } catch (_) {
        if (mounted) setState(() => _translating = false);
      }
    }
  }

  Future<void> _persist(String ru, String en, String summary) async {
    await FirestoreService.callsRef.doc(widget.call.id).set({
      'transcriptionRu': ru,
      'transcriptionEn': en,
      if (summary.trim().isNotEmpty) 'summary': summary,
    }, SetOptions(merge: true));
    final jobId = (widget.call.createdJobId ?? '').trim();
    if (jobId.isEmpty) return;
    await JobService.patchCallNotes(
      jobId: jobId,
      callId: widget.call.id,
      transcription: ru,
      transcriptionRu: ru,
      transcriptionEn: en,
      summary: summary,
    );
  }

  Future<void> _copyError() async {
    final report = _report;
    final pack = report?.agentPack() ??
        [
          'SECRETARY ERROR',
          'callSid: ${widget.call.id}',
          'from: ${widget.call.isIncoming ? widget.call.fromNumber : widget.call.toNumber}',
          if ((widget.call.aiError ?? '').trim().isNotEmpty)
            'aiError: ${widget.call.aiError}',
          if (widget.call.liveError.isNotEmpty)
            'liveError: ${widget.call.liveError}',
        ].join('\n');
    await Clipboard.setData(ClipboardData(text: pack));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.tr(
            'Скопировано. Пришлите это в чат, чтобы исправить.',
            'Copied. Send this in chat so it can be fixed.',
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final call = widget.call;
    final phone = call.isIncoming ? call.fromNumber : call.toNumber;
    final name = (widget.contactName ?? '').trim();
    final url = playableCallUrl(call.toAttachment());
    final report = _report;
    final hasProblem = (report?.isIssue ?? false) ||
        (call.aiError ?? '').trim().isNotEmpty ||
        call.liveFailed ||
        call.liveError.isNotEmpty;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
      children: [
        _HowItWorks(),
        const SizedBox(height: 16),
        _HeaderCard(call: call, name: name, phone: phone),
        const SizedBox(height: 12),
        _SectionCard(
          title: context.tr('Запись разговора', 'Call recording'),
          child: url.isEmpty
              ? Text(
                  context.tr(
                    'Запись ещё не готова. Подождите немного и откройте звонок снова.',
                    'The recording is not ready yet. Wait a bit and open the call again.',
                  ),
                  style: const TextStyle(color: Colors.black54, height: 1.35),
                )
              : CallAudioPlayer(
                  key: ValueKey(url),
                  url: url,
                  attachment: call.toAttachment(),
                ),
        ),
        const SizedBox(height: 12),
        _SectionCard(
          title: context.tr('Текст разговора', 'Call transcript'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_summary.isNotEmpty) ...[
                Text(
                  context.tr('Коротко', 'Summary'),
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                    color: Colors.black54,
                  ),
                ),
                const SizedBox(height: 4),
                Text(_summary, style: const TextStyle(height: 1.35)),
                const SizedBox(height: 12),
              ],
              Row(
                children: [
                  ChoiceChip(
                    label: Text(context.tr('По-русски', 'Russian')),
                    selected: _lang == 'ru',
                    onSelected: (_) => _switchLang('ru'),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: Text(context.tr('По-английски', 'English')),
                    selected: _lang == 'en',
                    onSelected: (_) => _switchLang('en'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_translating) const LinearProgressIndicator(minHeight: 2),
              const SizedBox(height: 8),
              CallTranscriptChat(
                text: _transcript,
                translating: _translating,
                answeredBy: call.answeredBy,
              ),
            ],
          ),
        ),
        if (call.answeredByAi) ...[
          const SizedBox(height: 12),
          _ProblemCard(
            call: call,
            report: report,
            hasProblem: hasProblem,
            onCopy: _copyError,
          ),
        ],
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: phone.trim().isEmpty
              ? null
              : () => CallScreen.open(
                    context,
                    phoneNumber: phone,
                    contactName: name.isEmpty ? null : name,
                  ),
          icon: const Icon(Icons.call),
          label: Text(context.tr('Перезвонить', 'Call back')),
        ),
        if ((call.createdJobId ?? '').trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: () => _openJob(context, call.createdJobId!),
            icon: const Icon(Icons.assignment),
            label: Text(context.tr('Открыть заявку', 'Open the job')),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.black,
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ],
      ],
    );
  }
}

Future<void> _openJob(BuildContext context, String jobId) async {
  final job = await JobService.getById(jobId);
  if (!context.mounted || job == null) return;
  await Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute(
      builder: (_) => JobDetailsScreen(
        jobId: job.id,
        clientId: job.clientId,
        jobData: job.toMap(),
      ),
    ),
  );
}

class _HowItWorks extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFEEF4FF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFB6C9EA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.tr('Как это читать', 'How to read this'),
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          const SizedBox(height: 10),
          _step(
            '1',
            context.tr(
              'Сверху запись. Можно послушать весь разговор.',
              'The recording is at the top. You can listen to the whole call.',
            ),
          ),
          _step(
            '2',
            context.tr(
              'Дальше текст: кнопка «По-русски» и «По-английски».',
              'Then the text: tap Russian or English.',
            ),
          ),
          _step(
            '3',
            context.tr(
              'Если секретарь ошибся — красный блок. Скопируйте его и пришлите в чат, чтобы исправить.',
              'If the secretary was wrong — a red box. Copy it and send it in chat to get a fix.',
            ),
          ),
        ],
      ),
    );
  }

  Widget _step(String number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            child: Text(
              number,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: const TextStyle(height: 1.35)),
          ),
        ],
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  final CallRecord call;
  final String name;
  final String phone;

  const _HeaderCard({
    required this.call,
    required this.name,
    required this.phone,
  });

  @override
  Widget build(BuildContext context) {
    final who = call.answeredByAi
        ? context.tr('Ответил секретарь', 'Secretary answered')
        : call.answeredBy == 'master'
            ? context.tr('Ответили вы', 'You answered')
            : context.tr('Звонок', 'Call');
    return _SectionCard(
      title: name.isNotEmpty ? name : phone,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (name.isNotEmpty && phone.isNotEmpty)
            Text(phone, style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 4),
          Text(
            [
              who,
              if (call.startTime != null)
                Formatters.formatDateTime(call.startTime),
            ].join(' · '),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _ProblemCard extends StatelessWidget {
  final CallRecord call;
  final SecretaryLesson? report;
  final bool hasProblem;
  final VoidCallback? onCopy;

  const _ProblemCard({
    required this.call,
    required this.report,
    required this.hasProblem,
    this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final color = hasProblem ? const Color(0xFFFEE2E2) : const Color(0xFFECFDF3);
    final border = hasProblem ? const Color(0xFFFECACA) : const Color(0xFFA7F3D0);
    final titleColor =
        hasProblem ? const Color(0xFF991B1B) : const Color(0xFF065F46);
    final problem = [
      if ((report?.problemRu ?? '').trim().isNotEmpty) report!.problemRu.trim(),
      if ((call.aiError ?? '').trim().isNotEmpty)
        context.tr(
          'Техническая ошибка ИИ: ${call.aiError}',
          'AI error: ${call.aiError}',
        ),
      if (call.liveFailed || call.liveError.isNotEmpty)
        context.tr(
          'Во время разговора связь оборвалась${call.liveError.isEmpty ? '' : ': ${call.liveError}'}',
          'The live call dropped${call.liveError.isEmpty ? '' : ': ${call.liveError}'}',
        ),
    ].join('\n');

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            hasProblem
                ? context.tr('Проблема секретаря', 'Secretary problem')
                : context.tr(
                    'Ошибок не видно',
                    'No secretary problem found',
                  ),
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 16,
              color: titleColor,
            ),
          ),
          const SizedBox(height: 8),
          if (!hasProblem)
            Text(
              (report?.okRu ?? '').trim().isNotEmpty
                  ? report!.okRu
                  : context.tr(
                      'Если всё равно нужно исправление — скопируйте карточку в Настройки → Ошибки секретаря и пришлите в чат.',
                      'If it still needs a fix, copy the card in Settings → Secretary errors and send it in chat.',
                    ),
              style: const TextStyle(height: 1.35),
            )
          else ...[
            if ((report?.whatHappenedRu ?? '').trim().isNotEmpty)
              _labeled(
                context.tr('Что случилось', 'What happened'),
                report!.whatHappenedRu,
              ),
            if ((report?.clungToRu ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              _labeled(
                context.tr(
                  'На чём запутался',
                  'What it got stuck on',
                ),
                report!.clungToRu,
              ),
            ],
            if (problem.isNotEmpty) ...[
              const SizedBox(height: 8),
              _labeled(
                context.tr('В чём ошибка', 'What went wrong'),
                problem,
              ),
            ],
            if ((report?.suggestedFixRu ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              _labeled(
                context.tr(
                  'Как лучше в следующий раз',
                  'Better next time',
                ),
                report!.suggestedFixRu,
              ),
            ],
          ],
          if (onCopy != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onCopy,
                icon: const Icon(Icons.copy, size: 18),
                label: Text(
                  context.tr('Скопировать для исправления', 'Copy for a fix'),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _labeled(String title, String text) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 12,
            color: Colors.black54,
          ),
        ),
        const SizedBox(height: 4),
        Text(text, style: const TextStyle(height: 1.35, fontSize: 15)),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;

  const _SectionCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}
