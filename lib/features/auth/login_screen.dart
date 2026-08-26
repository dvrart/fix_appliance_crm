import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../services/account_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _register = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_register) {
        await AccountService.instance.register(
          email: _email.text,
          password: _password.text,
        );
      } else {
        await AccountService.instance.signIn(
          email: _email.text,
          password: _password.text,
        );
      }
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() => _error = _authMessage(e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _authMessage(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-email':
        return context.tr('Некорректный email', 'Invalid email');
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return context.tr('Неверный email или пароль', 'Wrong email or password');
      case 'email-already-in-use':
        return context.tr('Этот email уже занят', 'This email is already in use');
      case 'weak-password':
        return context.tr('Пароль слишком короткий', 'Password is too short');
      case 'operation-not-allowed':
        return context.tr(
          'Этот вход ещё не включён в Firebase (Google или Apple).',
          'This sign-in method is not enabled in Firebase yet (Google or Apple).',
        );
      case 'account-exists-with-different-credential':
        return context.tr(
          'Этот email уже зарегистрирован другим способом. Войдите так, как создавали аккаунт.',
          'This email already uses another sign-in method.',
        );
      default:
        return e.message ?? e.code;
    }
  }

  Future<void> _google() => AccountService.instance.signInWithGoogle();

  Future<void> _apple() => AccountService.instance.signInWithApple();

  Future<void> _social(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      if (_isCanceled(e)) return;
      setState(() => _error = _authMessage(e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _isCanceled(FirebaseAuthException e) {
    final code = e.code.toLowerCase();
    return code.contains('cancel') || code == 'web-context-cancelled';
  }

  Widget _socialButton({
    required String label,
    required Color background,
    required Color foreground,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return FilledButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 26),
      label: Text(
        label,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
      style: FilledButton.styleFrom(
        backgroundColor: background,
        foregroundColor: foreground,
        minimumSize: const Size.fromHeight(50),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final yellow = AppColors.accent;
    return Scaffold(
      backgroundColor: AppColors.primary,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(28, 48, 28, 24),
          children: [
            Text(
              'Fix Cloud',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: yellow,
                fontSize: 32,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              context.tr(
                'CRM для своей компании по ремонту техники',
                'CRM for your appliance-repair company',
              ),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
            const SizedBox(height: 40),
            _field(
              controller: _email,
              label: 'Email',
              keyboard: TextInputType.emailAddress,
            ),
            const SizedBox(height: 12),
            _field(
              controller: _password,
              label: context.tr('Пароль', 'Password'),
              obscure: true,
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFFFCDD2)),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _submit,
              style: FilledButton.styleFrom(
                backgroundColor: yellow,
                foregroundColor: const Color(0xFF1A1A1A),
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: _busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      _register
                          ? context.tr('Создать аккаунт', 'Create account')
                          : context.tr('Войти', 'Sign in'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                const Expanded(child: Divider(color: Colors.white24)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    context.tr('или', 'or'),
                    style: const TextStyle(color: Colors.white54),
                  ),
                ),
                const Expanded(child: Divider(color: Colors.white24)),
              ],
            ),
            const SizedBox(height: 16),
            _socialButton(
              label: context.tr('Продолжить с Google', 'Continue with Google'),
              background: Colors.white,
              foreground: const Color(0xFF1A1A1A),
              icon: Icons.g_mobiledata,
              onPressed: _busy ? null : () => _social(_google),
            ),
            const SizedBox(height: 10),
            _socialButton(
              label: context.tr('Продолжить с Apple', 'Continue with Apple'),
              background: Colors.black,
              foreground: Colors.white,
              icon: Icons.apple,
              onPressed: _busy ? null : () => _social(_apple),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _register = !_register;
                        _error = null;
                      }),
              child: Text(
                _register
                    ? context.tr('У меня уже есть аккаунт', 'I already have an account')
                    : context.tr('Новая компания — регистрация', 'New company — register'),
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    bool obscure = false,
    TextInputType? keyboard,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboard,
      style: const TextStyle(color: Colors.white),
      cursorColor: AppColors.accent,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.08),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Colors.white24),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: AppColors.accent, width: 1.4),
        ),
      ),
    );
  }
}
