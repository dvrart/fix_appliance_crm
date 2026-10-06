import 'package:flutter/material.dart';

import 'app_feedback.dart';

/// ScaffoldMessenger, у которого любой SnackBar живёт
/// [AppFeedback.noticeDuration] — сколько бы ни просил вызывающий код и даже
/// с кнопкой (иначе такие SnackBar висят, пока их не смахнут).
class QuickScaffoldMessenger extends ScaffoldMessenger {
  const QuickScaffoldMessenger({super.key, required super.child});

  @override
  ScaffoldMessengerState createState() => _QuickScaffoldMessengerState();
}

class _QuickScaffoldMessengerState extends ScaffoldMessengerState {
  @override
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showSnackBar(
    SnackBar snackBar, {
    AnimationStyle? snackBarAnimationStyle,
  }) {
    return super.showSnackBar(
      SnackBar(
        key: snackBar.key,
        content: snackBar.content,
        backgroundColor: snackBar.backgroundColor,
        elevation: snackBar.elevation,
        margin: snackBar.margin,
        padding: snackBar.padding,
        width: snackBar.width,
        shape: snackBar.shape,
        hitTestBehavior: snackBar.hitTestBehavior,
        behavior: snackBar.behavior,
        action: snackBar.action,
        actionOverflowThreshold: snackBar.actionOverflowThreshold,
        showCloseIcon: snackBar.showCloseIcon,
        closeIconColor: snackBar.closeIconColor,
        duration: AppFeedback.noticeDuration,
        persist: false,
        animation: snackBar.animation,
        onVisible: snackBar.onVisible,
        dismissDirection: snackBar.dismissDirection,
        clipBehavior: snackBar.clipBehavior,
      ),
      snackBarAnimationStyle: snackBarAnimationStyle,
    );
  }
}
