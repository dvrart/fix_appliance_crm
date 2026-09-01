import 'dart:async';

import 'package:flutter/material.dart';

import 'app_feedback.dart';

enum FaceReaction { none, angry, happy }

/// Ключ корневого Navigator — звонки, ассистент, экраны поверх вкладок.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Команды между ассистентом Фикс и экранами приложения.
class AppCommands {
  static final ValueNotifier<int?> selectTab = ValueNotifier<int?>(null);
  static final ValueNotifier<String?> calendarMode = ValueNotifier<String?>(null);
  static final ValueNotifier<bool> calendarAtHome = ValueNotifier<bool>(false);
  /// 0 = звонки, 1 = переписка на вкладке «Связь».
  static final ValueNotifier<int> commsTab = ValueNotifier<int>(0);
  static final ValueNotifier<int> faceTick = ValueNotifier<int>(0);
  static ValueNotifier<int> get angryFaceTick => faceTick;
  static FaceReaction reaction = FaceReaction.none;
  static DateTime? _reactionStarted;
  static Duration _reactionDuration = Duration.zero;
  static Timer? _reactionTimer;
  static final List<bool Function()> _selectionGuards = [];

  static void addSelectionGuard(bool Function() clearIfNeeded) {
    _selectionGuards.add(clearIfNeeded);
  }

  static void removeSelectionGuard(bool Function() clearIfNeeded) {
    _selectionGuards.remove(clearIfNeeded);
  }

  /// Снимает выделение. true — назад уже обработан.
  static bool dismissSelections() {
    var cleared = false;
    for (final guard in List<bool Function()>.from(_selectionGuards)) {
      if (guard()) cleared = true;
    }
    return cleared;
  }

  static void openTab(int index) {
    selectTab.value = index;
  }

  static void openCalendarMode(String mode) {
    calendarMode.value = mode;
  }

  /// Default landing: calendar tab, week (or work week if weekends are hidden).
  static bool get isAngryFace => reaction == FaceReaction.angry;

  static double get reactionProgress {
    final start = _reactionStarted;
    if (start == null || reaction == FaceReaction.none) return 0;
    final ms = _reactionDuration.inMilliseconds;
    if (ms <= 0) return 1;
    return (DateTime.now().difference(start).inMilliseconds / ms).clamp(0.0, 1.0);
  }

  static void reactAngry({
    Duration duration = const Duration(milliseconds: 2000),
  }) {
    AppFeedback.pleasant();
    _play(FaceReaction.angry, duration);
  }

  /// Зелёная весёлая シ, затем галочка — на зелёное подтверждение.
  static void reactHappy({
    Duration duration = const Duration(milliseconds: 2200),
  }) {
    AppFeedback.pleasant();
    _play(FaceReaction.happy, duration);
  }

  static void _play(FaceReaction kind, Duration duration) {
    _reactionTimer?.cancel();
    reaction = kind;
    _reactionStarted = DateTime.now();
    _reactionDuration = duration;
    faceTick.value++;
    _reactionTimer = Timer(duration, () {
      reaction = FaceReaction.none;
      _reactionStarted = null;
      faceTick.value++;
    });
  }

  static void showCalendarHome() {
    if (calendarMode.value == 'home') {
      calendarMode.value = null;
    }
    calendarMode.value = 'home';
  }
}
