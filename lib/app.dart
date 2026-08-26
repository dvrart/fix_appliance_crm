import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'core/app_commands.dart';
import 'core/haptic_scope.dart';
import 'core/l10n/app_locale.dart';
import 'core/ui_scale.dart';
import 'core/theme.dart';
import 'features/auth/auth_gate.dart';
import 'features/main/main_screen.dart';
import 'features/calls/global_call_listener.dart';
import 'features/messages/global_sms_listener.dart';
import 'features/ai/assistant/assistant_host.dart';
import 'features/ai/assistant/assistant_screen_sight.dart';
import 'features/field/field_assistant_host.dart';

class FixApplianceCrmApp extends StatelessWidget {
  const FixApplianceCrmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        AppLocale.instance,
        AppUiSettings.instance,
      ]),
      builder: (context, _) {
        final ui = AppUiSettings.instance;
        return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: 'Fix Cloud',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(
        fontId: ui.fontFamily,
        primary: ui.primaryColor,
        accent: ui.accentColor,
        scale: ui.scale,
      ),
      scrollBehavior: const _AppScrollBehavior(),
      locale: AppLocale.instance.locale,
      supportedLocales: const [
        Locale('ru', 'RU'),
        Locale('en', 'US'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.light,
            systemNavigationBarColor: ui.primaryColor,
            systemNavigationBarIconBrightness: Brightness.light,
            systemNavigationBarDividerColor: ui.primaryColor,
          ),
          child: MediaQuery(
            data: media.copyWith(
              alwaysUse24HourFormat: true,
              textScaler: TextScaler.linear(ui.scale),
            ),
            child: AppHapticScope(
              child: RepaintBoundary(
                key: AssistantScreenSight.boundaryKey,
                child: child!,
              ),
            ),
          ),
        );
      },
      home: AuthGate(
        child: GlobalCallListener(
          navigatorKey: rootNavigatorKey,
          child: GlobalSmsListener(
            navigatorKey: rootNavigatorKey,
            child: const FieldAssistantHost(
              child: AssistantHost(
                child: MainScreen(),
              ),
            ),
          ),
        ),
      ),
        );
      },
    );
  }
}

class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
  }
}
