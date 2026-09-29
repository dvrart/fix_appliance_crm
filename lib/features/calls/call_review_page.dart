import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_feedback.dart';
import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../core/utils/formatters.dart';
import '../../models/secretary_lesson.dart';
import '../../services/ai_service.dart';
import '../../services/client_service.dart';
import '../../services/firestore_service.dart';
import '../../services/job_service.dart';
import '../../services/message_translate_service.dart';
import '../../services/secretary_learn_service.dart';
import '../../services/twilio_service.dart';
import '../../shared/widgets/call_transcript_chat.dart';
import '../ai/job_preview_screen.dart';
import '../jobs/job_details/editors/call_recording_page.dart';
import '../jobs/job_details/job_details_screen.dart';
import '../messages/conversation_screen.dart';
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
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => CallReviewPage(
          callId: id,
          contactName: contactName,
        ),
      ),
    );
  }

  static Future<void> _openMessageFromCall(
    BuildContext context, {
    required CallRecord call,
    String? contactName,
  }) async {
    final phone = (call.isIncoming ? call.fromNumber : call.toNumber).trim();
    if (phone.isEmpty) return;
    var name = (contactName ?? '').trim();
    var clientId = (call.clientId ?? '').trim();
    if (name.isEmpty) {
      final extracted = {
        ...?call.extractedData,
        if (call.aiReception?['extracted'] is Map)
          ...Map<String, dynamic>.from(call.aiReception!['extracted'] as Map),
      };
      for (final key in [
        'client_name',
        'clientName',
        'name',
        'caller_name',
        'contactName',
      ]) {
        final val = (extracted[key] ?? '').toString().trim();
        if (val.isNotEmpty) {
          name = val;
          break;
        }
      }
    }
    if (clientId.isEmpty || name.isEmpty) {
      try {
        final client = (call.clientId ?? '').trim().isNotEmpty
            ? await ClientService.getById(call.clientId!)
            : await ClientService.findByPhone(phone);
        if (client != null) {
          if (clientId.isEmpty) clientId = client.id;
          if (name.isEmpty) name = client.fullName.trim();
        }
      } catch (_) {}
    }
    if (!context.mounted) return;
    await ConversationScreen.open(
      context,
      phoneNumber: phone,
      contactName: name.isNotEmpty ? name : null,
      clientId: clientId.isNotEmpty ? clientId : null,
      jobId: (call.createdJobId ?? '').trim().isNotEmpty ? call.createdJobId : null,
      initialChannel: ConversationChannel.sms,
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
            final phone = call != null
                ? (call.isIncoming ? call.fromNumber : call.toNumber).trim()
                : '';
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
                  if (call != null && phone.isNotEmpty)
                    IconButton(
                      tooltip: context.tr('Написать', 'Message'),
                      icon: const Icon(Icons.chat_bubble_outline),
                      onPressed: () => _openMessageFromCall(
                        context,
                        call: call,
                        contactName: contactName,
                      ),
                    ),
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
  String? _clientLookupName;
  String? _clientLookupId;

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
    _lookupClient(widget.call);
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
    }
    if (next.id != prev.id ||
        next.fromNumber != prev.fromNumber ||
        next.toNumber != prev.toNumber ||
        next.clientId != prev.clientId) {
      _lookupClient(next);
    }
  }

  Future<void> _lookupClient(CallRecord call) async {
    final phone = (call.isIncoming ? call.fromNumber : call.toNumber).trim();
    if (phone.isEmpty) return;
    try {
      final client = (call.clientId ?? '').trim().isNotEmpty
          ? await ClientService.getById(call.clientId!)
          : await ClientService.findByPhone(phone);
      if (!mounted || client == null) return;
      setState(() {
        _clientLookupName = client.fullName.trim();
        _clientLookupId = client.id;
      });
    } catch (_) {}
  }

  String _effectiveName(CallRecord call) {
    if ((widget.contactName ?? '').trim().isNotEmpty) {
      return widget.contactName!.trim();
    }
    if ((_clientLookupName ?? '').trim().isNotEmpty) {
      return _clientLookupName!.trim();
    }
    final extracted = {
      ...?call.extractedData,
      if (call.aiReception?['extracted'] is Map)
        ...Map<String, dynamic>.from(call.aiReception!['extracted'] as Map),
    };
    for (final key in [
      'client_name',
      'clientName',
      'name',
      'caller_name',
      'contactName',
    ]) {
      final val = (extracted[key] ?? '').toString().trim();
      if (val.isNotEmpty) return val;
    }
    return '';
  }

  String? _effectiveClientId(CallRecord call) {
    if ((call.clientId ?? '').trim().isNotEmpty) {
      return call.clientId!.trim();
    }
    if ((_clientLookupId ?? '').trim().isNotEmpty) {
      return _clientLookupId!.trim();
    }
    return null;
  }

  Future<void> _openMessage() async {
    final call = widget.call;
    final phone = (call.isIncoming ? call.fromNumber : call.toNumber).trim();
    if (phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr('Номер телефона не указан', 'No phone number available'),
          ),
        ),
      );
      return;
    }
    final name = _effectiveName(call);
    final clientId = _effectiveClientId(call);
    final jobId = (call.createdJobId ?? '').trim().isNotEmpty
        ? call.createdJobId
        : null;

    await ConversationScreen.open(
      context,
      phoneNumber: phone,
      contactName: name.isNotEmpty ? name : null,
      clientId: clientId,
      jobId: jobId,
      initialChannel: ConversationChannel.sms,
    );
  }

  void _callBack() {
    final call = widget.call;
    final phone = (call.isIncoming ? call.fromNumber : call.toNumber).trim();
    if (phone.isEmpty) return;
    final name = _effectiveName(call);
    CallScreen.open(
      context,
      phoneNumber: phone,
      contactName: name.isNotEmpty ? name : null,
    );
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
        ru = keepFullerTranscript(
          ru,
          await MessageTranslateService.toRussianDialog(
            ru.isNotEmpty ? ru : en,
          ),
        );
      }
      if (needEn) {
        en = keepFullerTranscript(
          en,
          await MessageTranslateService.toEnglish(_transcriptRu),
        );
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
        final ru = keepFullerTranscript(
          _transcriptRu,
          await MessageTranslateService.toRussianDialog(_transcriptEn),
        );
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

  Future<void> _convertToJob(BuildContext context) async {
    final call = widget.call;
    final extracted = {
      ...?call.extractedData,
      if (call.aiReception?['extracted'] is Map)
        ...Map<String, dynamic>.from(call.aiReception!['extracted'] as Map),
    };
    final data = ExtractedJobData.fromJson(extracted);
    final phone = call.isIncoming ? call.fromNumber : call.toNumber;
    if (!context.mounted) return;
    final result = await Navigator.of(context, rootNavigator: true).push<bool>(
      MaterialPageRoute(
        builder: (_) => JobPreviewScreen(
          extractedData: data,
          originalText: call.transcriptionRu ?? call.transcription ?? '',
          fallbackPhone: phone.isNotEmpty ? phone : null,
          existingClientId: call.clientId,
          sourceCallId: call.id,
        ),
      ),
    );
    if (result == true && context.mounted) {
      unawaited(TwilioService.markReviewed(call.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final call = widget.call;
    final phone = (call.isIncoming ? call.fromNumber : call.toNumber).trim();
    final name = _effectiveName(call);
    final url = playableCallUrl(call.toAttachment());
    final report = _report;
    final hasProblem = (report?.isIssue ?? false) ||
        (call.aiError ?? '').trim().isNotEmpty ||
        call.liveFailed ||
        call.liveError.isNotEmpty;
    final hasLinkedJob = (call.createdJobId ?? '').trim().isNotEmpty;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
      children: [
        // Главная кнопка: «Преобразовать в заявку» или «Открыть заявку»
        if (hasLinkedJob)
          ElevatedButton.icon(
            onPressed: () => _openJob(context, call.createdJobId!),
            icon: const Icon(Icons.assignment),
            label: Text(context.tr('Открыть заявку', 'Open the job')),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.black,
              minimumSize: const Size.fromHeight(52),
            ),
          )
        else
          ElevatedButton.icon(
            onPressed: () => _convertToJob(context),
            icon: const Icon(Icons.add_task),
            label: Text(context.tr('Преобразовать в заявку', 'Convert to job')),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF16A34A),
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(52),
            ),
          ),
        const SizedBox(height: 12),
        CallReviewHeaderCard(
          call: call,
          name: name,
          phone: phone,
          onCall: phone.isEmpty ? null : _callBack,
          onMessage: phone.isEmpty ? null : _openMessage,
        ),
        // Краткое изложение — над аудио
        if (_summary.isNotEmpty) ...[
          const SizedBox(height: 12),
          _SectionCard(
            title: context.tr('Коротко о звонке', 'Call summary'),
            child: Text(_summary, style: const TextStyle(height: 1.45)),
          ),
        ],
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
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: phone.isEmpty ? null : _callBack,
                icon: const Icon(Icons.call),
                label: Text(context.tr('Перезвонить', 'Call back')),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: phone.isEmpty ? null : _openMessage,
                icon: const Icon(Icons.chat_bubble_outline),
                label: Text(context.tr('Написать', 'Message')),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1E88E5),
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ),
          ],
        ),
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

class CallReviewHeaderCard extends StatelessWidget {
  final CallRecord call;
  final String name;
  final String phone;
  final VoidCallback? onCall;
  final VoidCallback? onMessage;

  const CallReviewHeaderCard({
    super.key,
    required this.call,
    required this.name,
    required this.phone,
    this.onCall,
    this.onMessage,
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
            InkWell(
              onTap: () => AppFeedback.copy(context, phone),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      phone,
                      style: const TextStyle(
                        color: Colors.black87,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Icon(Icons.copy, size: 14, color: Colors.black38),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 4),
          Text(
            [
              who,
              if (call.startTime != null)
                Formatters.formatDateTime(call.startTime),
            ].join(' · '),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          if (phone.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onCall,
                    icon: const Icon(Icons.phone, size: 18),
                    label: Text(context.tr('Позвонить', 'Call')),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF008F3B),
                      side: const BorderSide(color: Color(0xFF008F3B)),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: onMessage,
                    icon: const Icon(Icons.chat_bubble_outline, size: 18),
                    label: Text(context.tr('Написать', 'Message')),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1E88E5),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
              ],
            ),
          ],
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
