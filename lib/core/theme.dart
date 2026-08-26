import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'constants.dart';
import 'ui_scale.dart';

class AppTheme {
  static ThemeData light({
    String fontId = '',
    Color? primary,
    Color? accent,
    double scale = 1.0,
  }) {
    final brand = primary ?? AppColors.primary;
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
          TargetPlatform.android: _SmoothPageTransitionsBuilder(),
          TargetPlatform.iOS: _SmoothPageTransitionsBuilder(),
          TargetPlatform.windows: _SmoothPageTransitionsBuilder(),
          TargetPlatform.linux: _SmoothPageTransitionsBuilder(),
          TargetPlatform.macOS: _SmoothPageTransitionsBuilder(),
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
          systemNavigationBarColor: brand,
          systemNavigationBarIconBrightness: Brightness.light,
          systemNavigationBarDividerColor: brand,
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
        backgroundColor: brand,
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
    );
    final themed = AppUiSettings.textThemeFor(fontId, base.textTheme);
    return base.copyWith(
      textTheme: themed,
      primaryTextTheme: AppUiSettings.textThemeFor(fontId, base.primaryTextTheme),
    );
  }
}

class _SmoothPageTransitionsBuilder extends PageTransitionsBuilder {
  const _SmoothPageTransitionsBuilder();

  @override
  Duration get transitionDuration => const Duration(milliseconds: 380);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 320);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final incoming = CurvedAnimation(
      parent: animation,
      curve: const Cubic(0.16, 1, 0.3, 1),
      reverseCurve: Curves.easeInOutCubic,
    );
    final outgoing = CurvedAnimation(
      parent: secondaryAnimation,
      curve: Curves.easeInOutCubic,
    );
    return FadeTransition(
      opacity: incoming,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0.055, 0),
          end: Offset.zero,
        ).animate(incoming),
        child: FadeTransition(
          opacity: Tween<double>(begin: 1, end: 0.86).animate(outgoing),
          child: SlideTransition(
            position: Tween<Offset>(
              begin: Offset.zero,
              end: const Offset(-0.04, 0),
            ).animate(outgoing),
            child: child,
          ),
        ),
      ),
    );
  }
}
