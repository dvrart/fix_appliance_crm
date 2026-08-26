import 'dart:async';

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
import 'services/notification_service.dart';
import 'shared/widgets/animated_app_logo.dart';

/// Обработчик фоновых push-уведомлений FCM. Должен быть top-level функцией
/// (не методом класса), Twilio Voice сам обрабатывает свои push-уведомления
/// о звонках через собственный сервис на Android — этот обработчик нужен
/// как точка входа для остальных фоновых уведомлений.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]);
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  unawaited(NotificationService.initialize());
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
      await AppLocale.instance.load();
      await AppUiSettings.instance.load();
      await NotificationLook.instance.load();
      await initializeDateFormatting('ru', null);
      await initializeDateFormatting('en', null);
      if (!mounted) return;
      setState(() => _readyApp = const FixApplianceCrmApp());
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
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
                    _error!.contains('not linked to Firebase') ||
                            _error!.contains('not configured')
                        ? 'Fix Cloud ещё не привязан к своему Firebase.\n'
                            'Создайте НОВЫЙ проект (не fix-appliance-crm) и выполните flutterfire configure.'
                        : _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
        ),
      ),
    );
  }
}
