import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/l10n/app_locale.dart';
import '../../../services/assistant_audio_service.dart';
import '../../../services/settings_service.dart';
import 'assistant_controller.dart';
import 'assistant_actions.dart';
import 'wake_word_service.dart';

class AssistantHost extends StatefulWidget {
  final Widget child;

  const AssistantHost({super.key, required this.child});

  static AssistantController? controllerOf(BuildContext context) {
    return context.findAncestorStateOfType<_AssistantHostState>()?.controller;
  }

  static Future<void> open(BuildContext context) async {
    await context
        .findAncestorStateOfType<_AssistantHostState>()
        ?.openAssistant();
  }

  static Future<void> close(BuildContext context) async {
    await context
        .findAncestorStateOfType<_AssistantHostState>()
        ?.closeAssistant();
  }

  /// Сохраняет ссылку на хост до закрытия drawer — контекст после pop уже мёртв.
  static Future<void> Function()? opener(BuildContext context) {
    final state = context.findAncestorStateOfType<_AssistantHostState>();
    if (state == null) return null;
    return state.openAssistant;
  }

  @override
  State<AssistantHost> createState() => _AssistantHostState();
}

class _AssistantHostState extends State<AssistantHost>
    with WidgetsBindingObserver {
  final controller = AssistantController();
  final _wake = WakeWordService();
  StreamSubscription? _configSub;
  StreamSubscription<AssistantAudioState>? _audioSub;
  AssistantAudioState _audioState = const AssistantAudioState(available: false);
  AppLifecycleState? _lifecycleState;
  Future<void> _wakeSync = Future.value();
  Future<void>? _closingAssistant;
  int _audioWatchEpoch = 0;
  bool _openingAssistant = false;
  bool _assistantEnabled = true;
  bool _wakeEnabled = true;
  bool _textFieldFocused = false;
  bool _keyboardShown = false;
  String? _lastWakeHint;

  @override
  void initState() {
    super.initState();
    _lifecycleState = WidgetsBinding.instance.lifecycleState;
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addListener(_onFocusChanged);
    _onFocusChanged();
    _readKeyboard();
    AssistantAudioService.playback.addListener(_onAssistantChanged);
    AssistantAudioService.playback.suspendMicrophone = _suspendForPlayback;
    unawaited(_watchAudio());
    _wake.onBlocked = _onWakeBlocked;
    _wake.applyPhrases(
      word: SettingsService.defaultAssistantWakeWord,
      aliases: SettingsService.defaultAssistantWakeAliases
          .split(RegExp(r'[,;\n]'))
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList(),
    );
    _wake.onWake = () {
      if (!_audioState.blocksWake && !AssistantAudioService.playback.isActive) {
        unawaited(openAssistant());
      }
    };
    controller.addListener(_onAssistantChanged);
    controller.onToolsFinished = () =>
        AssistantActions.flush(closeOverlay: closeAssistant);
    controller.onCloseRequested = closeAssistant;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(milliseconds: 700), () {
        if (mounted) unawaited(_syncWake());
      });
    });
    _configSub = SettingsService.watchConfig().listen((config) {
      _assistantEnabled = SettingsService.readAssistantEnabled(config);
      _wakeEnabled = SettingsService.readAssistantWakeEnabled(config);
      _wake.applyPhrases(
        word: SettingsService.readAssistantWakeWord(config),
        aliases: SettingsService.readAssistantWakeAliases(config),
      );
      unawaited(_syncWake());
    });
  }

  void _onAssistantChanged() {
    unawaited(_syncWake());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    unawaited(_watchAudio());
    unawaited(_syncWake());
  }

  /// Пока FIX печатает или диктует с клавиатуры, микрофон нужен клавиатуре:
  /// её голосовой ввод — тот же SpeechRecognizer, что и wake-слушатель, и
  /// вдвоём они не работают. Поле ввода в фокусе или клавиатура открыта —
  /// wake-слово отпускает микрофон, закрыли — слушает снова.
  bool get _typing => _textFieldFocused || _keyboardShown;

  void _onFocusChanged() {
    final focus = FocusManager.instance.primaryFocus;
    final editing = focus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;
    if (editing == _textFieldFocused) return;
    _textFieldFocused = editing;
    unawaited(_syncWake());
  }

  void _readKeyboard() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final shown = views.any((view) => view.viewInsets.bottom > 0);
    if (shown == _keyboardShown) return;
    _keyboardShown = shown;
    unawaited(_syncWake());
  }

  @override
  void didChangeMetrics() => _readKeyboard();

  bool get _appResumed =>
      _lifecycleState == null || _lifecycleState == AppLifecycleState.resumed;

  Future<void> _watchAudio() async {
    final epoch = ++_audioWatchEpoch;
    final previous = _audioSub;
    _audioSub = null;
    _audioState = const AssistantAudioState(available: false);
    await previous?.cancel();
    if (!mounted || epoch != _audioWatchEpoch || !_appResumed) return;
    _audioSub = AssistantAudioService.watchState().listen(
      (state) {
        if (!mounted || epoch != _audioWatchEpoch) return;
        _audioState = state;
        unawaited(_syncWake());
      },
      onError: (Object error) {
        if (!mounted || epoch != _audioWatchEpoch) return;
        _audioState = const AssistantAudioState(available: false);
        unawaited(_syncWake());
        debugPrint('Assistant audio state: $error');
      },
    );
  }

  void _onWakeBlocked(String reason) {
    if (!mounted || reason.trim().isEmpty) return;
    if (_lastWakeHint == reason) return;
    _lastWakeHint = reason;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(reason)));
  }

  Future<void> _syncWake() {
    final next = _wakeSync.then((_) async {
      if (!mounted) return;
      final want =
          _assistantEnabled &&
          _wakeEnabled &&
          !controller.isOpen &&
          !_openingAssistant &&
          _closingAssistant == null &&
          !AssistantAudioService.playback.isActive &&
          !_audioState.blocksWake &&
          !_typing &&
          _appResumed;
      if (want) {
        if (!_wake.isArmed) await _wake.start();
      } else if (_wake.isRunning) {
        await _wake.stop();
      }
    });
    _wakeSync = next.catchError((Object error) {
      debugPrint('Assistant microphone: $error');
    });
    return next;
  }

  Future<void> _suspendForPlayback() async {
    await _syncWake();
    if (controller.isOpen || _openingAssistant || _closingAssistant != null) {
      await closeAssistant();
    }
  }

  Future<void> openAssistant() async {
    if (!mounted ||
        !_appResumed ||
        _openingAssistant ||
        _closingAssistant != null) {
      return;
    }
    if (!_assistantEnabled || AssistantAudioService.playback.isActive) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AssistantAudioService.playback.isActive
                ? context.tr(
                    'Сначала остановите запись',
                    'Pause the recording first',
                  )
                : context.tr(
                    'Ассистент выключен в настройках',
                    'Assistant is turned off in Settings',
                  ),
          ),
        ),
      );
      return;
    }
    _openingAssistant = true;
    try {
      await _syncWake();
      final audio = await AssistantAudioService.readState();
      if (!mounted || !_appResumed || AssistantAudioService.playback.isActive) {
        return;
      }
      if (audio.callActive || !audio.available) return;
      await controller.open();
      final err = (controller.errorText ?? '').trim();
      if (mounted && !controller.isOpen && err.isNotEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(err)));
      }
    } finally {
      _openingAssistant = false;
      await _syncWake();
    }
  }

  Future<void> closeAssistant() async {
    if (_closingAssistant != null) return _closingAssistant;
    final closing = Future<void>.sync(controller.close);
    _closingAssistant = closing;
    try {
      await closing;
    } finally {
      _closingAssistant = null;
      await _syncWake();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeListener(_onFocusChanged);
    _audioWatchEpoch++;
    _audioSub?.cancel();
    _configSub?.cancel();
    AssistantAudioService.playback.removeListener(_onAssistantChanged);
    AssistantAudioService.playback.suspendMicrophone = null;
    controller.removeListener(_onAssistantChanged);
    _wake.dispose();
    unawaited(controller.close().whenComplete(controller.dispose));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
