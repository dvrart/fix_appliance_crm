import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/l10n/app_locale.dart';
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
    await context.findAncestorStateOfType<_AssistantHostState>()?.openAssistant();
  }

  static Future<void> close(BuildContext context) async {
    await context.findAncestorStateOfType<_AssistantHostState>()?.closeAssistant();
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

class _AssistantHostState extends State<AssistantHost> with WidgetsBindingObserver {
  final controller = AssistantController();
  final _wake = WakeWordService();
  StreamSubscription? _configSub;
  bool _assistantEnabled = true;
  bool _wakeEnabled = true;
  String? _lastWakeHint;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
      unawaited(openAssistant());
    };
    controller.addListener(_onAssistantChanged);
    controller.onToolsFinished = () => AssistantActions.flush(
          closeOverlay: closeAssistant,
        );
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
    unawaited(_syncWake());
  }

  bool get _appResumed {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  void _onWakeBlocked(String reason) {
    if (!mounted || reason.trim().isEmpty) return;
    if (_lastWakeHint == reason) return;
    _lastWakeHint = reason;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(reason)),
    );
  }

  Future<void> _syncWake() async {
    final want = _assistantEnabled &&
        _wakeEnabled &&
        !controller.isOpen &&
        _appResumed;
    if (want) {
      if (!_wake.isArmed) await _wake.start();
    } else if (_wake.isArmed) {
      await _wake.stop();
    }
  }

  Future<void> openAssistant() async {
    if (!_assistantEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr(
                'Ассистент выключен в настройках',
                'Assistant is turned off in Settings',
              ),
            ),
          ),
        );
      }
      return;
    }
    await _wake.stop();
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;
    await controller.open();
    if (!controller.isOpen) {
      final err = (controller.errorText ?? '').trim();
      if (mounted && err.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(err)),
        );
      }
      await _syncWake();
      return;
    }
  }

  Future<void> closeAssistant() async {
    await controller.close();
    await _syncWake();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _configSub?.cancel();
    controller.removeListener(_onAssistantChanged);
    unawaited(_wake.stop());
    _wake.dispose();
    controller.close();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
