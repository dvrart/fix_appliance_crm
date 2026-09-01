import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Вид локальных уведомлений на телефоне. Каналы Android не трогаем —
/// иначе сбрасывается выбранный звук.
class NotificationLook extends ChangeNotifier {
  NotificationLook._();
  static final NotificationLook instance = NotificationLook._();

  static const _colorKey = 'notification_look_color';
  static const _colorizedKey = 'notification_look_colorized';
  static const _largeKey = 'notification_look_large';
  static const _timeoutKey = 'notification_look_timeout';
  static const _lockKey = 'notification_look_lock';

  static const int defaultColor = 0xFFFCC520;

  static const List<Color> palette = [
    Color(0xFFFCC520),
    Color(0xFF14557F),
    Color(0xFF2E7D32),
    Color(0xFF791B29),
    Color(0xFF6A1B9A),
    Color(0xFFEF6C00),
    Color(0xFF00838F),
    Color(0xFF37474F),
  ];

  static const List<int> timeoutChoices = [3, 5, 8, 0];

  Color color = const Color(defaultColor);
  bool colorized = true;
  bool largeText = true;
  int timeoutSeconds = 5;
  String lockVisibility = 'public';

  Duration? get timeoutAfter => timeoutSeconds <= 0
      ? null
      : Duration(seconds: timeoutSeconds);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    color = Color(prefs.getInt(_colorKey) ?? defaultColor);
    colorized = prefs.getBool(_colorizedKey) ?? true;
    largeText = prefs.getBool(_largeKey) ?? true;
    timeoutSeconds = prefs.getInt(_timeoutKey) ?? 5;
    lockVisibility = prefs.getString(_lockKey) ?? 'public';
    notifyListeners();
  }

  Future<void> setColor(Color value) async {
    color = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_colorKey, value.toARGB32());
  }

  Future<void> setColorized(bool value) async {
    colorized = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_colorizedKey, value);
  }

  Future<void> setLargeText(bool value) async {
    largeText = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_largeKey, value);
  }

  Future<void> setTimeoutSeconds(int value) async {
    timeoutSeconds = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_timeoutKey, value);
  }

  Future<void> setLockVisibility(String value) async {
    lockVisibility = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lockKey, value);
  }

  Future<void> reset() async {
    color = const Color(defaultColor);
    colorized = true;
    largeText = true;
    timeoutSeconds = 5;
    lockVisibility = 'public';
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_colorKey);
    await prefs.remove(_colorizedKey);
    await prefs.remove(_largeKey);
    await prefs.remove(_timeoutKey);
    await prefs.remove(_lockKey);
  }
}
