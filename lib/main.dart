import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'core/app_commands.dart';
import 'firebase_options.dart';
import 'screens/login_screen.dart';

void main() async {
  // Обязательная строка перед запуском Firebase
  WidgetsFlutterBinding.ensureInitialized();

  // Инициализация базы данных
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  runApp(const FixApplianceCRM());
}

class FixApplianceCRM extends StatelessWidget {
  const FixApplianceCRM({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: 'FIX-Appliance CRM',
      debugShowCheckedModeBanner: false,

      // Настройка Светлой темы (по умолчанию)
      theme: ThemeData(
        brightness: Brightness.light,
        primaryColor: const Color(0xFF14557F), // Основной синий
        scaffoldBackgroundColor: const Color(0xFFF5F7FA), // Светло-серый фон
        // ДЕЛАЕМ ОТСТУПЫ КОМПАКТНЕЕ
        visualDensity: VisualDensity.compact,

        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF14557F),
          foregroundColor: Color(
            0xFFFCC520,
          ), // Желтый акцент для текста и иконок
          elevation: 0,
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: Color(0xFFFCC520), // Желтые кнопки
          foregroundColor: Colors.black, // Черная иконка на желтом
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          selectedItemColor: Color(0xFFFCC520),
          unselectedItemColor: Colors.grey,
          backgroundColor: Colors.white,
        ),
      ),

      // --- ВОТ ТОТ САМЫЙ BUILDER, КОТОРЫЙ МЕНЯЕТ МАСШТАБ ТЕКСТА ---
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(0.9), // Уменьшаем на 10%
          ),
          child: child!,
        );
      },

      // -------------------------------------------------------------
      home: const LoginScreen(),
    ); // Это закрывает MaterialApp
  } // Это закрывает Widget build
} // Это закрывает класс FixApplianceCRM
