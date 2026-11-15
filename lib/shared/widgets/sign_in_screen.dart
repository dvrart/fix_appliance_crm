import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/tester_build.dart';
import '../../services/auth_service.dart';
import 'app_onboarding_guide.dart';

/// Экран входа владельца / тестировщика (Firebase Auth, email + пароль).
/// Показывается один раз: после входа сессия хранится на устройстве
/// и работает офлайн.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  String _error = '';
  bool _busy = false;
  bool _obscure = true;
  bool _registerMode = false;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (_registerMode && name.isEmpty) {
      setState(() => _error = 'Введите ваше имя или название мастерской');
      return;
    }
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Введите email и пароль');
      return;
    }
    if (_registerMode && password.length < 6) {
      setState(() => _error = 'Пароль должен быть не короче 6 символов');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      if (_registerMode) {
        await AuthService.register(
          name: name,
          email: email,
          password: password,
          phone: phone,
        );
      } else {
        await AuthService.signIn(email, password);
      }
    } on FirebaseAuthException catch (e) {
      setState(() {
        _error = switch (e.code) {
          'invalid-credential' ||
          'wrong-password' ||
          'user-not-found' =>
            'Неверный email или пароль',
          'email-already-in-use' =>
            'Этот email уже зарегистрирован — переключитесь на «Вход»',
          'weak-password' => 'Пароль слишком простой (минимум 6 символов)',
          'invalid-email' => 'Проверьте формат email',
          'network-request-failed' => 'Нет связи. Проверьте интернет',
          'too-many-requests' => 'Слишком много попыток. Подождите немного',
          _ => 'Не удалось войти: ${e.code}',
        };
      });
    } catch (_) {
      setState(() => _error = 'Не удалось войти. Попробуйте ещё раз');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const navy = Color(0xFF1B2A4A);
    return Material(
      color: navy,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  kTesterAppBuild
                      ? Icons.handyman_outlined
                      : Icons.lock_outline,
                  color: Colors.amber,
                  size: 48,
                ),
                const SizedBox(height: 16),
                Text(
                  _registerMode
                      ? 'Новая база мастера'
                      : 'Вход в Fix Appliance CRM',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (kTesterAppBuild) ...[
                  const SizedBox(height: 6),
                  Text(
                    _registerMode
                        ? 'Создайте личный аккаунт — у вас будет своя отдельная база клиентов и заявок'
                        : 'Войдите в свою персональную базу заявок',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                    ),
                  ),
                ],
                const SizedBox(height: 22),
                if (_registerMode) ...[
                  TextField(
                    controller: _nameController,
                    textCapitalization: TextCapitalization.words,
                    style: const TextStyle(color: Colors.white),
                    decoration: _decoration('Имя или название мастерской'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    style: const TextStyle(color: Colors.white),
                    decoration: _decoration(
                      'Ваш мобильный (для звонков через Twilio)',
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  style: const TextStyle(color: Colors.white),
                  decoration: _decoration('Email'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  obscureText: _obscure,
                  style: const TextStyle(color: Colors.white),
                  onSubmitted: (_) => _submit(),
                  decoration: _decoration('Пароль').copyWith(
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure ? Icons.visibility : Icons.visibility_off,
                        color: Colors.white54,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                if (_error.isNotEmpty ||
                    AuthService.forcedSignOutNotice.value.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error.isNotEmpty
                        ? _error
                        : AuthService.forcedSignOutNotice.value,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF25D366),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Colors.white,
                            ),
                          )
                        : Text(_registerMode ? 'Создать свою базу' : 'Войти'),
                  ),
                ),
                if (kTesterAppBuild) ...[
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () {
                            setState(() {
                              _registerMode = !_registerMode;
                              _error = '';
                            });
                          },
                    child: Text(
                      _registerMode
                          ? 'Уже есть аккаунт? Войти'
                          : 'Нет аккаунта? Создать свою базу',
                      style: const TextStyle(color: Colors.amber),
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white38),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () => AppOnboardingGuide.open(context),
                    icon: const Icon(
                      Icons.menu_book_rounded,
                      color: Colors.amber,
                      size: 20,
                    ),
                    label: const Text('Гайд по приложению (обзор кнопок)'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _decoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white70),
      filled: true,
      fillColor: Colors.white10,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.white24),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.amber),
      ),
    );
  }
}
