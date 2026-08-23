import 'package:flutter/material.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

class AppCommands {
  AppCommands._();

  /// `day` | `week` | `workWeek` | `list` | `route`
  static final ValueNotifier<String?> calendarMode = ValueNotifier<String?>(null);

  static final ValueNotifier<int> openTabIndex = ValueNotifier<int>(-1);

  static void openTab(int index) {
    openTabIndex.value = index;
  }

  static void showCalendarWeek() {
    calendarMode.value = 'week';
  }
}
