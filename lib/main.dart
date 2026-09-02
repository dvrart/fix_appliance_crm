import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'core/constants.dart';
import 'core/l10n/app_locale.dart';
import 'core/notification_look.dart';
import 'core/ui_scale.dart';
import 'firebase_options.dart';
import 'app.dart';
import 'services/app_lock_service.dart';
import 'services/auth_service.dart';
import 'services/notification_service.dart';
import 'services/settings_service.dart';
import 'services/app_time_service.dart';
import 'services/backup_service.dart';
import 'services/error_log_service.dart';
import 'services/network_status_service.dart';
import 'shared/widgets/animated_app_logo.dart';

/// Обработчик фоновых push-уведомлений FCM. Должен быть top-level функцией
/// (не методом класса), Twilio Voice сам обрабатывает свои push-уведомления
/// о звонках через собственный сервис на Android — этот обработчик нужен
/// как точка входа для остальных фоновых уведомлений.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    // На Android шторку рисует VoiceFirebaseMessagingService (три картинки).
    // Если ещё и Dart покажет обычный текст, он затрёт кастомный вид.
    if (Platform.isAndroid) return;
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    await NotificationService.showRemoteMessage(message);
  } catch (e) {
    // Не роняем фон: шторку ещё рисует нативный FCM-сервис.
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]);
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Без интернета работаем по локальной копии базы. Лимит снят: в подвале дома
  // должны открываться все заявки, а не только те, что смотрели последними.
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
  );
  AuthService.init();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  unawaited(NotificationService.initialize());
  NetworkStatusService.start();
  ErrorLogService.install();
  unawaited(ErrorLogService.onAppStart());
  runApp(const AppBootstrap());
}

class AppBootstrap extends StatefulWidget {
  const AppBootstrap({super.key});

  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap> {
  Widget? _readyApp;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await FirebaseMessaging.instance.requestPermission(alert: true, badge: true, sound: true);
      // Только локальное — работает и в самолёте.
      await AppLocale.instance.load();
      await AppUiSettings.instance.load();
      await AppLockService.load();
      await NotificationLook.instance.load();
      await initializeDateFormatting('ru', null);
      await initializeDateFormatting('en', null);
      // Всё, что стучится в сеть. Без интернета не держим заставку: эти
      // настройки подтянутся сами, когда связь появится.
      await _online(() async {
        await SettingsService.ensureAiVoiceSettings();
        await SettingsService.ensureServiceAreaLabel();
        await SettingsService.ensureEnglishClientCopy();
        await AppTimeService.ensureInitialized();
      });
      unawaited(BackupService.runIfDue());
      if (!mounted) return;
      setState(() => _readyApp = const FixApplianceCrmApp());
    } catch (e, stack) {
      ErrorLogService.record(e, stack, kind: 'старт');
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _online(Future<void> Function() work) async {
    try {
      await work().timeout(const Duration(seconds: 6));
    } catch (error) {
      debugPrint('Старт без сети: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_readyApp != null) return _readyApp!;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: AppColors.primary,
        body: Center(
          child: _error == null
              ? const AnimatedAppLogo(size: 196)
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
        ),
      ),
    );
  }
}
