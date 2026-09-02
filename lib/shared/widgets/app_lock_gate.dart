import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../services/app_lock_service.dart';
import '../../services/auth_service.dart';
import '../../services/error_log_service.dart';
import 'animated_app_logo.dart';
import 'sign_in_screen.dart';

/// Показывает клавиатуру PIN поверх приложения, пока замок закрыт.
class AppLockGate extends StatefulWidget {
  final Widget child;

  const AppLockGate({super.key, required this.child});

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      AppLockService.onPaused();
      // Ушли в фон сами — значит это был не вылет.
      unawaited(ErrorLogService.markCleanPause());
    } else if (state == AppLifecycleState.resumed) {
      AppLockService.onResumed();
      unawaited(ErrorLogService.markResumed());
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AppLockService.locked,
      builder: (context, locked, child) {
        return ListenableBuilder(
          listenable: AuthService.user,
          builder: (context, _) {
            final signedIn = AuthService.user.value != null;
            return Stack(
              children: [
                child!,
                if (!signedIn)
                  const Positioned.fill(
                    child: SignInScreen(),
                  )
                else if (locked)
                  const Positioned.fill(
                    child: PinLockScreen(),
                  ),
              ],
            );
          },
        );
      },
      child: widget.child,
    );
  }
}

/// Экран ввода PIN. Используется и как замок, и как «придумайте PIN».
class PinLockScreen extends StatefulWidget {
  /// null — разблокировка, иначе новый PIN возвращается через Navigator.pop.
  final bool setupMode;

  const PinLockScreen({super.key, this.setupMode = false});

  @override
  State<PinLockScreen> createState() => _PinLockScreenState();
}

class _PinLockScreenState extends State<PinLockScreen> {
  String _entered = '';
  String _firstEntry = '';
  String _error = '';
  bool _biometricAvailable = false;
  bool _biometricRunning = false;

  @override
  void initState() {
    super.initState();
    if (!widget.setupMode) _tryBiometric();
  }

  Future<void> _tryBiometric() async {
    if (!AppLockService.biometricEnabled) return;
    if (!await AppLockService.canUseBiometrics()) return;
    if (!mounted) return;
    setState(() => _biometricAvailable = true);
    await _runBiometric();
  }

  Future<void> _runBiometric() async {
    if (_biometricRunning) return;
    setState(() => _biometricRunning = true);
    final ok = await AppLockService.authenticateBiometric(
      context.tr('Разблокировать Fix Appliance', 'Unlock Fix Appliance'),
    );
    if (!mounted) return;
    setState(() => _biometricRunning = false);
    if (ok) {
      AppLockService.markUnlocked();
      return;
    }
    // Палец не подошёл или отменили — оставляем цифры и подсказку про кнопку.
    setState(() {
      _error = context.tr(
        'Приложите палец или введите PIN',
        'Use your finger or type the PIN',
      );
    });
  }

  Future<void> _push(int digit) async {
    if (_entered.length >= AppLockService.pinLength) return;
    HapticFeedback.selectionClick();
    setState(() {
      _entered += '$digit';
      _error = '';
    });
    if (_entered.length < AppLockService.pinLength) return;

    if (widget.setupMode) {
      if (_firstEntry.isEmpty) {
        setState(() {
          _firstEntry = _entered;
          _entered = '';
        });
        return;
      }
      if (_firstEntry != _entered) {
        setState(() {
          _error = context.tr('PIN не совпал. Ещё раз.', 'PIN did not match. Try again.');
          _firstEntry = '';
          _entered = '';
        });
        return;
      }
      final pin = _entered;
      if (!mounted) return;
      Navigator.pop(context, pin);
      return;
    }

    final ok = await AppLockService.verifyPin(_entered);
    if (!mounted) return;
    if (ok) {
      AppLockService.markUnlocked();
      return;
    }
    HapticFeedback.heavyImpact();
    setState(() {
      _error = context.tr('Неверный PIN', 'Wrong PIN');
      _entered = '';
    });
  }

  void _backspace() {
    if (_entered.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  String get _title {
    if (!widget.setupMode) {
      return _biometricAvailable
          ? context.tr('Палец или PIN', 'Finger or PIN')
          : context.tr('Введите PIN', 'Enter PIN');
    }
    return _firstEntry.isEmpty
        ? context.tr('Придумайте PIN', 'Choose a PIN')
        : context.tr('Повторите PIN', 'Repeat the PIN');
  }

  Widget _key(Widget child, VoidCallback? onTap) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Material(
        color: Colors.white.withValues(alpha: onTap == null ? 0 : 0.12),
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: SizedBox(height: 62, child: Center(child: child)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.primary,
      child: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (widget.setupMode)
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              )
            else
              const AnimatedAppLogo(size: 96),
            const SizedBox(height: 18),
            Text(
              _title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < AppLockService.pinLength; i++)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i < _entered.length
                          ? AppColors.accent
                          : Colors.white24,
                    ),
                  ),
              ],
            ),
            SizedBox(
              height: 30,
              child: _error.isEmpty
                  ? null
                  : Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _error,
                        style: const TextStyle(color: Color(0xFFFF8A80)),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 44),
              child: GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 3,
                childAspectRatio: 1.5,
                children: [
                  for (var digit = 1; digit <= 9; digit++)
                    _key(
                      Text(
                        '$digit',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      () => _push(digit),
                    ),
                  _biometricAvailable && !widget.setupMode
                      ? _key(
                          _biometricRunning
                              ? SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.4,
                                    color: AppColors.accent,
                                  ),
                                )
                              : Icon(
                                  Icons.fingerprint,
                                  color: AppColors.accent,
                                  size: 32,
                                ),
                          _biometricRunning ? null : _runBiometric,
                        )
                      : _key(const SizedBox.shrink(), null),
                  _key(
                    const Text(
                      '0',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    () => _push(0),
                  ),
                  _key(
                    const Icon(
                      Icons.backspace_outlined,
                      color: Colors.white,
                      size: 24,
                    ),
                    _backspace,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
