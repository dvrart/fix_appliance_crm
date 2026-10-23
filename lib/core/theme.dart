import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'constants.dart';
import 'motion.dart';
import 'ui_scale.dart';

class AppTheme {
  static ThemeData light({
    String fontId = '',
    Color? primary,
    Color? footer,
    Color? accent,
    double scale = 1.0,
  }) {
    final brand = primary ?? AppColors.primary;
    final bottomBar = footer ?? AppColors.footer;
    final highlight = accent ?? AppColors.accent;
    final s = scale.clamp(0.85, 1.4);
    final scheme = ColorScheme.fromSeed(
      seedColor: brand,
      primary: brand,
      secondary: highlight,
    ).copyWith(
      onSurface: const Color(0xFF1A1A1A),
      onSurfaceVariant: const Color(0xFF3D3D3D),
      outline: const Color(0xFF6B6B6B),
    );
    final base = ThemeData(
      primaryColor: brand,
      colorScheme: scheme,
      useMaterial3: true,
      visualDensity: VisualDensity(
        horizontal: (s - 1) * 2,
        vertical: (s - 1) * 2,
      ),
      splashFactory: InkRipple.splashFactory,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: SoftPageTransitionsBuilder(),
          TargetPlatform.iOS: SoftPageTransitionsBuilder(),
          TargetPlatform.windows: SoftPageTransitionsBuilder(),
          TargetPlatform.linux: SoftPageTransitionsBuilder(),
          TargetPlatform.macOS: SoftPageTransitionsBuilder(),
        },
      ),
      scaffoldBackgroundColor: Colors.grey.shade100,
      iconTheme: IconThemeData(size: 24 * s, color: brand),
      appBarTheme: AppBarTheme(
        backgroundColor: brand,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 44,
        titleSpacing: 8,
        centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          systemNavigationBarColor: bottomBar,
          systemNavigationBarIconBrightness: Brightness.light,
          systemNavigationBarDividerColor: bottomBar,
        ),
        titleTextStyle: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 20 * s,
          color: Colors.white,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: highlight,
        foregroundColor: Colors.black,
      ),
      cardTheme: CardThemeData(
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.grey.shade50,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: highlight, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: highlight,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: brand,
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: bottomBar,
        selectedItemColor: Colors.white,
        unselectedItemColor: Colors.white70,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
        selectedIconTheme: IconThemeData(size: 24 * s, color: Colors.white),
        unselectedIconTheme: IconThemeData(size: 22 * s, color: Colors.white70),
        selectedLabelStyle: TextStyle(fontWeight: FontWeight.w700, fontSize: 12 * s),
        unselectedLabelStyle: TextStyle(fontWeight: FontWeight.w500, fontSize: 12 * s),
      ),
      chipTheme: ChipThemeData(
        selectedColor: highlight,
        checkmarkColor: Colors.black,
        backgroundColor: const Color(0xFFE8EEF3),
        disabledColor: const Color(0xFFD6D6D6),
        labelStyle: const TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 14,
          color: Color(0xFF1A1A1A),
        ),
        secondaryLabelStyle: const TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 14,
          color: Color(0xFF1A1A1A),
        ),
        side: BorderSide(color: brand, width: 1.2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: Colors.grey.shade300,
        thickness: 1,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: highlight,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        dismissDirection: DismissDirection.horizontal,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: brand,
        thumbColor: brand,
      ),
      // Выделение текста — красное, вместе с ползунками. Синяя подсветка по
      // умолчанию терялась на синих пузырях переписки. Material раздаёт это
      // через `DefaultSelectionStyle`, поэтому красным становится выделение
      // и в полях ввода, и в обычном тексте (`SelectionArea`, `LinkedText`).
      textSelectionTheme: const TextSelectionThemeData(
        selectionColor: Color(0x66E53935),
        selectionHandleColor: Color(0xFFE53935),
      ),
    );
    final themed = AppUiSettings.textThemeFor(fontId, base.textTheme);
    return base.copyWith(
      textTheme: themed,
      primaryTextTheme: AppUiSettings.textThemeFor(fontId, base.primaryTextTheme),
    );
  }

  /// Ночной режим. Цвета мастера (шапка и акцент) остаются его, тёмным
  /// становится всё, что красит Material: фон экранов, листы, диалоги,
  /// поля ввода и текст.
  ///
  /// Экраны, где фон карточки прописан руками (`Colors.white`), остаются
  /// светлыми — их надо переводить по одному, и только после проверки на
  /// телефоне. Половинчатая тема лучше сломанной: белая карточка читается,
  /// белый текст на белом — нет.
  static ThemeData dark({
    String fontId = '',
    Color? primary,
    Color? footer,
    Color? accent,
    double scale = 1.0,
    NightShadePreset? shade,
  }) {
    final brand = primary ?? AppColors.primary;
    final bottomBar = footer ?? AppColors.footer;
    final highlight = accent ?? AppColors.accent;
    final onCardBrand = Color.lerp(brand, Colors.white, 0.48)!;
    final s = scale.clamp(0.85, 1.4);
    final preset = shade ?? AppUiSettings.instance.nightShade;
    final surface = preset.surface;
    final card = preset.card;
    final border = preset.border;
    final ink = preset.ink;
    final inkMuted = preset.inkMuted;
    final scheme = ColorScheme.fromSeed(
      seedColor: brand,
      brightness: Brightness.dark,
      primary: onCardBrand,
      onPrimary: Colors.black,
      secondary: highlight,
      onSecondary: Colors.black,
    ).copyWith(
      surface: surface,
      onSurface: ink,
      onSurfaceVariant: inkMuted,
      outline: border,
      surfaceTint: Colors.transparent,
    );
    final base = ThemeData(
      brightness: Brightness.dark,
      primaryColor: brand,
      colorScheme: scheme,
      useMaterial3: true,
      visualDensity: VisualDensity(
        horizontal: (s - 1) * 2,
        vertical: (s - 1) * 2,
      ),
      splashFactory: InkRipple.splashFactory,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: SoftPageTransitionsBuilder(),
          TargetPlatform.iOS: SoftPageTransitionsBuilder(),
          TargetPlatform.windows: SoftPageTransitionsBuilder(),
          TargetPlatform.linux: SoftPageTransitionsBuilder(),
          TargetPlatform.macOS: SoftPageTransitionsBuilder(),
        },
      ),
      scaffoldBackgroundColor: surface,
      canvasColor: surface,
      cardColor: card,
      dividerColor: border,
      dialogTheme: DialogThemeData(
        backgroundColor: card,
        surfaceTintColor: Colors.transparent,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: card,
        modalBackgroundColor: card,
        surfaceTintColor: Colors.transparent,
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: card,
        surfaceTintColor: Colors.transparent,
      ),
      listTileTheme: ListTileThemeData(
        textColor: ink,
        iconColor: ink,
      ),
      iconTheme: IconThemeData(size: 24 * s, color: ink),
      appBarTheme: AppBarTheme(
        backgroundColor: brand,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 44,
        titleSpacing: 8,
        centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          systemNavigationBarColor: bottomBar,
          systemNavigationBarIconBrightness: Brightness.light,
          systemNavigationBarDividerColor: bottomBar,
        ),
        titleTextStyle: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 20 * s,
          color: Colors.white,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: highlight,
        foregroundColor: Colors.black,
      ),
      cardTheme: CardThemeData(
        color: card,
        surfaceTintColor: Colors.transparent,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: card,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: highlight, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: highlight,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          side: BorderSide(color: border),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: highlight),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.black;
          return ink;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return highlight;
          return preset.cardMuted;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.transparent;
          return border;
        }),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return highlight;
          return Colors.transparent;
        }),
        checkColor: const WidgetStatePropertyAll(Colors.black),
        side: BorderSide(color: inkMuted, width: 1.8),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return highlight;
          return inkMuted;
        }),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: bottomBar,
        selectedItemColor: Colors.white,
        unselectedItemColor: Colors.white70,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
        selectedIconTheme: IconThemeData(size: 24 * s, color: Colors.white),
        unselectedIconTheme: IconThemeData(size: 22 * s, color: Colors.white70),
        selectedLabelStyle: TextStyle(fontWeight: FontWeight.w700, fontSize: 12 * s),
        unselectedLabelStyle: TextStyle(fontWeight: FontWeight.w500, fontSize: 12 * s),
      ),
      chipTheme: ChipThemeData(
        selectedColor: highlight,
        checkmarkColor: Colors.black,
        backgroundColor: card,
        disabledColor: preset.cardMuted,
        labelStyle: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 14,
          color: ink,
        ),
        secondaryLabelStyle: const TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 14,
          color: Color(0xFF1A1A1A),
        ),
        side: BorderSide(color: border, width: 1.2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: border,
        thickness: 1,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: highlight),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        dismissDirection: DismissDirection.horizontal,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: highlight,
        thumbColor: highlight,
      ),
      textSelectionTheme: const TextSelectionThemeData(
        selectionColor: Color(0x66E53935),
        selectionHandleColor: Color(0xFFE53935),
      ),
    );
    return base.copyWith(
      textTheme: AppUiSettings.textThemeFor(fontId, base.textTheme),
      primaryTextTheme:
          AppUiSettings.textThemeFor(fontId, base.primaryTextTheme),
    );
  }
}
