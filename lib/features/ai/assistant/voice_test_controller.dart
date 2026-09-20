import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:gemini_live/gemini_live.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../../../core/api_keys.dart';
import '../../../services/assistant_audio_service.dart';
import 'pcm_playback_queue.dart';

/// Lightweight Gemini Live session for previewing a secretary voice in Settings.
/// Connects, sends a silent trigger so the AI greets first (phone-call style),
/// and stays open until [close] is called.
class VoiceTestController extends ChangeNotifier {
  static const _model = 'gemini-3.1-flash-live-preview';

  static const _systemPrompt = '''
You are the phone secretary for FixApplianceCA appliance repair in Toronto, Canada.
This is a voice demo — the owner is testing how you sound.
When the owner says anything (even just "Hello"), immediately reply:
"Hello! FixApplianceCA, how can I help you today?"
Then have a brief, natural conversation about appliance repair to demonstrate your voice.
Keep every reply to 1–2 sentences. Be warm and professional.
Do not hang up. Always wait for the owner to speak first.
''';

  final String voiceName;

  VoiceTestController(this.voiceName);

  final _recorder = AudioRecorder();
  final _player = PcmPlaybackQueue();
  LiveSession? _session;
  StreamSubscription<Uint8List>? _micSub;
  bool _opening = false;
  bool _closing = false;
  bool _disposed = false;
  int _generation = 0;
  int _connectionGeneration = 0;
  Future<bool>? _focusRequest;
  Future<void>? _closeFuture;
  Future<void> _micOperation = Future<void>.value();
  DateTime _sendAudioAfter = DateTime.fromMillisecondsSinceEpoch(0);

  bool isOpen = false;
  bool isConnecting = false;
  bool isSpeaking = false;
  String statusText = '';
  String? errorText;
  String inputTranscript = '';

  bool _isCurrent(int gen) =>
      gen == _generation && isOpen && !_closing && !_disposed;

  bool _isCurrentConn(int gen, int conn) =>
      _isCurrent(gen) && conn == _connectionGeneration;

  Future<void> open() async {
    if (isOpen || _opening || _closing || _disposed) return;
    final gen = ++_generation;
    final conn = ++_connectionGeneration;
    _opening = true;
    _closeFuture = null;
    isOpen = true;
    isConnecting = true;
    errorText = null;
    inputTranscript = '';
    statusText = 'Connecting...';
    notifyListeners();

    try {
      _focusRequest = AssistantAudioService.requestFocus();
      final focused = await _focusRequest!;
      if (!_isCurrentConn(gen, conn)) return;
      if (!focused) throw Exception('Audio unavailable');
      await _connectSession(gen, conn);
      if (!_isCurrentConn(gen, conn)) return;
      await _startMic(gen);
      if (!_isCurrentConn(gen, conn)) return;
      isConnecting = false;
      statusText = 'Listening...';
      notifyListeners();
    } catch (e) {
      if (!_isCurrentConn(gen, conn)) return;
      errorText = e.toString();
      statusText = 'Error';
      notifyListeners();
      unawaited(close());
    } finally {
      if (gen == _generation) _opening = false;
    }
  }

  Future<void> _connectSession(int gen, int conn) async {
    bool cur() => _isCurrentConn(gen, conn);
    if (!cur()) return;
    final mic = await Permission.microphone.request();
    if (!cur()) return;
    if (!mic.isGranted) throw Exception('Microphone permission denied');
    if (kGeminiApiKey.isEmpty || kGeminiApiKey == 'YOUR_GEMINI_API_KEY') {
      throw Exception('Gemini API key not set');
    }

    final genAI = GoogleGenAI(apiKey: kGeminiApiKey);
    final session = await genAI.live.connect(
      LiveConnectParameters(
        model: _model,
        systemInstruction: Content(
          parts: [Part(text: _systemPrompt)],
        ),
        config: GenerationConfig(
          responseModalities: [Modality.AUDIO],
          speechConfig: SpeechConfig(
            languageCode: 'en-US',
            voiceConfig: VoiceConfig(
              prebuiltVoiceConfig: PrebuiltVoiceConfig(voiceName: voiceName),
            ),
          ),
        ),
        inputAudioTranscription: AudioTranscriptionConfig(),
        outputAudioTranscription: AudioTranscriptionConfig(),
        realtimeInputConfig: RealtimeInputConfig(
          activityHandling: ActivityHandling.NO_INTERRUPTION,
          automaticActivityDetection: AutomaticActivityDetection(
            disabled: false,
            startOfSpeechSensitivity:
                StartSensitivity.START_SENSITIVITY_HIGH,
            endOfSpeechSensitivity: EndSensitivity.END_SENSITIVITY_LOW,
            prefixPaddingMs: 400,
            silenceDurationMs: 900,
          ),
        ),
        callbacks: LiveCallbacks(
          onOpen: () {
            if (!cur()) return;
            isConnecting = false;
            statusText = 'Listening...';
            notifyListeners();
          },
          onMessage: (msg) => _onMessage(msg, gen, conn),
          onError: (error, _) {
            if (!cur()) return;
            errorText = error.toString();
            statusText = 'Error';
            notifyListeners();
          },
          onClose: (_, __) {},
        ),
      ),
    );
    if (!cur()) {
      try {
        await session.close();
      } catch (_) {}
      return;
    }
    _session = session;
  }

  Future<void> _onMessage(LiveServerMessage msg, int gen, int conn) async {
    bool cur() => _isCurrentConn(gen, conn);
    if (!cur()) return;

    final content = msg.serverContent;
    if (content?.interrupted == true) {
      _player.clear();
      if (isSpeaking) {
        isSpeaking = false;
        statusText = 'Listening...';
        notifyListeners();
      }
    }

    final inputText =
        content?.interimInputTranscription?.text ??
        content?.inputTranscription?.text;
    if (inputText != null && inputText.trim().isNotEmpty) {
      inputTranscript = inputText.trim();
      notifyListeners();
    }

    final audioB64 = msg.data;
    if (audioB64 != null && audioB64.isNotEmpty) {
      if (!isSpeaking) {
        isSpeaking = true;
        statusText = 'Speaking...';
        notifyListeners();
      }
      if (!cur()) return;
      await _player.addPcm16Bytes(
        Uint8List.fromList(base64Decode(audioB64)),
      );
    }

    if (content?.turnComplete == true) {
      Future<void>.delayed(const Duration(milliseconds: 600), () {
        if (!cur() || _player.isPlaying) return;
        if (isSpeaking) {
          isSpeaking = false;
          statusText = 'Listening...';
          notifyListeners();
        }
      });
    }
  }

  Future<void> _serializeMic(Future<void> Function() action) {
    final op = _micOperation.then((_) => action());
    _micOperation = op.catchError((Object _) {});
    return op;
  }

  Future<void> _stopMic() => _serializeMic(() async {
    final sub = _micSub;
    _micSub = null;
    try {
      await sub?.cancel();
    } catch (_) {}
    try {
      await _recorder.stop();
    } catch (_) {}
  });

  Future<void> _startMic(int gen) => _serializeMic(() async {
    bool cur() => _isCurrent(gen);
    if (!cur()) return;
    final sub = _micSub;
    _micSub = null;
    await sub?.cancel();
    if (!cur()) return;
    try {
      if (await _recorder.isRecording()) await _recorder.stop();
    } catch (_) {}
    if (!cur()) return;
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
        autoGain: true,
        audioInterruption: AudioInterruptionMode.none,
        androidConfig: AndroidRecordConfig(
          manageBluetooth: true,
          audioSource: AndroidAudioSource.voiceCommunication,
          speakerphone: true,
          audioManagerMode: AudioManagerMode.modeInCommunication,
        ),
      ),
    );
    if (!cur()) {
      try {
        await _recorder.stop();
      } catch (_) {}
      return;
    }
    _sendAudioAfter = DateTime.now().add(const Duration(milliseconds: 280));
    _micSub = stream.listen((chunk) {
      final session = _session;
      if (!_isCurrent(gen) || session == null || chunk.isEmpty) return;
      if (DateTime.now().isBefore(_sendAudioAfter)) return;
      if (isSpeaking || _player.isPlaying) return;
      try {
        session.sendRealtimeInput(
          audio: Blob(
            mimeType: 'audio/pcm;rate=16000',
            data: base64Encode(chunk),
          ),
        );
      } catch (_) {}
    });
  });

  Future<void> close() {
    final pending = _closeFuture;
    if (pending != null) return pending;
    final completer = Completer<void>();
    _closeFuture = completer.future;
    unawaited(
      _close().then(completer.complete, onError: completer.completeError),
    );
    return completer.future;
  }

  Future<void> _close() async {
    _closing = true;
    ++_generation;
    _opening = false;
    isOpen = false;
    isConnecting = false;
    isSpeaking = false;
    statusText = '';
    final session = _session;
    _session = null;
    if (session != null) {
      try {
        await session.close();
      } catch (_) {}
    }
    if (!_disposed) notifyListeners();
    try {
      await _stopMic();
      await _player.stop();
    } finally {
      await _focusRequest;
      _focusRequest = null;
      await AssistantAudioService.releaseFocus();
      _closing = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(close().whenComplete(_recorder.dispose));
    super.dispose();
  }
}
