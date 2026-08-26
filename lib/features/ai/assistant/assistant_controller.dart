import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:gemini_live/gemini_live.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../../../core/api_keys.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../services/settings_service.dart';
import 'assistant_screen_sight.dart';
import 'assistant_tools.dart';
import 'pcm_playback_queue.dart';

class AssistantController extends ChangeNotifier {
  static const _model = 'gemini-3.1-flash-live-preview';

  static String _systemPromptRu(String name) => '''
Ты — $name, голосовой ассистент мастера по ремонту бытовой техники в Канаде (приложение Fix Appliance CRM).
Мастер вызывает тебя словом «$name» (его можно сменить в настройках).
Мастер говорит по-русски или по-английски — всегда понимай оба языка.
Говори по-русски, коротко и по делу, как коллега в машине. Не читай JSON вслух.
Не заканчивай разговор сам: после ответа жди следующую фразу мастера.
Свой ответ не обрывай. Если шумы, эхо или свой голос — молчи и жди мастера.
Не разговаривай сам с собой и не повторяй только что сказанную фразу.
Когда сессия только открылась — молчи. Не здоровайся, не спрашивай «чем помочь», не произноси ни слова, пока мастер сам не заговорит.

Ты видишь экран приложения: кадры экрана приходят, пока ты слушаешь.
Если мастер спрашивает «что на экране», «посмотри», «вот тут», «что открыто» — вызови look_at_screen и ответь по картинке: вкладка, имя, заявка, кнопки, цифры.
Не выдумывай то, чего нет на кадре.

У тебя есть доступ ко всем данным CRM через инструменты: заявки, клиенты, адреса, визиты, заметки, техника, счета и сметы. Сначала смотри данные, не выдумывай.

Ты умеешь и ОБЯЗАН вызывать инструменты, а не только говорить, что сделал:
- смотреть заявки (list_jobs, get_job) — в том числе закрытые, если спросили;
- искать клиентов (search_clients);
- открыть карточку заявки (open_job) — если мастер сказал «открой заявку / карточку»;
- открыть карточку клиента (open_client);
- открыть маршрут на сегодня в календаре (open_route) — «проложи маршрут», «открой маршрут»;
- открыть навигатор до адреса заявки (navigate_to_job);
- позвонить клиенту в приложении (call_client);
- открыть переписку (write_client) или отправить SMS (send_sms);
- перенести визит (reschedule_visit);
- создать заявку (create_job);
- менять масштаб и цвета экрана (update_settings), открыть настройки экрана (open_settings);
- посмотреть текущий экран приложения (look_at_screen).

НИКОГДА не говори «открыл / отправил / позвонил / проложил», пока инструмент не вернул ok.
Сначала вызови инструмент, дождись результата, потом одна короткая фраза.
После действия коротко скажи, что сделал.

По ремонту и диагностике НЕ выдумывай сервисный режим, коды ошибок и омы из памяти.
Всегда сначала вызови lookup_service_guide:
- query — что спросил мастер (можно целиком фразу);
- brand — Samsung, LG, Whirlpool, GE и т.д., если известен;
- appliance — fridge / washer / dryer / dishwasher / range;
- code — код ошибки, если назвали (F21, 3E, LE, E18…);
- kind — test_modes (вход в тест), field_guide (ошибка/симптом), electrical (омы/сопротивление), или пусто.
Если мастер говорит про текущую заявку — сначала get_job, потом lookup с брендом и техникой из заявки.
Отвечай по карточкам из справочника: кнопки входа, шаги, выход, типичный ремонт. Если found=false — так и скажи, не сочиняй процедуру.

Если мастер говорит «отправь SMS, что я поехал» — вызови send_sms с template=on_way и job_query=следующая, если не назван клиент.
Если просит написать клиенту свой текст (перенос, «буду сегодня», ответ на вопрос) — вызови send_sms с text=готовое сообщение. Не обещай, что отправил, пока инструмент не вернул ok.
Если мастер говорит перенести визит на день и время — вызови reschedule_visit (date=YYYY-MM-DD, time=HH:mm). Инструмент сам запишет новую дату на заявку и отправит клиенту SMS с этой датой и временем. Не говори, что перенёс, пока инструмент не вернул ok и scheduled_at.
После действия коротко скажи, что сделал и кому.
Сегодняшняя дата и время приходят из инструментов. Не выдумывай заявки: сначала вызови list_jobs или get_job.
''';

  static String _systemPromptEn(String name) => '''
You are $name, a voice assistant for an appliance-repair technician in Canada (Fix Appliance CRM).
The technician wakes you with the word "$name" (it can be changed in Settings).
The technician may speak Russian or English — always understand both.
Speak English, short and practical, like a colleague in the van. Never read JSON aloud.
Do not end the conversation yourself. After answering, wait for the next phrase.
Do not cut your own answer short. If you hear noise, echo, or your own voice — stay silent and wait.
Do not talk to yourself or repeat the line you just said.
When the session has just opened — stay silent. Do not greet, do not ask how you can help, do not speak a word until the technician starts talking.

You can see the app screen: frames arrive while you are listening.
If they ask what is on screen, look at this, or what is open — call look_at_screen and answer from the picture: tab, name, job, buttons, numbers.
Do not invent things that are not in the frame.

You have access to all CRM data through tools: jobs, clients, addresses, visits, notes, appliances, invoices and estimates. Look the data up first — do not invent it.

You CAN and MUST call tools instead of only saying you did it:
- look up jobs (list_jobs, get_job), including closed ones if asked;
- search clients (search_clients);
- open a job card (open_job);
- open a client card (open_client);
- open today's route in the calendar (open_route);
- open turn-by-turn navigation (navigate_to_job);
- call the client in the app (call_client);
- open the chat (write_client) or send SMS (send_sms);
- reschedule a visit (reschedule_visit);
- create a job (create_job);
- change scale/colors (update_settings) or open display settings (open_settings);
- look at the current app screen (look_at_screen).

NEVER say you opened, sent, called, or routed until the matching tool returns ok.
Call the tool first, wait for the result, then say one short sentence.
After an action, say briefly what you did and for whom.

For repair, error codes, test/service mode, and ohm specs do NOT invent procedures from memory.
Always call lookup_service_guide first:
- query — the technician's question;
- brand — Samsung, LG, Whirlpool, GE, etc. if known;
- appliance — fridge / washer / dryer / dishwasher / range;
- code — error code if given (F21, 3E, LE, E18…);
- kind — test_modes, field_guide, electrical, or empty.
If they mean the current job, call get_job first, then lookup with that brand and appliance.
Answer from the guide cards: how to enter, steps, how to exit, typical fix. If found=false, say the guide has no card — do not invent a sequence.

If they say "send SMS that I'm on my way" — call send_sms with template=on_way and job_query=next if no client is named.
If they want you to text the client a custom reply (reschedule, "I'll be there today", answer a question) — call send_sms with text=the message. Do not claim you sent it until the tool returns ok.
If they ask to move a visit to a day and time — call reschedule_visit (date=YYYY-MM-DD, time=HH:mm). The tool writes the new date on the job and texts the client with that date and time. Do not say it was moved until the tool returns ok and scheduled_at.
After an action, say briefly what you did and for whom.
Today's date and time come from tools. Do not invent jobs: call list_jobs or get_job first.
''';

  static const _holdAfterSpeech = Duration(milliseconds: 1200);

  final _recorder = AudioRecorder();
  final _player = PcmPlaybackQueue();
  LiveSession? _session;
  StreamSubscription<Uint8List>? _micSub;
  Timer? _holdTimer;
  Timer? _speakWatchdog;
  Timer? _intentTimer;
  Timer? _screenTimer;
  DateTime _sendAudioAfter = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<String, DateTime> _recentTools = {};
  bool _opening = false;
  bool _closing = false;
  bool _reconnectScheduled = false;

  bool isOpen = false;
  bool isConnecting = false;
  bool isSpeaking = false;
  bool isPaused = false;
  String statusText = '';
  String? errorText;
  String transcript = '';
  String _assistantName = SettingsService.defaultAssistantWakeWord;
  String _lastSpoken = '';
  Future<void> Function()? onToolsFinished;

  String get _speakingStatus =>
      _t('$_assistantName отвечает', '$_assistantName is speaking');

  String _t(String ru, String en) => AppLocale.instance.t(ru, en);

  Future<void> open() async {
    if (isOpen || _opening) return;
    _opening = true;
    _closing = false;
    isOpen = true;
    isConnecting = true;
    isPaused = false;
    errorText = null;
    transcript = '';
    _lastSpoken = '';
    statusText = _t('Подключаюсь...', 'Connecting...');
    notifyListeners();

    try {
      await _connectSession();
      await _startMic();
      isConnecting = false;
      statusText = _t('Слушаю — нажмите для паузы', 'Listening — tap to pause');
      notifyListeners();
      _startScreenSight();
    } catch (e) {
      errorText = e.toString();
      statusText = _t('Не удалось подключиться', 'Could not connect');
      isConnecting = false;
      notifyListeners();
    } finally {
      _opening = false;
    }
  }

  Future<void> _connectSession() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      throw Exception('Нет доступа к микрофону');
    }
    if (kGeminiApiKey.isEmpty || kGeminiApiKey == 'YOUR_GEMINI_API_KEY') {
      throw Exception('Не настроен ключ Gemini');
    }

    final config = await SettingsService.loadConfig();
    final english =
        SettingsService.readAssistantLanguage(config) ==
            SettingsService.assistantLanguageEn;
    _assistantName = SettingsService.readAssistantWakeWord(config);
    final genAI = GoogleGenAI(apiKey: kGeminiApiKey);
    _session = await genAI.live.connect(
      LiveConnectParameters(
        model: _model,
        systemInstruction: Content(
          parts: [
            Part(
              text: english
                  ? _systemPromptEn(_assistantName)
                  : _systemPromptRu(_assistantName),
            ),
          ],
        ),
        config: GenerationConfig(
          responseModalities: [Modality.AUDIO],
          speechConfig: SpeechConfig(
            languageCode: AppLocale.instance.isEn ? 'en-US' : 'ru-RU',
            voiceConfig: VoiceConfig(
              prebuiltVoiceConfig: PrebuiltVoiceConfig(voiceName: 'Kore'),
            ),
          ),
        ),
        inputAudioTranscription: AudioTranscriptionConfig(),
        outputAudioTranscription: AudioTranscriptionConfig(),
        realtimeInputConfig: RealtimeInputConfig(
          activityHandling: ActivityHandling.NO_INTERRUPTION,
          automaticActivityDetection: AutomaticActivityDetection(
            disabled: false,
            startOfSpeechSensitivity: StartSensitivity.START_SENSITIVITY_HIGH,
            endOfSpeechSensitivity: EndSensitivity.END_SENSITIVITY_LOW,
            prefixPaddingMs: 400,
            silenceDurationMs: 900,
          ),
        ),
        tools: [_tools],
        callbacks: LiveCallbacks(
          onOpen: () {
            if (!isOpen) return;
            statusText = isPaused
                ? _t('Пауза', 'Paused')
                : _t('Слушаю — нажмите для паузы', 'Listening — tap to pause');
            isConnecting = false;
            notifyListeners();
          },
          onMessage: _onMessage,
          onError: (error, _) {
            if (!isOpen || _closing) return;
            errorText = error.toString();
            statusText = _t('Ошибка связи', 'Connection error');
            notifyListeners();
          },
          onClose: (_, reason) {
            if (!isOpen || _closing) return;
            _scheduleReconnect();
          },
        ),
      ),
    );
  }

  void _scheduleReconnect() {
    if (_reconnectScheduled || _closing || !isOpen) return;
    _reconnectScheduled = true;
    statusText = _t('Переподключаюсь...', 'Reconnecting...');
    notifyListeners();
    Future<void>.delayed(const Duration(milliseconds: 600), () async {
      _reconnectScheduled = false;
      if (!isOpen || _closing) return;
      try {
        await _player.stop();
        isSpeaking = false;
        _sendAudioAfter = DateTime.now().add(const Duration(milliseconds: 800));
        await _connectSession();
        if (isPaused) {
          statusText = _t('Пауза', 'Paused');
        } else {
          statusText = _t(
            'Слушаю — нажмите для паузы',
            'Listening — tap to pause',
          );
        }
        notifyListeners();
      } catch (e) {
        errorText = e.toString();
        statusText = _t('Связь оборвалась', 'Connection lost');
        notifyListeners();
      }
    });
  }

  Future<void> togglePause() async {
    if (!isOpen || isConnecting || _opening || _closing) return;
    if (isPaused) {
      isPaused = false;
      errorText = null;
      await _startMic();
      statusText = _t('Слушаю — нажмите для паузы', 'Listening — tap to pause');
    } else {
      isPaused = true;
      await _micSub?.cancel();
      _micSub = null;
      try {
        await _recorder.stop();
      } catch (_) {}
      await _player.stop();
      isSpeaking = false;
      statusText = _t('Пауза — нажмите, чтобы слушать', 'Paused — tap to listen');
    }
    notifyListeners();
  }

  void _startScreenSight() {
    _screenTimer?.cancel();
    unawaited(_pushScreen(force: true));
    _screenTimer = Timer.periodic(const Duration(milliseconds: 2800), (_) {
      unawaited(_pushScreen());
    });
  }

  Future<void> _pushScreen({bool force = false}) async {
    if (!isOpen || _closing || _session == null) return;
    if (!force && (isPaused || isSpeaking || isConnecting)) return;
    final bytes = await AssistantScreenSight.capture();
    if (bytes == null || bytes.isEmpty) return;
    if (!isOpen || _session == null) return;
    try {
      _session!.sendVideo(bytes, mimeType: 'image/png');
    } catch (e) {
      debugPrint('assistant screen push: $e');
    }
  }

  Future<void> close() async {
    _closing = true;
    isOpen = false;
    isConnecting = false;
    isSpeaking = false;
    isPaused = false;
    statusText = '';
    notifyListeners();
    _holdTimer?.cancel();
    _speakWatchdog?.cancel();
    _intentTimer?.cancel();
    _screenTimer?.cancel();
    _screenTimer = null;
    await _micSub?.cancel();
    _micSub = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    await _player.stop();
    try {
      await _session?.close();
    } catch (_) {}
    _session = null;
  }

  Future<void> _startMic() async {
    await _micSub?.cancel();
    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (_) {}
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
          manageBluetooth: false,
          audioSource: AndroidAudioSource.voiceRecognition,
          speakerphone: false,
          audioManagerMode: AudioManagerMode.modeNormal,
        ),
      ),
    );
    final holdUntil = DateTime.now().add(const Duration(milliseconds: 280));
    if (holdUntil.isAfter(_sendAudioAfter)) {
      _sendAudioAfter = holdUntil;
    }
    _micSub = stream.listen((chunk) {
      final session = _session;
      if (session == null || chunk.isEmpty) return;
      if (!_shouldSendMic()) return;
      session.sendRealtimeInput(
        audio: Blob(
          mimeType: 'audio/pcm;rate=16000',
          data: base64Encode(chunk),
        ),
      );
    });
  }

  bool _shouldSendMic() {
    if (isPaused) return false;
    if (isSpeaking || _player.isPlaying) return false;
    if (DateTime.now().isBefore(_sendAudioAfter)) return false;
    return true;
  }

  bool _soundsLikeEcho(String text) {
    final a = _normVoice(text);
    final b = _normVoice(_lastSpoken);
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;
    final shorter = a.length <= b.length ? a : b;
    final longer = a.length <= b.length ? b : a;
    return shorter.length >= 12 &&
        longer.contains(shorter) &&
        shorter.length / longer.length >= 0.78;
  }

  String _normVoice(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9а-яё]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  void _holdMicAfterSpeech() {
    _holdTimer?.cancel();
    _speakWatchdog?.cancel();
    _speakWatchdog = Timer(const Duration(seconds: 10), () {
      if (!isOpen || isPaused) return;
      if (!isSpeaking || _player.isPlaying) return;
      isSpeaking = false;
      if (!isPaused) {
        statusText = _t('Слушаю — нажмите для паузы', 'Listening — tap to pause');
        notifyListeners();
      }
    });
    _holdTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
      if (_player.isPlaying) return;
      timer.cancel();
      isSpeaking = false;
      _sendAudioAfter = DateTime.now().add(_holdAfterSpeech);
      if (!isPaused) {
        statusText = _t('Слушаю — нажмите для паузы', 'Listening — tap to pause');
        notifyListeners();
      }
    });
  }

  Future<void> _onMessage(LiveServerMessage message) async {
    var changed = false;
    final content = message.serverContent;
    if (content?.interrupted == true) {
      _player.clear();
      isSpeaking = false;
      _sendAudioAfter = DateTime.now().add(const Duration(milliseconds: 250));
      if (!isPaused) {
        statusText = _t('Слушаю — нажмите для паузы', 'Listening — tap to pause');
        changed = true;
      }
    }

    final output = content?.outputTranscription?.text;
    if (output != null && output.trim().isNotEmpty) {
      _lastSpoken = output.trim();
    }

    final input = content?.interimInputTranscription?.text ??
        content?.inputTranscription?.text;
    if (input != null &&
        input.trim().isNotEmpty &&
        transcript != input.trim() &&
        !_soundsLikeEcho(input)) {
      transcript = input.trim();
      changed = true;
      _scheduleLocalIntent(transcript);
    }

    final audioB64 = message.data;
    if (audioB64 != null && audioB64.isNotEmpty) {
      if (!isSpeaking || statusText != _speakingStatus) {
        isSpeaking = true;
        statusText = _speakingStatus;
        changed = true;
      }
      if (changed) {
        notifyListeners();
        changed = false;
      }
      await _player.addPcm16Bytes(Uint8List.fromList(base64Decode(audioB64)));
      _holdMicAfterSpeech();
    }

    if (content?.turnComplete == true) {
      _holdMicAfterSpeech();
    }

    if (changed) notifyListeners();

    final calls = _collectCalls(message);
    var ranTool = false;
    for (final call in calls) {
      if (call.willContinue == true) continue;
      final name = (call.name ?? '').trim();
      if (name.isEmpty) continue;
      final id = (call.id ?? '').trim();
      final args = _argsOf(call);
      ranTool = true;
      await _runTool(name, args, id: id.isEmpty ? null : id);
    }
    if (ranTool) {
      _intentTimer?.cancel();
      await onToolsFinished?.call();
    }
  }

  List<FunctionCall> _collectCalls(LiveServerMessage message) {
    final out = <FunctionCall>[];
    final fromTool = message.toolCall?.functionCalls;
    if (fromTool != null) out.addAll(fromTool);
    final parts = message.serverContent?.modelTurn?.parts;
    if (parts != null) {
      for (final part in parts) {
        final call = part.functionCall;
        if (call != null) out.add(call);
      }
    }
    return out;
  }

  Map<String, dynamic> _argsOf(FunctionCall call) {
    final raw = call.args;
    if (raw == null) return <String, dynamic>{};
    return Map<String, dynamic>.from(raw);
  }

  bool _recentlyRan(String name) {
    final at = _recentTools[name];
    if (at == null) return false;
    return DateTime.now().difference(at) < const Duration(seconds: 8);
  }

  void _scheduleLocalIntent(String text) {
    _intentTimer?.cancel();
    _intentTimer = Timer(const Duration(milliseconds: 1400), () {
      if (!isOpen || isPaused) return;
      final parsed = AssistantIntents.parse(text);
      if (parsed == null) return;
      if (_recentlyRan(parsed.name)) return;
      unawaited(_runTool(parsed.name, parsed.args).then((_) {
        return onToolsFinished?.call();
      }));
    });
  }

  Future<void> _runTool(
    String name,
    Map<String, dynamic> args, {
    String? id,
  }) async {
    if (AssistantIntents.mutating.contains(name) && _recentlyRan(name)) {
      if (id != null) {
        try {
          _session?.sendFunctionResponse(
            id: id,
            name: name,
            response: {'ok': true, 'duplicate': true},
          );
        } catch (_) {}
      }
      return;
    }
    _recentTools[name] = DateTime.now();
    statusText = '${'Делаю'.tr}: $name';
    notifyListeners();
    Map<String, dynamic> result;
    try {
      if (name == 'look_at_screen') {
        await _pushScreen(force: true);
        result = {
          'ok': true,
          'seen': true,
          'note': 'Снимок текущего экрана отправлен. Ответь по картинке.',
        };
      } else {
        result = await AssistantTools.handle(name, args);
      }
    } catch (e) {
      result = {'ok': false, 'error': e.toString()};
    }
    if (id != null && id.isNotEmpty) {
      try {
        _session?.sendFunctionResponse(
          id: id,
          name: name,
          response: result,
        );
      } catch (e) {
        debugPrint('assistant function response: $e');
      }
    }
  }

  static final _tools = Tool(
    functionDeclarations: [
      FunctionDeclaration(
        behavior: Behavior.BLOCKING,
        name: 'list_jobs',
        description:
            'Список заявок CRM. when: today, upcoming, all (включая закрытые) или closed.',
        parameters: {
          'type': 'OBJECT',
          'properties': {
            'when': {
              'type': 'STRING',
              'description': 'today | upcoming | all',
            },
          },
        },
      ),
      FunctionDeclaration(
        behavior: Behavior.BLOCKING,
        name: 'get_job',
        description:
            'Полная карточка заявки: клиент, адрес, визиты, техника, заметки, счета. По имени, телефону, технике или «следующая».',
        parameters: {
          'type': 'OBJECT',
          'properties': {
            'query': {'type': 'STRING'},
          },
          'required': ['query'],
        },
      ),
      FunctionDeclaration(
        behavior: Behavior.BLOCKING,
        name: 'send_sms',
        description:
            'Отправить SMS клиенту. Можно шаблон on_way/parts/done ИЛИ свой text (ответ про перенос, «буду сегодня» и т.д.). job_query: следующая или имя.',
        parameters: {
          'type': 'OBJECT',
          'properties': {
            'job_query': {'type': 'STRING'},
            'template': {'type': 'STRING'},
            'text': {'type': 'STRING'},
          },
        },
      ),
      FunctionDeclaration(
        behavior: Behavior.BLOCKING,
        name: 'reschedule_visit',
        description:
            'Перенести визит заявки на новую дату и время. date=YYYY-MM-DD (или Tuesday / next Tuesday), time=HH:mm. Сам пишет дату в заявку и шлёт клиенту SMS с этой датой.',
        parameters: {
          'type': 'OBJECT',
          'properties': {
            'job_query': {'type': 'STRING'},
            'date': {'type': 'STRING'},
            'time': {'type': 'STRING'},
          },
          'required': ['date', 'time'],
        },
      ),
      FunctionDeclaration(
        behavior: Behavior.BLOCKING,
        name: 'create_job',
        description: 'Создать заявку на ремонт, если мастер явно просит.',
        parameters: {
          'type': 'OBJECT',
          'properties': {
            'client_name': {'type': 'STRING'},
            'client_phone': {'type': 'STRING'},
            'address': {'type': 'STRING'},
            'city': {'type': 'STRING'},
            'appliance_type': {'type': 'STRING'},
            'brand': {'type': 'STRING'},
            'problem': {'type': 'STRING'},
            'scheduled_date': {'type': 'STRING'},
            'scheduled_time': {'type': 'STRING'},
          },
        },
      ),
      FunctionDeclaration(
        behavior: Behavior.BLOCKING,
        name: 'search_clients',
        description:
            'Найти клиентов по имени или телефону. Возвращает телефон, адрес, почту и заметки.',
        parameters: {
          'type': 'OBJECT',
          'properties': {
            'query': {'type': 'STRING'},
          },
          'required': ['query'],
        },
      ),
      FunctionDeclaration(
        behavior: Behavior.BLOCKING,
        name: 'lookup_service_guide',
        description:
            'Справочник мастера: тестовые/сервисные режимы, коды ошибок, омы и диагностика. Вызывать при любом вопросе про ошибку, тест, сопротивление или ремонт по бренду.',
        parameters: {
          'type': 'OBJECT',
          'properties': {
            'query': {
              'type': 'STRING',
              'description': 'Фраза мастера или что искать',
            },
            'brand': {
              'type': 'STRING',
              'description': 'Samsung, LG, Whirlpool, GE, Bosch…',
            },
            'appliance': {
              'type': 'STRING',
              'description': 'fridge, washer, dryer, dishwasher, range',
            },
            'code': {
              'type': 'STRING',
              'description': 'Код ошибки, например F21, 3E, LE, E18',
            },
            'kind': {
              'type': 'STRING',
              'description': 'test_modes | field_guide | electrical',
            },
          },
          'required': ['query'],
        },
      ),
      FunctionDeclaration(
        behavior: Behavior.BLOCKING,
        name: 'open_job',
        description:
            'Открыть карточку заявки на экране. Вызывать, когда мастер просит открыть заявку или карточку работы.',
        parameters: {
          'type': 'OBJECT',
          'properties': {
            'query': {
              'type': 'STRING',
              'description': 'Имя клиента, телефон, техника или «следующая»',
            },
          },
        },
      ),
      FunctionDeclaration(
        behavior: Behavior.BLOCKING,
        name: 'open_client',
        description:
            'Открыть карточку клиента. Вызывать, когда мастер просит открыть клиента.',
        parameters: {
          'type': 'OBJECT',
          'properties': {
            'query': {'type': 'STRING'},
          },
          'required': ['query'],
        },
      ),
      FunctionDeclaration(
        behavior: Behavior.BLOCKING,
        name: 'open_route',
        description:
            'Открыть маршрут на сегодня в календаре. Вызывать при «проложи маршрут», «открой маршрут», «покажи маршрут».',
        parameters: {
          'type': 'OBJECT',
          'properties': {
            'when': {
              'type': 'STRING',
              'description': 'today, если не указано',
            },
          },
        },
      ),
      FunctionDeclaration(
        behavior: Behavior.BLOCKING,
        name: 'navigate_to_job',
        description:
            'Открыть Google Maps / навигатор до адреса заявки.',
        parameters: {
          'type': 'OBJECT',
          'properties': {
            'query': {'type': 'STRING'},
          },
        },
      ),
      FunctionDeclaration(
        behavior: Behavior.BLOCKING,
        name: 'call_client',
        description:
            'Позвонить клиенту из приложения (Twilio). Вызывать, когда мастер говорит «позвони».',
        parameters: {
          'type': 'OBJECT',
          'properties': {
            'query': {'type': 'STRING'},
            'phone': {'type': 'STRING'},
          },
        },
      ),
      FunctionDeclaration(
        behavior: Behavior.BLOCKING,
        name: 'write_client',
        description:
            'Открыть переписку SMS/email с клиентом.',
        parameters: {
          'type': 'OBJECT',
          'properties': {
            'query': {'type': 'STRING'},
          },
        },
      ),
      FunctionDeclaration(
        behavior: Behavior.BLOCKING,
        name: 'update_settings',
        description:
            'Изменить масштаб экрана, тему или шрифт. theme: navy, forest, wine, graphite, teal, night. scale: 0.85–1.4.',
        parameters: {
          'type': 'OBJECT',
          'properties': {
            'scale': {'type': 'NUMBER'},
            'theme': {'type': 'STRING'},
            'font': {'type': 'STRING'},
          },
        },
      ),
      FunctionDeclaration(
        behavior: Behavior.BLOCKING,
        name: 'look_at_screen',
        description:
            'Посмотреть текущий экран приложения. Вызывать, когда мастер спрашивает что на экране, что открыто, посмотри сюда.',
        parameters: {
          'type': 'OBJECT',
          'properties': {
            'why': {
              'type': 'STRING',
              'description': 'Зачем смотреть экран',
            },
          },
        },
      ),
      FunctionDeclaration(
        behavior: Behavior.BLOCKING,
        name: 'open_settings',
        description: 'Открыть экран настроек «Экран и шрифт».',
        parameters: {
          'type': 'OBJECT',
          'properties': {
            'page': {
              'type': 'STRING',
              'description': 'appearance',
            },
          },
        },
      ),
    ],
  );

  @override
  void dispose() {
    _holdTimer?.cancel();
    _speakWatchdog?.cancel();
    _intentTimer?.cancel();
    _screenTimer?.cancel();
    _micSub?.cancel();
    _recorder.dispose();
    super.dispose();
  }
}
