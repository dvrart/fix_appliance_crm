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
  double _cardNameScale = 1.2;
  String _fontFamily = '';
  int _primary = defaultPrimary;
  int _accent = defaultAccent;
  int _danger = defaultDanger;
  int _paper = defaultPaper;
  int _nameColor = defaultName;
  int _addressColor = defaultAddress;
  int _bodyColor = defaultBody;
  bool _hapticOnPress = true;

  double get scale => _scale;
  double get cardNameScale => _cardNameScale;
  String get fontFamily => _fontFamily;
  String? get themeFontFamily => _fontFamily.isEmpty ? null : _fontFamily;
  Color get primaryColor => Color(_primary);
  Color get accentColor => Color(_accent);
  Color get dangerColor => Color(_danger);
  Color get surfaceColor => const Color(defaultSurface);
  Color get drawerHeaderColor => const Color(defaultDrawer);
  Color get paperColor => Color(_paper);
  Color get nameColor => Color(_nameColor);
  Color get addressColor => Color(_addressColor);
  Color get bodyColor => Color(_bodyColor);
  bool get hapticOnPress => _hapticOnPress;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _scale = (prefs.getDouble('uiScale') ?? 1.0).clamp(minScale, maxScale);
    _cardNameScale =
        (prefs.getDouble('uiCardNameScale') ?? 1.2).clamp(1.0, 1.6);
    _fontFamily = prefs.getString('uiFontFamily') ?? '';
    _primary = prefs.getInt('uiPrimary') ?? defaultPrimary;
    _accent = prefs.getInt('uiAccent') ?? defaultAccent;
    _danger = prefs.getInt('uiDanger') ?? defaultDanger;
    _paper = prefs.getInt('uiPaper') ?? defaultPaper;
    _nameColor = prefs.getInt('uiNameColor') ?? defaultName;
    _addressColor = prefs.getInt('uiAddressColor') ?? defaultAddress;
    _bodyColor = prefs.getInt('uiBodyColor') ?? defaultBody;
    _hapticOnPress = prefs.getBool('uiHapticOnPress') ?? true;
  }

  Future<void> setScale(double value) async {
    final next = value.clamp(minScale, maxScale);
    if (next == _scale) return;
    _scale = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('uiScale', _scale);
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
    _cardNameScale = 1.2;
    _fontFamily = '';
    _primary = defaultPrimary;
    _accent = defaultAccent;
    _danger = defaultDanger;
    _paper = defaultPaper;
    _nameColor = defaultName;
    _addressColor = defaultAddress;
    _bodyColor = defaultBody;
    _hapticOnPress = true;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('uiScale');
    await prefs.remove('uiCardNameScale');
    await prefs.remove('uiFontFamily');
    await prefs.remove('uiPrimary');
    await prefs.remove('uiAccent');
    await prefs.remove('uiDanger');
    await prefs.remove('uiPaper');
    await prefs.remove('uiNameColor');
    await prefs.remove('uiAddressColor');
    await prefs.remove('uiBodyColor');
    await prefs.remove('uiHapticOnPress');
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
