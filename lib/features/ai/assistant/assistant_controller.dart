import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:gemini_live/gemini_live.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../../../core/api_keys.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../services/assistant_audio_service.dart';
import '../../../services/settings_service.dart';
import 'assistant_screen_sight.dart';
import 'assistant_tools.dart';
import 'pcm_playback_queue.dart';

class AssistantController extends ChangeNotifier {
  static const _model = 'gemini-3.8-live';

  static String _systemPromptRu(String name) => '''
Ты — $name, голосовой ассистент мастера по ремонту бытовой техники в Канаде (приложение Fix Appliance CRM).
Мастер вызывает тебя словом «$name» (его можно сменить в настройках).
Мастер говорит по-русски или по-английски — всегда понимай оба языка.
Говори по-русски, коротко и по делу, как коллега в машине. Не читай JSON вслух.
Не заканчивай разговор сам: после ответа жди следующую фразу мастера.
Если мастер говорит «конец», «стоп», «хватит» — коротко попрощайся одним словом и замолчи (приложение само закроет сессию).
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
- найти запчасть в наличии по самой выгодной цене и открыть проверенные ссылки для покупки (search_parts);
- менять масштаб и цвета экрана (update_settings), открыть настройки экрана (open_settings);
- посмотреть текущий экран приложения (look_at_screen).

НИКОГДА не говори «открыл / отправил / позвонил / проложил», пока инструмент не вернул ok.
Сначала вызови инструмент, дождись результата, потом одна короткая фраза.
После действия коротко скажи, что сделал.

Если мастер просит найти запчасть, узнать где купить дешевле, проверить наличие или дать ссылки («найди запчасть для этой посудомойки», «где купить сливной насос», «поищи деталь W10876537»):
- НИКОГДА не придумывай артикулы, цены, наличие и ссылки из памяти;
- если речь про открытую карточку или фото шильдика/детали на экране, можешь сначала посмотреть экран (look_at_screen), если на нём открыто фото шильдика или этикетки, и обязательно вызывай search_parts (передай job_query='current', если речь про текущую заявку/технику, плюс известные part_query, part_number, appliance_type, brand, model);
- search_parts сам тщательно проверит точный OEM-артикул, совместимость с моделью, собственный склад мастера, живое наличие и цены в канадских магазинах и откроет на экране проверенные ссылки для покупки;
- если search_parts вернул needs_clarification=true — коротко спроси у мастера то, чего не хватает (номер модели с шильдика или какая именно деталь нужна);
- когда search_parts вернул ok=true — назови проверенный артикул, скажи если деталь уже есть на своём складе, и ОБЯЗАТЕЛЬНО назови ОБА варианта с ценой и магазином: 1) самый дешёвый аналог / вариант с Amazon.ca или XPart (cheapest_aftermarket_or_amazon / cheapest_in_stock), и 2) самый выгодный оригинал OEM (cheapest_oem_in_stock), плюс скажи, что ссылки на дешёвые аналоги с Amazon.ca и на оригинал открыты на экране.

По ремонту и диагностике НЕ выдумывай сервисный режим, коды ошибок и омы из памяти.
У тебя есть полный доступ ко всей базе знаний мастера через инструмент lookup_service_guide (коды ошибок, вход в тестовые режимы, калибровка, распиновка плат, tech sheets вроде W11448643, W11580994, 31-3000205, Омы по всем брендам — Whirlpool, Maytag, Amana, Samsung, LG, GE, Frigidaire, Electrolux, Bosch, Miele, Blomberg, Beko, Speed Queen, Midea, Insignia, Haier и др.):
- query — что спросил мастер;
- brand — бренд, если назван (Samsung, LG, Whirlpool, Maytag, GE, Bosch, Frigidaire, Electrolux, Speed Queen, Blomberg, Beko, Miele, Midea…);
- appliance — fridge / freezer / washer / dryer / dishwasher / range / cooktop / microwave / other;
- code — код ошибки или номер мануала tech sheet (F7E1, F21, 3E, LE, E15, W11448643, W11580994…);
- kind — test_modes (вход в тестовый режим, ручной тест и калибровка), error_codes (коды ошибок и двоичная расшифровка LED), electrical (распиновка разъёмов, омы, напряжения), field_guide (пошаговая диагностика), или пусто.
Если мастер спрашивает «как войти в тестовый режим» — обязательно вызови lookup_service_guide с kind='test_modes' и подробно, чётко по шагам объясни процедуру входа, какие индикаторы загораются и как выбрать нужный тест или калибровку.
Если мастер просит открыть раздел «Ошибка и диагностика» на экране — вызови open_diagnostics.

Если мастер просит отправить сообщение / SMS (например «отправь сообщение хорошо, спасибо», «напиши я буду через 20 минут»):
- если на экране открыта переписка с клиентом или карточка клиента/заявки и мастер НЕ назвал другое конкретное имя — ВСЕГДА передавай job_query='current' (никогда не передавай случайные слова, технику или next, чтобы сообщение ушло строго тому человеку, чей чат или карточка открыты на экране!);
- если мастер явно назвал имя клиента, фамилию, улицу или телефон — передай ТОЛЬКО это имя/адрес/телефон в job_query (латиницей как в базе, либо сначала проверь через search_clients / list_jobs, чтобы на 100% не перепутать получателя);
- передавай job_query='next' ТОЛЬКО если мастер прямо сказал «следующему клиенту»;
- в поле text передавай ТОЧНО тот смысл, который продиктовал мастер, на грамотном английском (например для «хорошо, спасибо» -> text='Okay, thank you.') — не подменяй его шаблоном «я в пути» и не добавляй лишних слов, о которых мастер не просил. Не говори «отправил», пока send_sms не вернул ok=true.
Если мастер говорит перенести визит на другой день (с временем или только на день без времени) — вызови reschedule_visit (date=YYYY-MM-DD, и time=HH:mm если время названо). Не говори, что перенёс, пока инструмент не вернул ok и scheduled_at.
После действия коротко скажи, что сделал и кому.
Сегодняшняя дата и время приходят из инструментов. Не выдумывай заявки: сначала вызови list_jobs или get_job.
ВАЖНО про клиентов с несколькими объектами: у одного клиента (лендлорда, управляющего недвижимостью, например Kyle Malinouski) может быть несколько мест проведения работ (разные адреса и разные арендаторы), при этом мастер переписывается с ним с одного и того же номера телефона. Поэтому в одной переписке по одному номеру могут обсуждаться разные адреса и заявки. Всегда различай заявки одного клиента по адресу объекта (address / job_site_address) и контакту на месте (contact_name), проверяй все открытые заявки этого клиента через list_jobs или get_job и не путай один адрес клиента с другим.
''';

  static String _systemPromptEn(String name) => '''
You are $name, a voice assistant for an appliance-repair technician in Canada (Fix Appliance CRM).
The technician wakes you with the word "$name" (it can be changed in Settings).
The technician may speak Russian or English — always understand both.
Speak English, short and practical, like a colleague in the van. Never read JSON aloud.
Do not end the conversation yourself. After answering, wait for the next phrase.
If they say "end", "stop", "done" — say one short goodbye word and go silent (the app closes the session).
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
- find spare parts in stock at the lowest verified price and open verified buy links (search_parts);
- change scale/colors (update_settings) or open display settings (open_settings);
- look at the current app screen (look_at_screen).

NEVER say you opened, sent, called, or routed until the matching tool returns ok.
Call the tool first, wait for the result, then say one short sentence.
After an action, say briefly what you did and for whom.

When they ask to find a spare part, check prices/availability, or get links to buy ("find me a part for this dishwasher", "where is the cheapest drain pump in stock", "find W10876537"):
- NEVER invent part numbers, prices, stock status, or URLs from memory;
- if a rating plate or part sticker photo might be open on screen, call look_at_screen to read the model/part number if needed, and ALWAYS call search_parts (pass job_query='current' when referring to the open job/appliance, plus known part_query, part_number, appliance_type, brand, model);
- search_parts thoroughly verifies the exact OEM part number, model compatibility, own warehouse stock, and live prices/availability across Canadian suppliers, and opens verified purchase links on screen;
- if search_parts returns needs_clarification=true, briefly ask for the missing detail (rating-plate model number or specific part);
- when search_parts returns ok=true, state the verified part number, mention if it is already in the technician's own warehouse, name the cheapest verified in-stock option (and cheapest genuine OEM if different from aftermarket) with store and price, and confirm that verified buy links are open on screen.

For repair, error codes, test/service mode, and ohm specs do NOT invent procedures from memory.
Always call lookup_service_guide first (stored on the server):
- query — the technician's question;
- brand — Samsung, LG, Whirlpool, Maytag, KitchenAid, GE, Bosch, Frigidaire, Electrolux, Miele, Fisher & Paykel, Midea, Panasonic, etc. if known;
- appliance — fridge / freezer / washer / dryer / dishwasher / range / cooktop / microwave / other;
- code — error code if given (F21, 3E, LE, E15, E09, Er IF, SY EF, d80, F7E1, H97…);
- kind — error_codes, test_modes, field_guide, electrical, or empty.
If they mean the current job, call get_job first, then lookup_service_guide with that brand and appliance.
If they ask to open the "Errors & diagnostics" screen ("open diagnostics", "show error codes") — call open_diagnostics.
Answer from the guide cards: error meaning, how to enter test mode, steps, ohms, how to exit, typical fix. If found=false, say the guide has no card — do not invent a sequence.

If they ask to send an SMS ("send 'okay, thank you'", "I'm on my way, I'll be there in 20 minutes", custom message):
- if a client conversation or job/client card is open on screen and no other specific client was named — ALWAYS pass job_query='current' so it goes strictly to the person currently open on screen;
- if they explicitly named a client, street, or phone — pass ONLY that exact name/address/phone in job_query (verify via search_clients / list_jobs if unsure). Pass job_query='next' ONLY if they explicitly said "next client";
- pass the exact dictated message in English in `text` (e.g. "Okay, thank you.") without replacing it with an unrelated template. Do not claim you sent it until send_sms returns ok=true.
If they ask to move a visit to a day (with a time, or date only without a time) — call reschedule_visit (date=YYYY-MM-DD, and time=HH:mm if given). Do not say it was moved until the tool returns ok and scheduled_at.
After an action, say briefly what you did and for whom.
Today's date and time come from tools. Do not invent jobs: call list_jobs or get_job first.
IMPORTANT about multi-property clients: one client (landlord or property manager, e.g. Kyle Malinouski) can have multiple job sites / properties at different addresses while texting and calling from a single phone number. In the same SMS thread with that phone number, different messages may refer to different addresses and jobs. Always distinguish a client's jobs by their work address (address / job_site_address) and on-site tenant (contact_name), check all open jobs for that client via list_jobs or get_job, and never mix up one property address with another.
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
  bool _togglingPause = false;
  bool _disposed = false;
  int _generation = 0;
  int _connectionGeneration = 0;
  Future<bool>? _focusRequest;
  Future<void>? _closeFuture;
  Future<void> _micOperation = Future<void>.value();

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
  Future<void> Function()? onCloseRequested;

  String get _speakingStatus =>
      _t('$_assistantName отвечает', '$_assistantName is speaking');

  String _t(String ru, String en) => AppLocale.instance.t(ru, en);

  bool _isCurrent(int generation) =>
      generation == _generation &&
      isOpen &&
      !_closing &&
      !_disposed &&
      !AssistantAudioService.playback.isActive;

  bool _isCurrentConnection(int generation, int connection) =>
      _isCurrent(generation) && connection == _connectionGeneration;

  Future<void> open() async {
    if (isOpen ||
        _opening ||
        _closing ||
        _disposed ||
        AssistantAudioService.playback.isActive) {
      return;
    }
    final generation = ++_generation;
    final connection = ++_connectionGeneration;
    _opening = true;
    _closeFuture = null;
    isOpen = true;
    isConnecting = true;
    isPaused = false;
    errorText = null;
    transcript = '';
    _lastSpoken = '';
    statusText = _t('Подключаюсь...', 'Connecting...');
    notifyListeners();

    try {
      if (!_isCurrentConnection(generation, connection)) return;
      _focusRequest = AssistantAudioService.requestFocus();
      final focused = await _focusRequest!;
      if (!_isCurrentConnection(generation, connection)) return;
      if (!focused) {
        throw Exception(
          _t('Звук сейчас недоступен', 'Audio is currently unavailable'),
        );
      }
      await _connectSession(generation, connection);
      if (!_isCurrentConnection(generation, connection)) return;
      await _startMic(generation);
      if (!_isCurrentConnection(generation, connection)) return;
      isConnecting = false;
      statusText = _t('Слушаю — нажмите для паузы', 'Listening — tap to pause');
      notifyListeners();
      if (_isCurrentConnection(generation, connection)) _startScreenSight();
    } catch (e) {
      if (!_isCurrentConnection(generation, connection)) return;
      final error = _friendlyError(e);
      final closing = close();
      final closedGeneration = _generation;
      await closing;
      if (_disposed || closedGeneration != _generation) return;
      errorText = error;
      statusText = _t('Не удалось подключиться', 'Could not connect');
      notifyListeners();
    } finally {
      if (generation == _generation) _opening = false;
    }
  }

  String _friendlyError(Object e) {
    final raw = e.toString();
    if (raw.contains('Нет доступа к микрофону') ||
        raw.toLowerCase().contains('microphone')) {
      return _t(
        'Нет доступа к микрофону. Разрешите в настройках телефона.',
        'Microphone access denied. Allow it in phone settings.',
      );
    }
    if (raw.contains('ключ Gemini') || raw.contains('Gemini')) {
      return _t('Не настроен ключ Gemini', 'Gemini API key is not set');
    }
    return raw;
  }

  Future<void> _connectSession(int generation, int connection) async {
    bool current() => _isCurrentConnection(generation, connection);
    if (!current()) return;
    final mic = await Permission.microphone.request();
    if (!current()) return;
    if (!mic.isGranted) {
      throw Exception('Нет доступа к микрофону');
    }
    if (kGeminiApiKey.isEmpty || kGeminiApiKey == 'YOUR_GEMINI_API_KEY') {
      throw Exception('Не настроен ключ Gemini');
    }

    final config = await SettingsService.loadConfig();
    if (!current()) return;
    final english =
        SettingsService.readAssistantLanguage(config) ==
            SettingsService.assistantLanguageEn;
    _assistantName = SettingsService.readAssistantWakeWord(config);
    final voice = SettingsService.readAssistantVoice(config);
    final genAI = GoogleGenAI(apiKey: kGeminiApiKey);
    final session = await genAI.live.connect(
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
              prebuiltVoiceConfig: PrebuiltVoiceConfig(voiceName: voice),
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
            if (!current()) return;
            statusText = isPaused
                ? _t('Пауза', 'Paused')
                : _t('Слушаю — нажмите для паузы', 'Listening — tap to pause');
            isConnecting = false;
            notifyListeners();
          },
          onMessage: (message) => _onMessage(message, generation, connection),
          onError: (error, _) {
            if (!current()) return;
            errorText = error.toString();
            statusText = _t('Ошибка связи', 'Connection error');
            notifyListeners();
          },
          onClose: (_, reason) {
            if (!current()) return;
            _scheduleReconnect(generation, connection);
          },
        ),
      ),
    );
    if (!current()) {
      unawaited(_closeSession(session));
      return;
    }
    _session = session;
  }

  Future<void> _closeSession(LiveSession session) async {
    try {
      await session.close();
    } catch (_) {}
  }

  void _scheduleReconnect(int generation, int connection) {
    if (_reconnectScheduled || !_isCurrentConnection(generation, connection)) {
      return;
    }
    _reconnectScheduled = true;
    statusText = _t('Переподключаюсь...', 'Reconnecting...');
    notifyListeners();
    Future<void>.delayed(const Duration(milliseconds: 600), () async {
      if (!_isCurrentConnection(generation, connection)) return;
      _reconnectScheduled = false;
      final nextConnection = ++_connectionGeneration;
      try {
        await _player.stop();
        if (!_isCurrentConnection(generation, nextConnection)) return;
        isSpeaking = false;
        _sendAudioAfter = DateTime.now().add(const Duration(milliseconds: 800));
        await _connectSession(generation, nextConnection);
        if (!_isCurrentConnection(generation, nextConnection)) return;
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
        if (!_isCurrentConnection(generation, nextConnection)) return;
        errorText = e.toString();
        statusText = _t('Связь оборвалась', 'Connection lost');
        notifyListeners();
      }
    });
  }

  Future<void> togglePause() async {
    final generation = _generation;
    if (!_isCurrent(generation) || isConnecting || _opening || _togglingPause) {
      return;
    }
    _togglingPause = true;
    try {
      if (isPaused) {
        isPaused = false;
        errorText = null;
        await _startMic(generation);
        if (!_isCurrent(generation)) return;
        statusText = _t('Слушаю — нажмите для паузы', 'Listening — tap to pause');
      } else {
        isPaused = true;
        await _stopMic();
        if (!_isCurrent(generation)) return;
        await _player.stop();
        if (!_isCurrent(generation)) return;
        isSpeaking = false;
        statusText = _t('Пауза — нажмите, чтобы слушать', 'Paused — tap to listen');
      }
      notifyListeners();
    } finally {
      if (generation == _generation) _togglingPause = false;
    }
  }

  void _startScreenSight() {
    _screenTimer?.cancel();
    unawaited(_pushScreen(force: true));
    _screenTimer = Timer.periodic(const Duration(milliseconds: 2800), (_) {
      unawaited(_pushScreen());
    });
  }

  Future<void> _pushScreen({bool force = false}) async {
    final generation = _generation;
    final session = _session;
    if (!_isCurrent(generation) || session == null) return;
    if (!force && (isPaused || isSpeaking || isConnecting)) return;
    final bytes = await AssistantScreenSight.capture();
    if (bytes == null || bytes.isEmpty) return;
    if (!_isCurrent(generation) || !identical(session, _session)) return;
    try {
      session.sendVideo(bytes, mimeType: 'image/png');
    } catch (e) {
      debugPrint('assistant screen push: $e');
    }
  }

  Future<void> close() {
    final closing = _closeFuture;
    if (closing != null) return closing;
    final completed = Completer<void>();
    _closeFuture = completed.future;
    unawaited(_close().then(completed.complete, onError: completed.completeError));
    return completed.future;
  }

  Future<void> _close() async {
    _closing = true;
    ++_generation;
    _opening = false;
    _togglingPause = false;
    _reconnectScheduled = false;
    isOpen = false;
    isConnecting = false;
    isSpeaking = false;
    isPaused = false;
    statusText = '';
    _holdTimer?.cancel();
    _speakWatchdog?.cancel();
    _intentTimer?.cancel();
    _screenTimer?.cancel();
    _screenTimer = null;
    final session = _session;
    _session = null;
    if (session != null) unawaited(_closeSession(session));
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

  bool _isEndCommand(String raw) {
    final t = _normVoice(raw);
    if (t.isEmpty) return false;
    const ends = {
      'конец',
      'end',
      'stop',
      'стоп',
      'хватит',
      'закрой',
      'выключись',
      'bye',
      'goodbye',
      'done',
      'all done',
      'finish',
      'enough',
    };
    if (ends.contains(t)) return true;
    for (final word in t.split(' ')) {
      if (ends.contains(word)) return true;
    }
    return t.startsWith('конец ') ||
        t.endsWith(' конец') ||
        t.contains(' конец ');
  }

  void _maybeCloseOnEnd(String text) {
    if (!_isEndCommand(text)) return;
    unawaited(onCloseRequested?.call());
  }

  Future<void> _serializeMic(Future<void> Function() action) {
    final operation = _micOperation.then((_) => action());
    _micOperation = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> refreshAudioRoute() async {
    final generation = _generation;
    if (!_isCurrent(generation) || isConnecting || _opening) return;
    await AssistantAudioService.requestFocus();
    if (!_isCurrent(generation) || isPaused) return;
    await _startMic(generation);
  }

  Future<void> _stopMic() => _serializeMic(() async {
    final subscription = _micSub;
    _micSub = null;
    try {
      await subscription?.cancel();
    } catch (_) {}
    try {
      await _recorder.stop();
    } catch (_) {}
  });

  Future<void> _startMic(int generation) => _serializeMic(() async {
    bool current() => _isCurrent(generation) && !isPaused;
    if (!current()) return;
    final subscription = _micSub;
    _micSub = null;
    await subscription?.cancel();
    if (!current()) return;
    try {
      final recording = await _recorder.isRecording();
      if (!current()) return;
      if (recording) {
        await _recorder.stop();
      }
    } catch (_) {}
    if (!current()) return;
    final inputDevice = await AssistantAudioService.preferredInputDevice();
    if (!current()) return;
    final stream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        device: inputDevice,
        echoCancel: true,
        noiseSuppress: true,
        autoGain: true,
        audioInterruption: AudioInterruptionMode.none,
        androidConfig: const AndroidRecordConfig(
          manageBluetooth: false,
          audioSource: AndroidAudioSource.voiceCommunication,
          speakerphone: false,
          audioManagerMode: AudioManagerMode.modeNormal,
        ),
      ),
    );
    if (!current()) {
      try {
        await _recorder.stop();
      } catch (_) {}
      return;
    }
    final holdUntil = DateTime.now().add(const Duration(milliseconds: 280));
    if (holdUntil.isAfter(_sendAudioAfter)) {
      _sendAudioAfter = holdUntil;
    }
    _micSub = stream.listen((chunk) {
      final session = _session;
      if (!_isCurrent(generation) || session == null || chunk.isEmpty) return;
      if (!_shouldSendMic()) return;
      session.sendRealtimeInput(
        audio: Blob(
          mimeType: 'audio/pcm;rate=16000',
          data: base64Encode(chunk),
        ),
      );
    });
  });

  bool _shouldSendMic() {
    if (!_isCurrent(_generation) || isPaused) return false;
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
    final generation = _generation;
    _holdTimer?.cancel();
    _speakWatchdog?.cancel();
    _speakWatchdog = Timer(const Duration(seconds: 10), () {
      if (!_isCurrent(generation) || isPaused) return;
      if (!isSpeaking || _player.isPlaying) return;
      isSpeaking = false;
      if (!isPaused) {
        statusText = _t('Слушаю — нажмите для паузы', 'Listening — tap to pause');
        notifyListeners();
      }
    });
    _holdTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
      if (!_isCurrent(generation)) {
        timer.cancel();
        return;
      }
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

  Future<void> _onMessage(
    LiveServerMessage message,
    int generation,
    int connection,
  ) async {
    bool current() => _isCurrentConnection(generation, connection);
    if (!current()) return;
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
      _maybeCloseOnEnd(transcript);
      if (!current()) return;
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
      if (!current()) return;
      await _player.addPcm16Bytes(Uint8List.fromList(base64Decode(audioB64)));
      if (!current()) return;
      _holdMicAfterSpeech();
    }

    if (content?.turnComplete == true) {
      _holdMicAfterSpeech();
    }

    if (changed) notifyListeners();
    if (!current()) return;

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
      if (!current()) return;
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
    final generation = _generation;
    final connection = _connectionGeneration;
    _intentTimer?.cancel();
    _intentTimer = Timer(const Duration(milliseconds: 1400), () {
      if (!_isCurrentConnection(generation, connection) || isPaused) return;
      final parsed = AssistantIntents.parse(text);
      if (parsed == null) return;
      if (_recentlyRan(parsed.name)) return;
      unawaited(_runTool(parsed.name, parsed.args).then((_) async {
        if (!_isCurrentConnection(generation, connection)) return;
        await onToolsFinished?.call();
      }));
    });
  }

  Future<void> _runTool(
    String name,
    Map<String, dynamic> args, {
    String? id,
  }) async {
    final generation = _generation;
    final connection = _connectionGeneration;
    if (!_isCurrentConnection(generation, connection)) return;
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
    if (!_isCurrentConnection(generation, connection)) return;
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
    if (!_isCurrentConnection(generation, connection)) return;
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
            'Отправить SMS клиенту. Если на экране открыт чат или карточка клиента и имя другого клиента не названо — передавай job_query="current". Если назван конкретный клиент — передай его имя/телефон в job_query. В text передай точный текст сообщения на английском.',
        parameters: {
          'type': 'OBJECT',
          'properties': {
            'job_query': {
              'type': 'STRING',
              'description':
                  'current (для открытого сейчас экрана переписки/карточки), имя клиента, адрес, телефон или next (только если явно просят следующему)',
            },
            'template': {
              'type': 'STRING',
              'description': 'on_way | parts | done (только если просят стандартный шаблон)',
            },
            'text': {
              'type': 'STRING',
              'description': 'Точный текст сообщения на английском языке',
            },
          },
        },
      ),
      FunctionDeclaration(
        behavior: Behavior.BLOCKING,
        name: 'reschedule_visit',
        description:
            'Перенести визит заявки на новую дату (и время, если указано). date=YYYY-MM-DD (или Tuesday / next Tuesday), time=HH:mm (необязательно, если известен только день).',
        parameters: {
          'type': 'OBJECT',
          'properties': {
            'job_query': {'type': 'STRING'},
            'date': {'type': 'STRING'},
            'time': {'type': 'STRING'},
          },
          'required': ['date'],
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
            'База знаний мастера (сервисные мануалы и tech sheets): вход в тестовый/сервисный режим и калибровка (test_modes), все коды ошибок и двоичная расшифровка мигания LED (error_codes), распиновка плат, напряжения и сопротивления в Омах (electrical), пошаговая диагностика (field_guide). Вызывать при любом вопросе про тестовый режим, калибровку, код ошибки, мануал (например W11448643) или Омы.',
        parameters: {
          'type': 'OBJECT',
          'properties': {
            'query': {
              'type': 'STRING',
              'description': 'Вопрос мастера или что искать',
            },
            'brand': {
              'type': 'STRING',
              'description':
                  'Whirlpool, Maytag, Amana, Samsung, LG, GE, Bosch, Frigidaire, Electrolux, Speed Queen, Blomberg, Beko, Miele, Midea, Insignia, Haier…',
            },
            'appliance': {
              'type': 'STRING',
              'description':
                  'fridge, freezer, washer, dryer, dishwasher, range, cooktop, microwave, other',
            },
            'code': {
              'type': 'STRING',
              'description':
                  'Код ошибки или номер tech sheet, например F7E1, F21, 3E, LE, E15, W11448643, W11580994',
            },
            'model': {
              'type': 'STRING',
              'description': 'Модель техники, если известна (например WTW4816FW, MVW6230HW, ELFW7637)',
            },
            'tech_sheet': {
              'type': 'STRING',
              'description': 'Номер сервисного листа (например W11448643)',
            },
            'kind': {
              'type': 'STRING',
              'description':
                  'test_modes | error_codes | electrical | field_guide',
            },
          },
        },
      ),
      FunctionDeclaration(
        behavior: Behavior.BLOCKING,
        name: 'open_diagnostics',
        description:
            'Открыть экран «Ошибка и диагностика» с кодами ошибок, тестовыми режимами и диагностикой бытовой техники.',
        parameters: {
          'type': 'OBJECT',
          'properties': {
            'query': {
              'type': 'STRING',
              'description': 'Код ошибки или поисковый запрос (необязательно)',
            },
            'appliance': {
              'type': 'STRING',
              'description':
                  'fridge, freezer, washer, dryer, dishwasher, range, cooktop, microwave, other, all',
            },
            'brand': {
              'type': 'STRING',
              'description': 'Бренд техники (необязательно)',
            },
            'kind': {
              'type': 'STRING',
              'description':
                  'error_codes | test_modes | field_guide | electrical | all',
            },
          },
        },
      ),
      FunctionDeclaration(
        behavior: Behavior.BLOCKING,
        name: 'search_parts',
        description:
            'Тщательно найти и проверить запчасть для техники: проверяет точный OEM-артикул, совместимость с моделью, собственный склад мастера, живое наличие и самые низкие цены в канадских магазинах, и открывает проверенные ссылки для покупки.',
        parameters: {
          'type': 'OBJECT',
          'properties': {
            'part_query': {
              'type': 'STRING',
              'description':
                  'Какая деталь нужна (например: сливной насос, drain pump, ТЭН, дверной замок)',
            },
            'part_number': {
              'type': 'STRING',
              'description':
                  'Известный артикул детали, если мастер назвал или прочитал с этикетки (например W10876537, 00631200, DC47-00019A)',
            },
            'appliance_type': {
              'type': 'STRING',
              'description':
                  'Тип техники (dishwasher, washer, dryer, fridge, range, microwave и т.д.)',
            },
            'brand': {
              'type': 'STRING',
              'description':
                  'Бренд техники (Bosch, Whirlpool, Samsung, LG, GE, Frigidaire, Maytag, KitchenAid, Miele и т.д.)',
            },
            'model': {
              'type': 'STRING',
              'description':
                  'Точный номер модели техники с шильдика или из заявки (например SHXM63W55N/01, WDT730PAHZ0)',
            },
            'problem': {
              'type': 'STRING',
              'description':
                  'Симптом или код ошибки, если конкретная деталь не названа (например E24 не сливает воду)',
            },
            'job_query': {
              'type': 'STRING',
              'description':
                  'current (для открытой сейчас заявки/техники), имя клиента или адрес',
            },
          },
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
    _disposed = true;
    unawaited(close().whenComplete(_recorder.dispose));
    super.dispose();
  }
}
