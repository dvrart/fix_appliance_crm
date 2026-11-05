import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/api_keys.dart';
import '../../../../core/constants.dart';
import '../../../../core/l10n/app_locale.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../services/auth_service.dart';
import '../../../../services/assistant_audio_service.dart';
import '../../../../services/firestore_service.dart';
import '../../../../services/job_service.dart';
import '../../../../services/twilio_service.dart';
import '../../../../services/message_translate_service.dart';
import '../../../../shared/widgets/call_transcript_chat.dart';
import '../../../../shared/widgets/linked_text.dart';
import '../../../calls/call_review_page.dart';

String playableCallUrl(Map<String, dynamic> attachment) {
  final storage = (attachment['storageUrl'] ?? '').toString().trim();
  if (storage.isNotEmpty) return storage;
  final callId = (attachment['callId'] ?? '').toString().trim();
  if (callId.isNotEmpty) {
    return AuthService.withAuthQuery(
      '$kCallRecordingAudioUrl?callId=${Uri.encodeQueryComponent(callId)}',
    );
  }
  return (attachment['url'] ?? '').toString().trim();
}

/// Ссылки на запись. `lang: 'ru'` — это озвучка перевода: её собирает сервер
/// по расшифровке, поэтому в хранилище оригинала её искать бесполезно.
List<String> _callAudioUrls(
  String primary, {
  String storageUrl = '',
  String callId = '',
  String lang = '',
}) {
  final urls = <String>[];
  void add(String value) {
    final url = value.trim();
    if (url.isEmpty || urls.contains(url)) return;
    urls.add(url);
  }

  final uri = Uri.tryParse(primary);
  final id = callId.isNotEmpty
      ? callId
      : (uri?.queryParameters['callId'] ?? '');
  final suffix = lang.isEmpty ? '' : '&lang=${Uri.encodeQueryComponent(lang)}';
  if (lang.isEmpty) {
    add(storageUrl);
    add(primary);
  }
  if (id.isNotEmpty) {
    add(AuthService.withAuthQuery(
      '$kCallRecordingAudioUrl?callId=${Uri.encodeQueryComponent(id)}$suffix',
    ));
    add(AuthService.withAuthQuery(
      '$kFirebaseFunctionsUrl/callRecordingAudio?callId=${Uri.encodeQueryComponent(id)}$suffix',
    ));
  }
  return urls;
}

bool _looksLikeAudio(Uint8List bytes) {
  if (bytes.length < 32) return false;
  if (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) return true;
  if (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) return true;
  if (bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46) {
    return true;
  }
  final head = String.fromCharCodes(bytes.take(80)).toLowerCase();
  if (head.contains('<') ||
      head.contains('error') ||
      head.contains('not found') ||
      head.contains('unauthorized')) {
    return false;
  }
  return false;
}

String transcriptFromHistory(dynamic raw) {
  if (raw is! List) return '';
  final lines = <String>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final text = (item['text'] ?? '').toString().trim();
    if (text.isEmpty) continue;
    final role = (item['role'] ?? '').toString();
    final who = role == 'assistant' ? 'ИИ' : 'Клиент';
    lines.add('$who: $text');
  }
  return lines.join('\n');
}

bool _hasBothSpeakers(String text) {
  final hasShop = RegExp(
    r'(^|\n)\s*(ИИ|AI|Assistant|Me|Master|Мастер|Моё|Секретарь)\s*:',
    caseSensitive: false,
  ).hasMatch(text);
  final hasClient =
      RegExp(r'(^|\n)\s*(Клиент|Client|User|Caller)\s*:', caseSensitive: false)
          .hasMatch(text);
  return hasShop && hasClient;
}

String callTranscriptText(Map<String, dynamic> attachment) {
  String longer(String a, String b) {
    if (_hasBothSpeakers(b) && !_hasBothSpeakers(a)) return b;
    if (_hasBothSpeakers(a) && !_hasBothSpeakers(b)) return a;
    return keepFullerTranscript(a, b);
  }

  final fromHistory = transcriptFromHistory(attachment['history']);
  final stored = (attachment['transcription'] ?? '').toString().trim();
  final ru = (attachment['transcriptionRu'] ?? '').toString().trim();
  final en = (attachment['transcriptionEn'] ?? '').toString().trim();
  return [stored, ru, en, fromHistory].fold<String>('', longer);
}

String _audioMime(Uint8List bytes) {
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46) {
    return 'audio/wav';
  }
  return 'audio/mpeg';
}

Future<void> openCallRecordingSheet(
  BuildContext context,
  Map<String, dynamic> attachment, {
  String? jobId,
}) {
  final url = playableCallUrl(attachment);
  final transcript = callTranscriptText(attachment);
  if (url.isEmpty && transcript.trim().isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Запись ещё не готова'.tr)),
    );
    return Future.value();
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) {
      return _CallRecordingSheet(
        url: url,
        attachment: attachment,
        jobId: jobId,
      );
    },
  );
}

class _CallRecordingSheet extends StatefulWidget {
  final String url;
  final Map<String, dynamic> attachment;
  final String? jobId;

  const _CallRecordingSheet({
    required this.url,
    required this.attachment,
    this.jobId,
  });

  @override
  State<_CallRecordingSheet> createState() => _CallRecordingSheetState();
}

class _CallRecordingSheetState extends State<_CallRecordingSheet> {
  String _summary = '';
  String _transcriptRu = '';
  String _transcriptEn = '';
  String _lang = 'ru';
  bool _translating = false;

  String get _transcript => _lang == 'en' ? _transcriptEn : _transcriptRu;

  @override
  void initState() {
    super.initState();
    // Открыли запись/расшифровку звонка — он просмотрен: снимаем «новое»
    // и карточку в шторке, как делает разбор звонка.
    final callId = (widget.attachment['callId'] ?? '').toString().trim();
    if (callId.isNotEmpty) {
      unawaited(TwilioService.markReviewed(callId));
    }
    _summary = (widget.attachment['summary'] ?? '').toString().trim();
    final stored = callTranscriptText(widget.attachment);
    final rawRu =
        (widget.attachment['transcriptionRu'] ?? stored).toString().trim();
    _transcriptRu = rawRu.isEmpty ? stored : rawRu;
    _transcriptEn =
        (widget.attachment['transcriptionEn'] ?? '').toString().trim();
    if (_transcriptEn.isEmpty &&
        !MessageTranslateService.isRussianDialog(stored) &&
        MessageTranslateService.hasLatin(stored)) {
      _transcriptEn = stored;
    }
    _ensureLanguages();
  }

  Future<void> _ensureLanguages() async {
    if (_translating) return;
    final needRu = MessageTranslateService.needsRussianDialog(_transcriptRu) ||
        (_transcriptRu.isEmpty && _transcriptEn.isNotEmpty);
    final needEn = (_transcriptEn.isEmpty ||
            MessageTranslateService.isRussianDialog(_transcriptEn)) &&
        _transcriptRu.isNotEmpty;
    final needSummary = MessageTranslateService.needsRussianDialog(_summary);
    if (!needRu && !needEn && !needSummary) return;
    setState(() => _translating = true);
    final answeredBy = (widget.attachment['answeredBy'] ?? '').toString();
    try {
      var ru = _transcriptRu;
      var en = _transcriptEn;
      var summary = _summary;
      if (needRu) {
        final source = (!MessageTranslateService.isRussianDialog(en) &&
                en.length >= ru.length)
            ? en
            : (ru.isNotEmpty ? ru : en);
        ru = keepFullerTranscript(
          ru,
          await MessageTranslateService.toRussianDialog(
            source,
            answeredBy: answeredBy,
          ),
        );
      }
      if (needEn) {
        en = keepFullerTranscript(
          en,
          await MessageTranslateService.toEnglish(ru),
          preferRussian: false,
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
    } catch (error) {
      debugPrint('Call transcript translate: $error');
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
    if (lang == 'ru' &&
        (_transcriptRu.isEmpty ||
            MessageTranslateService.needsRussianDialog(_transcriptRu)) &&
        _transcriptEn.isNotEmpty) {
      setState(() => _translating = true);
      final answeredBy = (widget.attachment['answeredBy'] ?? '').toString();
      try {
        final ru = keepFullerTranscript(
          _transcriptRu,
          await MessageTranslateService.toRussianDialog(
            _transcriptEn,
            answeredBy: answeredBy,
          ),
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
    widget.attachment['transcription'] = ru;
    widget.attachment['transcriptionRu'] = ru;
    widget.attachment['transcriptionEn'] = en;
    if (summary.trim().isNotEmpty) widget.attachment['summary'] = summary;
    final jobId = (widget.jobId ?? '').trim();
    final callId = (widget.attachment['callId'] ?? '').toString().trim();
    if (callId.isNotEmpty) {
      try {
        await FirestoreService.callsRef.doc(callId).set({
          'transcriptionRu': ru,
          'transcriptionEn': en,
          if (summary.trim().isNotEmpty) 'summary': summary,
        }, SetOptions(merge: true));
      } catch (_) {}
    }
    if (jobId.isEmpty || callId.isEmpty) return;
    await JobService.patchCallNotes(
      jobId: jobId,
      callId: callId,
      transcription: ru,
      transcriptionRu: ru,
      transcriptionEn: en,
      summary: summary,
    );
  }

  Future<void> _reviewSecretary() async {
    final callId = (widget.attachment['callId'] ?? '').toString().trim();
    if (callId.isEmpty || !mounted) return;
    await CallReviewPage.open(context, callId: callId);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: SingleChildScrollView(
          child: SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.mic, color: Colors.black),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Запись разговора'.tr,
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 18,
                              color: AppColors.ink,
                            ),
                          ),
                          if (CallRecord.parseStamp(
                                widget.attachment['startTime'],
                              ) !=
                              null)
                            Text(
                              Formatters.formatDateTime(
                                CallRecord.parseStamp(
                                  widget.attachment['startTime'],
                                ),
                              ),
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                                color: AppColors.inkMuted,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (widget.url.trim().isNotEmpty)
                  CallAudioPlayer(
                    url: widget.url,
                    attachment: widget.attachment,
                  )
                else
                  Text(
                    'Аудио ещё готовится'.tr,
                    style: const TextStyle(color: Colors.grey),
                  ),
                const SizedBox(height: 20),
                Text(
                  'Выжимка'.tr,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: AppColors.ink,
                  ),
                ),
                const SizedBox(height: 6),
                if (_translating && _summary.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                LinkedText(
                  _summary.isEmpty
                      ? (_translating
                          ? 'Перевожу...'.tr
                          : 'Пока нет выжимки'.tr)
                      : _summary,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.35,
                    color: AppColors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Разговор'.tr,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: AppColors.ink,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    ChoiceChip(
                      label: const Text('RU'),
                      selected: _lang == 'ru',
                      onSelected: (_) => _switchLang('ru'),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('EN'),
                      selected: _lang == 'en',
                      onSelected: (_) => _switchLang('en'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                if (_translating)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                CallTranscriptChat(
                  text: _transcript,
                  translating: _translating,
                  answeredBy:
                      (widget.attachment['answeredBy'] ?? '').toString(),
                  startedAt: CallRecord.parseStamp(
                    widget.attachment['startTime'],
                  ),
                ),
                if ((widget.attachment['answeredBy'] ?? '').toString() ==
                        'ai' &&
                    (widget.attachment['callId'] ?? '')
                        .toString()
                        .trim()
                        .isNotEmpty) ...[
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _reviewSecretary,
                    icon: const Icon(Icons.report_gmailerrorred_outlined),
                    label: Text(
                      context.tr(
                        'Открыть звонок',
                        'Open the call',
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Русской расшифровки ещё нет — озвучивать нечего.
class _TranslationNotReady implements Exception {
  const _TranslationNotReady();
}

class CallAudioPlayer extends StatefulWidget {
  final String url;
  final Map<String, dynamic> attachment;

  const CallAudioPlayer({
    super.key,
    required this.url,
    required this.attachment,
  });

  @override
  State<CallAudioPlayer> createState() => _CallAudioPlayerState();
}

class _CallAudioPlayerState extends State<CallAudioPlayer> {
  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  Duration? _resumePosition;
  PlayerState _state = PlayerState.stopped;
  Future<void>? _playTask;
  bool _loading = true;
  bool _disposed = false;
  bool _saving = false;
  String? _error;
  Uint8List? _bytes;
  String? _filePath;
  String _mime = 'audio/mpeg';
  /// Какую дорожку слушаем: '' — оригинал звонка, 'ru' — русская озвучка.
  String _lang = '';

  bool get _playing => _state == PlayerState.playing;

  String get _callId => (widget.attachment['callId'] ?? '').toString().trim();

  @override
  void initState() {
    super.initState();
    _subscriptions.addAll([
      _player.onDurationChanged.listen((value) {
        if (!mounted || _disposed) return;
        setState(() => _duration = value);
      }, onError: _onPlayerError),
      _player.onPositionChanged.listen((value) {
        if (!mounted || _disposed || _resumePosition != null) return;
        setState(() => _position = value);
      }, onError: _onPlayerError),
      _player.onPlayerStateChanged.listen((value) {
        if (_disposed) return;
        if (value != PlayerState.playing && _playTask == null) {
          AssistantAudioService.playback.release(_player);
        }
        if (!mounted) return;
        setState(() => _state = value);
      }, onError: _onPlayerError),
    ]);
    _prepare();
  }

  void _onPlayerError(Object error) {
    if (_disposed) return;
    unawaited(_stopAfterError(error));
  }

  Future<void> _stopAfterError(Object error) async {
    try {
      await _player.stop();
    } catch (_) {
    } finally {
      AssistantAudioService.playback.release(_player);
    }
    if (!mounted || _disposed) return;
    setState(() {
      _loading = false;
      _error = 'Не удалось включить запись'.tr;
    });
    debugPrint('Call player playback: $error');
  }

  Future<void> _prepare() async {
    try {
      await _player.setReleaseMode(ReleaseMode.stop);
      await _player.setPlayerMode(PlayerMode.mediaPlayer);
      if (mounted) {
        setState(() {
          _loading = true;
          _error = null;
        });
      }
      if (!mounted || _disposed) return;
      final bytes = await _downloadWithRetry();
      if (!mounted || _disposed) return;
      _bytes = bytes;
      _mime = _audioMime(bytes);
      _filePath = await _writeTemp(bytes, _mime);
      if (!mounted || _disposed) return;
      try {
        await _player.setSource(DeviceFileSource(_filePath!));
      } catch (sourceError) {
        if (!mounted || _disposed) return;
        debugPrint('Call player setSource file: $sourceError');
        await _player.setSource(BytesSource(bytes, mimeType: _mime));
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = null;
      });
    } on _TranslationNotReady {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = context.tr(
          'Перевод записи ещё не готов',
          'The translated recording is not ready yet',
        );
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось загрузить запись'.tr;
      });
      debugPrint('Call player: $error');
    }
  }

  Future<Uint8List> _downloadWithRetry() async {
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    Object? lastError;
    var attempt = 0;
    while (DateTime.now().isBefore(deadline)) {
      attempt += 1;
      try {
        return await _download();
      } on _TranslationNotReady {
        rethrow;
      } catch (error) {
        lastError = error;
        debugPrint('Call player download try $attempt: $error');
        if (!mounted) rethrow;
        await Future<void>.delayed(
          Duration(seconds: attempt < 6 ? 3 : 8),
        );
      }
    }
    throw lastError ?? Exception('no audio');
  }

  List<String> _audioCandidates() {
    return _callAudioUrls(
      widget.url,
      storageUrl: (widget.attachment['storageUrl'] ?? '').toString(),
      callId: _callId,
      lang: _lang,
    );
  }

  /// Переключение языка озвучки: это другая дорожка, поэтому плеер
  /// перезаряжается с начала.
  Future<void> _switchLang(String lang) async {
    if (_lang == lang || _loading) return;
    try {
      await _player.stop();
    } catch (_) {}
    AssistantAudioService.playback.release(_player);
    if (!mounted) return;
    setState(() {
      _lang = lang;
      _bytes = null;
      _filePath = null;
      _resumePosition = null;
      _position = Duration.zero;
      _duration = Duration.zero;
      _state = PlayerState.stopped;
      _error = null;
    });
    await _prepare();
  }

  Future<Uint8List> _download() async {
    Object? lastError;
    for (final url in _audioCandidates()) {
      try {
        final response = await http.get(
          Uri.parse(url),
          headers: const {'Accept': 'audio/mpeg,audio/*,*/*'},
        ).timeout(const Duration(seconds: 90));
        if (response.statusCode == 404) {
          lastError = Exception('recording not ready');
          continue;
        }
        // Озвучивать нечего, пока нет русской расшифровки: ждать бессмысленно.
        if (response.statusCode == 409 || response.statusCode == 503) {
          throw const _TranslationNotReady();
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          lastError = Exception('HTTP ${response.statusCode} $url');
          continue;
        }
        final bytes = response.bodyBytes;
        final mime = (response.headers['content-type'] ?? '').toLowerCase();
        if (bytes.isEmpty) {
          lastError = Exception('empty audio $url');
          continue;
        }
        if (mime.contains('audio') || _looksLikeAudio(bytes)) {
          return bytes;
        }
        if (bytes.length > 4000 && !mime.contains('json') && !mime.contains('html')) {
          return bytes;
        }
        lastError = Exception('not audio $url');
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? Exception('no audio url');
  }

  Future<String> _writeTemp(Uint8List bytes, String mime) async {
    final dir = await getTemporaryDirectory();
    final callId = _callId;
    final ext = mime.contains('wav') ? 'wav' : 'mp3';
    final suffix = _lang.isEmpty ? '' : '_$_lang';
    final file = File(
      '${dir.path}/call_${callId.isEmpty ? bytes.length : callId}$suffix.$ext',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// Имя скачиваемого файла: дата звонка понятнее, чем Twilio-идентификатор.
  String _downloadName(String ext) {
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp = CallRecord.parseStamp(widget.attachment['startTime']);
    if (stamp != null) {
      return 'call_${stamp.year}-${two(stamp.month)}-${two(stamp.day)}'
          '_${two(stamp.hour)}-${two(stamp.minute)}.$ext';
    }
    final callId = (widget.attachment['callId'] ?? '').toString().trim();
    if (callId.isNotEmpty) return 'call_$callId.$ext';
    return 'call_${DateTime.now().millisecondsSinceEpoch}.$ext';
  }

  /// Сохраняем запись в телефон: сначала системное «Сохранить как»
  /// (там есть «Загрузки»), а если его нет — отдаём файл через «Поделиться».
  Future<void> _saveToPhone() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final bytes = _bytes ?? await _download();
      if (!mounted || _disposed) return;
      _bytes ??= bytes;
      final mime = _audioMime(bytes);
      final name = _downloadName(mime.contains('wav') ? 'wav' : 'mp3');
      Uri? saved;
      try {
        saved = await FilePicker.saveFile(
          dialogTitle: context.tr('Скачать запись', 'Download the recording'),
          fileName: name,
          bytes: bytes,
          mimeType: mime,
        );
      } catch (error) {
        debugPrint('Call recording saveFile: $error');
      }
      if (!mounted || _disposed) return;
      if (saved != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.tr('Запись сохранена', 'Recording saved')),
          ),
        );
        return;
      }
      final path = _filePath ?? await _writeTemp(bytes, mime);
      _filePath ??= path;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path, mimeType: mime, name: name)],
          title: name,
        ),
      );
    } catch (error) {
      debugPrint('Call recording save: $error');
      if (!mounted || _disposed) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr(
              'Не удалось скачать запись',
              'Could not download the recording',
            ),
          ),
        ),
      );
    } finally {
      if (mounted && !_disposed) setState(() => _saving = false);
    }
  }

  Future<void> _toggle() {
    if (_loading || _disposed || _playTask != null) return Future.value();
    final task = _togglePlayback();
    _playTask = task;
    return task.whenComplete(() {
      _playTask = null;
      if (_disposed) return;
      if (_player.state != PlayerState.playing) {
        AssistantAudioService.playback.release(_player);
      }
      if (mounted) setState(() => _loading = false);
    });
  }

  Future<void> _togglePlayback() async {
    setState(() => _loading = true);
    try {
      if (_error != null) {
        await _prepare();
        if (!mounted || _disposed || _error != null) return;
        setState(() => _loading = true);
      }
      if (_playing) {
        _resumePosition = await _player.getCurrentPosition() ?? _position;
        await _player.stop();
        if (!mounted || _disposed) return;
        setState(() {
          _state = PlayerState.paused;
          _position = _resumePosition!;
        });
        return;
      }
      await AssistantAudioService.playback.acquire(_player);
      if (!mounted || _disposed) return;
      final audio = await AssistantAudioService.readState();
      if (!mounted || _disposed) return;
      if (audio.callActive || !audio.available) {
        throw StateError('Audio is unavailable during a call');
      }
      await _player.setAudioContext(AudioContext(
        android: const AudioContextAndroid(
          contentType: AndroidContentType.speech,
          usageType: AndroidUsageType.media,
          audioFocus: AndroidAudioFocus.gainTransient,
        ),
      ));
      if (!mounted || _disposed) return;
      final resumePosition = _resumePosition;
      if (resumePosition != null) await _player.seek(resumePosition);
      if (!mounted || _disposed) return;
      _resumePosition = null;
      await _player.resume();
    } catch (error) {
      await _stopAfterError(error);
    }
  }

  Future<void> _seek(double value) async {
    final target = Duration(milliseconds: value.round().clamp(0, _maxMillis));
    if (!_playing) {
      setState(() {
        _resumePosition = target;
        _position = target;
      });
      return;
    }
    try {
      await _player.seek(target);
    } catch (error) {
      await _stopAfterError(error);
    }
  }

  int get _maxMillis {
    final total = _duration.inMilliseconds;
    if (total > 0) return total;
    final pos = _position.inMilliseconds;
    return pos > 0 ? pos : 1;
  }

  Widget _langChip(String lang, String label) {
    final selected = _lang == lang;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: _loading ? null : (_) => _switchLang(lang),
      labelStyle: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: selected ? Colors.white : AppColors.inkMuted,
      ),
      selectedColor: AppColors.primary,
      backgroundColor: AppColors.card,
      side: BorderSide(color: AppColors.border),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      showCheckmark: false,
    );
  }

  String _fmt(Duration value) {
    final m = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = value.inHours;
    if (h > 0) return '$h:$m:$s';
    return '$m:$s';
  }

  Future<void> _disposePlayer() async {
    try {
      await _playTask;
      await _player.dispose();
    } finally {
      AssistantAudioService.playback.release(_player);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_disposePlayer());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final max = _maxMillis.toDouble();
    final pos = _position.inMilliseconds.clamp(0, _maxMillis).toDouble();
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
      decoration: BoxDecoration(
        color: AppColors.cardMuted,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              IconButton.filled(
                onPressed: _loading ? null : _toggle,
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(48, 48),
                ),
                icon: _loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Icon(_playing ? Icons.pause : Icons.play_arrow),
              ),
              Expanded(
                child: Slider(
                  value: pos,
                  max: max,
                  onChanged: _loading || _duration.inMilliseconds <= 0 ? null : _seek,
                ),
              ),
              Text(
                '${_fmt(_position)} / ${_fmt(_duration)}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.inkMuted,
                ),
              ),
            ],
          ),
          if (_callId.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 2),
                child: Wrap(
                  spacing: 6,
                  children: [
                    _langChip('', context.tr('Оригинал', 'Original')),
                    _langChip('ru', context.tr('По-русски', 'In Russian')),
                  ],
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _saving ? null : _saveToPhone,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_outlined, size: 18),
              label: Text(
                _saving
                    ? context.tr('Скачиваю...', 'Downloading...')
                    : context.tr('Скачать MP3', 'Download MP3'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.primaryOnCard,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
          if (_loading && _bytes == null)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Готовим запись...'.tr,
                  style: TextStyle(
                    color: AppColors.inkMuted,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: const TextStyle(
                    color: Color(0xFFB91C1C),
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
