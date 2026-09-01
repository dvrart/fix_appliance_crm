import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../../../core/api_keys.dart';
import '../../../../core/constants.dart';
import '../../../../core/l10n/app_locale.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../services/job_service.dart';
import '../../../../services/twilio_service.dart';
import '../../../../services/message_translate_service.dart';
import '../../../../shared/widgets/call_transcript_chat.dart';
import '../../../calls/call_review_page.dart';

String playableCallUrl(Map<String, dynamic> attachment) {
  final storage = (attachment['storageUrl'] ?? '').toString().trim();
  if (storage.isNotEmpty) return storage;
  final callId = (attachment['callId'] ?? '').toString().trim();
  if (callId.isNotEmpty) {
    return '$kCallRecordingAudioUrl?callId=${Uri.encodeQueryComponent(callId)}';
  }
  return (attachment['url'] ?? '').toString().trim();
}

List<String> _callAudioUrls(String primary, {String storageUrl = '', String callId = ''}) {
  final urls = <String>[];
  void add(String value) {
    final url = value.trim();
    if (url.isEmpty || urls.contains(url)) return;
    urls.add(url);
  }

  add(storageUrl);
  add(primary);
  final uri = Uri.tryParse(primary);
  final id = callId.isNotEmpty
      ? callId
      : (uri?.queryParameters['callId'] ?? '');
  if (id.isNotEmpty) {
    add('$kCallRecordingAudioUrl?callId=${Uri.encodeQueryComponent(id)}');
    add(
      '$kFirebaseFunctionsUrl/callRecordingAudio?callId=${Uri.encodeQueryComponent(id)}',
    );
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
    return a.trim().length >= b.trim().length ? a : b;
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
  late String _summary;
  late String _transcriptRu;
  late String _transcriptEn;
  String _lang = 'ru';
  bool _translating = false;

  String get _transcript => _lang == 'en' ? _transcriptEn : _transcriptRu;

  @override
  void initState() {
    super.initState();
    _summary = (widget.attachment['summary'] ?? '').toString().trim();
    final stored = callTranscriptText(widget.attachment);
    _transcriptRu = (widget.attachment['transcriptionRu'] ?? stored).toString().trim();
    if (_transcriptRu.isEmpty) _transcriptRu = stored;
    _transcriptEn = (widget.attachment['transcriptionEn'] ?? '').toString().trim();
    if (_transcriptEn.isEmpty && MessageTranslateService.looksEnglish(stored)) {
      _transcriptEn = stored;
    }
    _ensureLanguages();
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
    final jobId = (widget.jobId ?? '').trim();
    final callId = (widget.attachment['callId'] ?? '').toString().trim();
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
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 18,
                              color: Color(0xFF1A1A1A),
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
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                                color: Color(0xFF546E7A),
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
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: Color(0xFF1A1A1A),
                  ),
                ),
                const SizedBox(height: 6),
                if (_translating && _summary.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                Text(
                  _summary.isEmpty
                      ? (_translating
                          ? 'Перевожу...'.tr
                          : 'Пока нет выжимки'.tr)
                      : _summary,
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.35,
                    color: Color(0xFF1A1A1A),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Разговор'.tr,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: Color(0xFF1A1A1A),
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
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  PlayerState _state = PlayerState.stopped;
  bool _loading = true;
  String? _error;
  Uint8List? _bytes;
  String? _filePath;
  String _mime = 'audio/mpeg';

  bool get _playing => _state == PlayerState.playing;

  @override
  void initState() {
    super.initState();
    _player.onDurationChanged.listen((value) {
      if (!mounted) return;
      setState(() => _duration = value);
    });
    _player.onPositionChanged.listen((value) {
      if (!mounted) return;
      setState(() => _position = value);
    });
    _player.onPlayerStateChanged.listen((value) {
      if (!mounted) return;
      setState(() {
        _state = value;
        if (value == PlayerState.playing || value == PlayerState.paused) {
          _loading = false;
        }
      });
    });
    _prepare();
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
      final bytes = await _downloadWithRetry();
      _bytes = bytes;
      _mime = _audioMime(bytes);
      _filePath = await _writeTemp(bytes, _mime);
      try {
        await _player.setSource(DeviceFileSource(_filePath!));
      } catch (sourceError) {
        debugPrint('Call player setSource file: $sourceError');
        await _player.setSource(BytesSource(bytes, mimeType: _mime));
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = null;
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
      callId: (widget.attachment['callId'] ?? '').toString(),
    );
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
    final callId = (widget.attachment['callId'] ?? '').toString().trim();
    final ext = mime.contains('wav') ? 'wav' : 'mp3';
    final file = File(
      '${dir.path}/call_${callId.isEmpty ? bytes.length : callId}.$ext',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<void> _toggle() async {
    if (_error != null) {
      setState(() {
        _error = null;
        _loading = true;
      });
      await _prepare();
      if (_error != null) return;
    }
    if (_playing) {
      await _player.pause();
      return;
    }
    setState(() => _loading = true);
    try {
      if (_filePath != null) {
        await _player.play(DeviceFileSource(_filePath!));
      } else if (_bytes != null) {
        await _player.play(BytesSource(_bytes!));
      } else {
        final urls = _audioCandidates();
        var played = false;
        for (final url in urls) {
          try {
            await _player.play(UrlSource(url));
            played = true;
            break;
          } catch (error) {
            debugPrint('Call player play url: $error');
          }
        }
        if (!played) {
          final bytes = await _download();
          _bytes = bytes;
          _mime = _audioMime(bytes);
          _filePath = await _writeTemp(bytes, _mime);
          await _player.play(DeviceFileSource(_filePath!));
        }
      }
    } catch (playError) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось включить запись'.tr;
      });
      debugPrint('Call player play: $playError');
      return;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _seek(double value) async {
    final millis = value.round().clamp(0, _maxMillis);
    await _player.seek(Duration(milliseconds: millis));
  }

  int get _maxMillis {
    final total = _duration.inMilliseconds;
    if (total > 0) return total;
    final pos = _position.inMilliseconds;
    return pos > 0 ? pos : 1;
  }

  String _fmt(Duration value) {
    final m = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = value.inHours;
    if (h > 0) return '$h:$m:$s';
    return '$m:$s';
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final max = _maxMillis.toDouble();
    final pos = _position.inMilliseconds.clamp(0, _maxMillis).toDouble();
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F6FB),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              IconButton.filled(
                onPressed: _toggle,
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
                  onChanged: _duration.inMilliseconds <= 0 ? null : _seek,
                ),
              ),
              Text(
                '${_fmt(_position)} / ${_fmt(_duration)}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF475569),
                ),
              ),
            ],
          ),
          if (_loading && _bytes == null)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Готовим запись...'.tr,
                  style: const TextStyle(
                    color: Color(0xFF475569),
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
