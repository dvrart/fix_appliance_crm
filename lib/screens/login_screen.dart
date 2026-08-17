// Файл: lib/screens/login_screen.dart
import 'package:flutter/material.dart';
import 'main_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  String _pin = '';
  final String _correctPin = '1234'; // ТВОЙ PIN-КОД (можешь поменять на любой)

  void _onKeyPress(String key) {
    setState(() {
      if (key == 'back') {
        if (_pin.isNotEmpty) {
          _pin = _pin.substring(0, _pin.length - 1);
        }
      } else {
        if (_pin.length < 4) {
          _pin += key;
        }
      }
    });

    // Проверяем PIN, когда введено 4 цифры
    if (_pin.length == 4) {
      Future.delayed(const Duration(milliseconds: 200), () {
        if (_pin == _correctPin) {
          // Если PIN верный -> Переходим на главный экран и удаляем экран логина из истории
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const MainScreen()),
          );
        } else {
          // Если PIN неверный -> Очищаем и показываем ошибку
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'Неверный PIN-код',
                textAlign: TextAlign.center,
              ),
              backgroundColor: Colors.red.shade400,
              behavior: SnackBarBehavior.floating,
            ),
          );
          setState(() {
            _pin = '';
          });
        }
      });
    }
  }

  Widget _buildPinDot(int index) {
    bool isFilled = index < _pin.length;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isFilled ? const Color(0xFFFCC520) : Colors.transparent,
        border: Border.all(
          color: isFilled ? const Color(0xFFFCC520) : Colors.white54,
          width: 2,
        ),
      ),
    );
  }

  Widget _buildKeypadButton(String key) {
    if (key == 'empty') return const SizedBox(width: 80, height: 80);

    return GestureDetector(
      onTap: () => _onKeyPress(key),
      child: Container(
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withOpacity(0.1),
        ),
        child: Center(
          child: key == 'back'
              ? const Icon(
                  Icons.backspace_outlined,
                  color: Colors.white,
                  size: 28,
                )
              : Text(
                  key,
                  style: const TextStyle(
                    fontSize: 32,
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF14557F), // Фирменный синий фон
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Spacer(),
            // Логотип или иконка
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.1),
              ),
              child: const Icon(
                Icons.lock_outline,
                size: 60,
                color: Color(0xFFFCC520),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'FIX APPLIANCE',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Введите PIN-код',
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
            const SizedBox(height: 40),

            // Индикаторы введенных цифр (4 точки)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(4, (index) => _buildPinDot(index)),
            ),

            const Spacer(),

            // Цифровая клавиатура
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      '1',
                      '2',
                      '3',
                    ].map((e) => _buildKeypadButton(e)).toList(),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      '4',
                      '5',
                      '6',
                    ].map((e) => _buildKeypadButton(e)).toList(),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      '7',
                      '8',
                      '9',
                    ].map((e) => _buildKeypadButton(e)).toList(),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      'empty',
                      '0',
                      'back',
                    ].map((e) => _buildKeypadButton(e)).toList(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}
