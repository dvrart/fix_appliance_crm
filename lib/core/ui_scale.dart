import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppColorPreset {
  final String id;
  final String label;
  final Color primary;
  final Color accent;

  const AppColorPreset({
    required this.id,
    required this.label,
    required this.primary,
    required this.accent,
  });
}

/// Оттенок ночного режима: от мягкого светло-тёмного до глубокого чёрного.
class NightShadePreset {
  final int id;
  final String labelRu;
  final String labelEn;
  final String subtitleRu;
  final String subtitleEn;
  final Color surface;
  final Color card;
  final Color cardMuted;
  final Color selectedCard;
  final Color border;
  final Color nonWorking;
  final Color ink;
  final Color inkMuted;

  const NightShadePreset({
    required this.id,
    required this.labelRu,
    required this.labelEn,
    required this.subtitleRu,
    required this.subtitleEn,
    required this.surface,
    required this.card,
    required this.cardMuted,
    required this.selectedCard,
    required this.border,
    required this.nonWorking,
    required this.ink,
    required this.inkMuted,
  });
}

/// Масштаб, шрифт, цвета темы и карточек. Хранится на устройстве.
class AppUiSettings extends ChangeNotifier {
  AppUiSettings._();
  static final AppUiSettings instance = AppUiSettings._();

  static const double minScale = 0.85;
  static const double maxScale = 1.4;
  static const List<double> presets = [0.85, 1.0, 1.15, 1.3];

  static const int defaultPrimary = 0xFF14557F;
  static const int defaultAccent = 0xFFFCC520;
  static const int defaultDanger = 0xFF791B29;
  static const int defaultSurface = 0xFFF5F5F5;
  static const int defaultDrawer = 0xFFBC8A51;
  static const int defaultPaper = 0xFFF3E6C4;
  static const int defaultName = 0xFF2A2218;
  static const int defaultAddress = 0xFF5C4E3A;
  static const int defaultBody = 0xFF1A1A1A;

  static const List<NightShadePreset> nightShades = [
    NightShadePreset(
      id: 0,
      labelRu: 'Светло-тёмный',
      labelEn: 'Light dark',
      subtitleRu: 'Мягкий графит',
      subtitleEn: 'Soft slate',
      surface: Color(0xFF2B323C),
      card: Color(0xFF353E4B),
      cardMuted: Color(0xFF404A59),
      selectedCard: Color(0xFF3D526B),
      border: Color(0xFF4E596A),
      nonWorking: Color(0xFF232932),
      ink: Color(0xFFF2F4F7),
      inkMuted: Color(0xFFCBD2D9),
    ),
    NightShadePreset(
      id: 1,
      labelRu: 'Не совсем тёмный',
      labelEn: 'Medium dark',
      subtitleRu: 'Спокойный тёмно-серый',
      subtitleEn: 'Balanced dark grey',
      surface: Color(0xFF1C2128),
      card: Color(0xFF252C35),
      cardMuted: Color(0xFF2F3742),
      selectedCard: Color(0xFF293B52),
      border: Color(0xFF3B4452),
      nonWorking: Color(0xFF15191F),
      ink: Color(0xFFE8ECEF),
      inkMuted: Color(0xFFB8C0C8),
    ),
    NightShadePreset(
      id: 2,
      labelRu: 'Сильно тёмный',
      labelEn: 'Deep dark',
      subtitleRu: 'Глубокий почти чёрный',
      subtitleEn: 'Deep near-black',
      surface: Color(0xFF0C0F13),
      card: Color(0xFF151920),
      cardMuted: Color(0xFF1E242D),
      selectedCard: Color(0xFF1C2C3F),
      border: Color(0xFF272E38),
      nonWorking: Color(0xFF07090C),
      ink: Color(0xFFE6E8EA),
      inkMuted: Color(0xFFB0B7BF),
    ),
  ];

  static const List<({int argb, String ru, String en})> barColors = [
    (argb: 0xFF14557F, ru: 'Синий', en: 'Blue'),
    (argb: 0xFF0D2235, ru: 'Полночь', en: 'Midnight'),
    (argb: 0xFF2B323C, ru: 'Светло-тёмный', en: 'Light dark'),
    (argb: 0xFF1C2128, ru: 'Графит', en: 'Graphite'),
    (argb: 0xFF0C0F13, ru: 'Чёрный', en: 'Black'),
    (argb: 0xFF37474F, ru: 'Серый', en: 'Slate'),
    (argb: 0xFF1B5E20, ru: 'Зелёный', en: 'Green'),
    (argb: 0xFF00695C, ru: 'Бирюза', en: 'Teal'),
    (argb: 0xFF6D1B2A, ru: 'Бордо', en: 'Wine'),
    (argb: 0xFF283593, ru: 'Индиго', en: 'Indigo'),
    (argb: 0xFF3E2723, ru: 'Кофе', en: 'Coffee'),
  ];

  static const List<AppColorPreset> themePresets = [
    AppColorPreset(
      id: 'navy',
      label: 'Синий и жёлтый',
      primary: Color(defaultPrimary),
      accent: Color(defaultAccent),
    ),
    AppColorPreset(
      id: 'forest',
      label: 'Зелёный',
      primary: Color(0xFF1B5E20),
      accent: Color(0xFFF9A825),
    ),
    AppColorPreset(
      id: 'wine',
      label: 'Бордо',
      primary: Color(0xFF6D1B2A),
      accent: Color(0xFFE8C39E),
    ),
    AppColorPreset(
      id: 'graphite',
      label: 'Графит',
      primary: Color(0xFF37474F),
      accent: Color(0xFF90A4AE),
    ),
    AppColorPreset(
      id: 'teal',
      label: 'Бирюза',
      primary: Color(0xFF00695C),
      accent: Color(0xFFFFC107),
    ),
    AppColorPreset(
      id: 'night',
      label: 'Ночь',
      primary: Color(0xFF0D1B2A),
      accent: Color(0xFFE0A100),
    ),
  ];

  static const Map<int, String> paperPresets = {
    defaultPaper: 'Старая книга',
    0xFFFBF3E0: 'Слоновая кость',
    0xFFFFF8E7: 'Кремовая',
    0xFFE8D5A3: 'Крафт',
    0xFFFFFFFF: 'Белая',
    0xFFF5F5F5: 'Серая',
  };

  static const Map<String, String> fonts = {
    '': 'Системный',
    'roboto': 'Roboto',
    'openSans': 'Open Sans',
    'lato': 'Lato',
    'nunito': 'Nunito',
    'rubik': 'Rubik',
    'sourceSans': 'Source Sans',
    'merriweather': 'Книжный',
    'ptSerif': 'PT Serif',
    'playfair': 'Playfair',
    'oswald': 'Oswald',
    'serif': 'Serif',
    'monospace': 'Моноширинный',
  };

  static const List<Color> palette = [
    Color(defaultPrimary),
    Color(0xFF1B5E20),
    Color(0xFF6D1B2A),
    Color(0xFF37474F),
    Color(0xFF00695C),
    Color(0xFF0D1B2A),
    Color(0xFF0D47A1),
    Color(0xFF4A148C),
    Color(0xFFBF360C),
    Color(0xFF3E2723),
    Color(defaultAccent),
    Color(0xFFF9A825),
    Color(0xFFE8C39E),
    Color(0xFF90A4AE),
    Color(0xFFFFC107),
    Color(0xFFE0A100),
    Color(0xFFFF7043),
    Color(0xFF66BB6A),
    Color(0xFF42A5F5),
    Color(0xFFAB47BC),
    Color(defaultName),
    Color(defaultAddress),
    Color(0xFF1A1A1A),
    Color(0xFF3D3D3D),
    Color(0xFF5D4037),
    Color(0xFFFFFFFF),
  ];

  double _scale = 1.0;
  double _persistedScale = 1.0;
  double _cardNameScale = 1.2;
  String _fontFamily = '';
  String _persistedFontFamily = '';
  int _primary = defaultPrimary;
  int _footer = 0;
  int _accent = defaultAccent;
  int _danger = defaultDanger;
  int _paper = defaultPaper;
  int _nameColor = defaultName;
  int _addressColor = defaultAddress;
  int _bodyColor = defaultBody;
  bool _hapticOnPress = true;
  bool _nightMode = false;
  bool _nightAuto = false;
  int _nightLevel = 1;
  int _nightFrom = 22 * 60;
  int _nightTo = 7 * 60;
  Timer? _nightTicker;

  /// Ночной режим включён руками.
  bool get nightMode => _nightMode;

  /// Ночной режим включается сам в заданные часы.
  bool get nightAuto => _nightAuto;

  /// Уровень темноты: 0 — светло-тёмный, 1 — не совсем тёмный, 2 — сильно тёмный.
  int get nightLevel => _nightLevel.clamp(0, nightShades.length - 1);

  NightShadePreset get nightShade => nightShades[nightLevel];

  /// 0 — нижняя панель такого же цвета, как шапка.
  int get footerRaw => _footer;

  /// Границы расписания в минутах от полуночи.
  int get nightFrom => _nightFrom;
  int get nightTo => _nightTo;

  TimeOfDay get nightFromTime =>
      TimeOfDay(hour: _nightFrom ~/ 60, minute: _nightFrom % 60);
  TimeOfDay get nightToTime =>
      TimeOfDay(hour: _nightTo ~/ 60, minute: _nightTo % 60);

  /// Темно ли прямо сейчас. Ручной переключатель главнее расписания:
  /// выехал на ночной вызов — включил, и приложение не спорит.
  bool get darkNow => _nightMode || (_nightAuto && nightScheduleActive());

  /// Окно может переходить через полночь (22:00 → 07:00) — тогда «внутри»
  /// значит «после начала или до конца», а не «между».
  bool nightScheduleActive([DateTime? now]) {
    final at = now ?? DateTime.now();
    final minutes = at.hour * 60 + at.minute;
    if (_nightFrom == _nightTo) return false;
    if (_nightFrom < _nightTo) {
      return minutes >= _nightFrom && minutes < _nightTo;
    }
    return minutes >= _nightFrom || minutes < _nightTo;
  }

  double get scale => _scale;
  double get persistedScale => _persistedScale;
  double get cardNameScale => _cardNameScale;
  String get fontFamily => _fontFamily;
  String get persistedFontFamily => _persistedFontFamily;
  bool get scaleDirty => _scale != _persistedScale;
  bool get fontDirty => _fontFamily != _persistedFontFamily;
  bool get appearanceDirty => scaleDirty || fontDirty;
  String? get themeFontFamily => _fontFamily.isEmpty ? null : _fontFamily;
  Color get primaryColor => Color(_primary);
  Color get footerColor => _footer == 0 ? Color(_primary) : Color(_footer);
  Color get accentColor => Color(_accent);
  Color get dangerColor => Color(_danger);
  Color get surfaceColor =>
      darkNow ? nightShade.surface : const Color(defaultSurface);
  Color get drawerHeaderColor => const Color(defaultDrawer);
  Color get paperColor =>
      darkNow ? nightShade.card : Color(_paper);
  Color get nameColor =>
      darkNow ? nightShade.ink : Color(_nameColor);
  Color get addressColor =>
      darkNow ? nightShade.inkMuted : Color(_addressColor);
  Color get bodyColor =>
      darkNow ? nightShade.ink : Color(_bodyColor);
  bool get hapticOnPress => _hapticOnPress;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _scale = (prefs.getDouble('uiScale') ?? 1.0).clamp(minScale, maxScale);
    _persistedScale = _scale;
    _cardNameScale =
        (prefs.getDouble('uiCardNameScale') ?? 1.2).clamp(1.0, 1.6);
    _fontFamily = prefs.getString('uiFontFamily') ?? '';
    _persistedFontFamily = _fontFamily;
    _primary = prefs.getInt('uiPrimary') ?? defaultPrimary;
    _footer = prefs.getInt('uiFooter') ?? 0;
    _accent = prefs.getInt('uiAccent') ?? defaultAccent;
    _danger = prefs.getInt('uiDanger') ?? defaultDanger;
    _paper = prefs.getInt('uiPaper') ?? defaultPaper;
    _nameColor = prefs.getInt('uiNameColor') ?? defaultName;
    _addressColor = prefs.getInt('uiAddressColor') ?? defaultAddress;
    _bodyColor = prefs.getInt('uiBodyColor') ?? defaultBody;
    _hapticOnPress = prefs.getBool('uiHapticOnPress') ?? true;
    _nightMode = prefs.getBool('uiNightMode') ?? false;
    _nightAuto = prefs.getBool('uiNightAuto') ?? false;
    _nightLevel = (prefs.getInt('uiNightLevel') ?? 1).clamp(0, nightShades.length - 1);
    _nightFrom = prefs.getInt('uiNightFrom') ?? 22 * 60;
    _nightTo = prefs.getInt('uiNightTo') ?? 7 * 60;
    _syncNightTicker();
  }

  /// Расписание без часов не сработает: экран перекрасится только при
  /// следующей перестройке, то есть случайно. Минута — достаточно точно и
  /// дёшево; при выключенном расписании таймера нет вовсе.
  void _syncNightTicker() {
    final needed = _nightAuto && !_nightMode;
    if (needed == (_nightTicker != null)) return;
    if (!needed) {
      _nightTicker?.cancel();
      _nightTicker = null;
      return;
    }
    var wasDark = nightScheduleActive();
    _nightTicker = Timer.periodic(const Duration(minutes: 1), (_) {
      final isDark = nightScheduleActive();
      if (isDark == wasDark) return;
      wasDark = isDark;
      notifyListeners();
    });
  }

  Future<void> setNightMode(bool value) async {
    if (value == _nightMode) return;
    _nightMode = value;
    _syncNightTicker();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('uiNightMode', value);
  }

  Future<void> setNightAuto(bool value) async {
    if (value == _nightAuto) return;
    _nightAuto = value;
    _syncNightTicker();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('uiNightAuto', value);
  }

  Future<void> setNightWindow({TimeOfDay? from, TimeOfDay? to}) async {
    if (from != null) _nightFrom = from.hour * 60 + from.minute;
    if (to != null) _nightTo = to.hour * 60 + to.minute;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('uiNightFrom', _nightFrom);
    await prefs.setInt('uiNightTo', _nightTo);
  }

  Future<void> setNightLevel(int level, {bool enableNow = false}) async {
    final next = level.clamp(0, nightShades.length - 1);
    final changedLevel = next != _nightLevel;
    final changedMode = enableNow && !darkNow;
    if (!changedLevel && !changedMode) return;
    _nightLevel = next;
    if (changedMode) {
      _nightMode = true;
      _syncNightTicker();
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('uiNightLevel', _nightLevel);
    if (changedMode) {
      await prefs.setBool('uiNightMode', true);
    }
  }

  Future<void> setFooterRaw(int argb) async {
    if (argb == _footer) return;
    _footer = argb;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (argb == 0) {
      await prefs.remove('uiFooter');
    } else {
      await prefs.setInt('uiFooter', argb);
    }
  }

  Future<void> setScale(double value) async {
    final next = value.clamp(minScale, maxScale);
    if (next == _scale) return;
    _scale = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('uiScale', _scale);
    _persistedScale = _scale;
  }

  void previewScale(double value) {
    final next = value.clamp(minScale, maxScale);
    if (next == _scale) return;
    _scale = next;
    notifyListeners();
  }

  Future<void> setCardNameScale(double value) async {
    final next = value.clamp(1.0, 1.6);
    if (next == _cardNameScale) return;
    _cardNameScale = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('uiCardNameScale', _cardNameScale);
  }

  Future<void> setFontFamily(String family) async {
    if (family == _fontFamily) return;
    _fontFamily = family;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('uiFontFamily', _fontFamily);
    _persistedFontFamily = _fontFamily;
  }

  void previewFontFamily(String family) {
    if (family == _fontFamily) return;
    _fontFamily = family;
    notifyListeners();
  }

  void previewAppearanceReset() {
    if (_scale == 1.0 && _fontFamily.isEmpty) return;
    _scale = 1.0;
    _fontFamily = '';
    notifyListeners();
  }

  void restorePersistedAppearance() {
    if (_scale == _persistedScale && _fontFamily == _persistedFontFamily) {
      return;
    }
    _scale = _persistedScale;
    _fontFamily = _persistedFontFamily;
    notifyListeners();
  }

  Future<void> persistAppearance() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('uiScale', _scale);
    await prefs.setString('uiFontFamily', _fontFamily);
    _persistedScale = _scale;
    _persistedFontFamily = _fontFamily;
  }

  Future<void> setHapticOnPress(bool value) async {
    if (value == _hapticOnPress) return;
    _hapticOnPress = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('uiHapticOnPress', value);
  }

  Future<void> setPrimary(Color color) => _setInt('uiPrimary', color, (v) => _primary = v);
  Future<void> setAccent(Color color) => _setInt('uiAccent', color, (v) => _accent = v);
  Future<void> setDanger(Color color) => _setInt('uiDanger', color, (v) => _danger = v);
  Future<void> setPaper(Color color) => _setInt('uiPaper', color, (v) => _paper = v);
  Future<void> setNameColor(Color color) =>
      _setInt('uiNameColor', color, (v) => _nameColor = v);
  Future<void> setAddressColor(Color color) =>
      _setInt('uiAddressColor', color, (v) => _addressColor = v);
  Future<void> setBodyColor(Color color) =>
      _setInt('uiBodyColor', color, (v) => _bodyColor = v);

  Future<void> applyThemePreset(AppColorPreset preset) async {
    _primary = preset.primary.toARGB32();
    _accent = preset.accent.toARGB32();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('uiPrimary', _primary);
    await prefs.setInt('uiAccent', _accent);
  }

  Future<void> reset() async {
    _scale = 1.0;
    _persistedScale = 1.0;
    _cardNameScale = 1.2;
    _fontFamily = '';
    _persistedFontFamily = '';
    _primary = defaultPrimary;
    _footer = 0;
    _accent = defaultAccent;
    _danger = defaultDanger;
    _paper = defaultPaper;
    _nameColor = defaultName;
    _addressColor = defaultAddress;
    _bodyColor = defaultBody;
    _hapticOnPress = true;
    _nightMode = false;
    _nightAuto = false;
    _nightLevel = 1;
    _nightFrom = 22 * 60;
    _nightTo = 7 * 60;
    _syncNightTicker();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('uiScale');
    await prefs.remove('uiCardNameScale');
    await prefs.remove('uiFontFamily');
    await prefs.remove('uiPrimary');
    await prefs.remove('uiFooter');
    await prefs.remove('uiAccent');
    await prefs.remove('uiDanger');
    await prefs.remove('uiPaper');
    await prefs.remove('uiNameColor');
    await prefs.remove('uiAddressColor');
    await prefs.remove('uiBodyColor');
    await prefs.remove('uiHapticOnPress');
    await prefs.remove('uiNightMode');
    await prefs.remove('uiNightAuto');
    await prefs.remove('uiNightLevel');
    await prefs.remove('uiNightFrom');
    await prefs.remove('uiNightTo');
  }

  Future<void> _setInt(
    String key,
    Color color,
    void Function(int value) assign,
  ) async {
    final next = color.toARGB32();
    assign(next);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(key, next);
  }

  static TextStyle previewStyle(
    String id, {
    double size = 16,
    TextTheme? base,
  }) {
    final theme = textThemeFor(id, base ?? ThemeData.light().textTheme);
    return (theme.bodyLarge ?? const TextStyle()).copyWith(
      fontSize: size,
      fontWeight: FontWeight.w600,
    );
  }

  static TextTheme textThemeFor(String id, TextTheme base) {
    try {
      switch (id) {
        case 'roboto':
          return GoogleFonts.robotoTextTheme(base);
        case 'openSans':
          return GoogleFonts.openSansTextTheme(base);
        case 'lato':
          return GoogleFonts.latoTextTheme(base);
        case 'nunito':
          return GoogleFonts.nunitoTextTheme(base);
        case 'rubik':
          return GoogleFonts.rubikTextTheme(base);
        case 'sourceSans':
          return GoogleFonts.sourceSans3TextTheme(base);
        case 'merriweather':
          return GoogleFonts.merriweatherTextTheme(base);
        case 'ptSerif':
          return GoogleFonts.ptSerifTextTheme(base);
        case 'playfair':
          return GoogleFonts.playfairDisplayTextTheme(base);
        case 'oswald':
          return GoogleFonts.oswaldTextTheme(base);
        case 'serif':
          return base.apply(fontFamily: 'serif');
        case 'monospace':
          return base.apply(fontFamily: 'monospace');
        default:
          return base;
      }
    } catch (_) {
      return base;
    }
  }
}

/// Перестраивает экран, когда меняются масштаб или цвета в настройках.
mixin UiSettingsAware<T extends StatefulWidget> on State<T> {
  @override
  void initState() {
    super.initState();
    AppUiSettings.instance.addListener(_onUiSettingsChanged);
  }

  @override
  void dispose() {
    AppUiSettings.instance.removeListener(_onUiSettingsChanged);
    super.dispose();
  }

  void _onUiSettingsChanged() {
    if (mounted) setState(() {});
  }
}
