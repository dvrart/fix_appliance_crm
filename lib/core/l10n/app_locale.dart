import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/settings_service.dart';
import 'en_ui.dart';

/// Язык интерфейса. Документы (invoice / estimate / PDF) всегда на английском.
class AppLocale extends ChangeNotifier {
  AppLocale._();
  static final AppLocale instance = AppLocale._();

  static const String ru = 'ru';
  static const String en = 'en';

  String _code = ru;

  String get code => _code;
  bool get isEn => _code == en;
  Locale get locale =>
      isEn ? const Locale('en', 'US') : const Locale('ru', 'RU');
  String get dateLocale => isEn ? 'en' : 'ru';

  String t(String russian, [String? english]) {
    if (!isEn) return russian;
    if (english != null) return english;
    return kEnglishUi[russian] ?? russian;
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final local = prefs.getString('uiLanguage');
    if (local == en || local == ru) {
      _code = local!;
      return;
    }
    try {
      final config = await SettingsService.loadConfig();
      final remote = config['uiLanguage'] as String?;
      if (remote == en || remote == ru) {
        _code = remote!;
        await prefs.setString('uiLanguage', _code);
      }
    } catch (_) {}
  }

  Future<void> setLanguage(String code) async {
    final next = code == en ? en : ru;
    if (_code == next) return;
    _code = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('uiLanguage', _code);
    await SettingsService.updateConfig('uiLanguage', _code);
  }

  Future<void> toggle() => setLanguage(isEn ? ru : en);
}

extension AppLocaleX on BuildContext {
  String tr(String russian, [String? english]) =>
      AppLocale.instance.t(russian, english);
}

extension AppLocaleStringX on String {
  String get tr => AppLocale.instance.t(this);
}

/// Safe for Firestore/`dynamic` values. `value.tr` does not work on [dynamic].
String trAny(Object? value, [String? english]) =>
    AppLocale.instance.t(value?.toString() ?? '', english);
