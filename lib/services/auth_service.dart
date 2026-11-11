import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api_keys.dart';
import '../models/technician.dart';

/// Firebase Auth: автоматический вход владельца и ID-токен для защищённых
/// HTTP-функций и правил Firestore/Storage.
///
/// Учётные данные владельца вшиты в локальный `api_keys.dart` (и дублируются
/// в SharedPreferences). Вход выполняется полностью автоматически без показа
/// экрана с полями email и пароля.
class AuthService {
  AuthService._();

  static User? _safeCurrentUser() {
    try {
      return FirebaseAuth.instance.currentUser;
    } catch (_) {
      return null;
    }
  }

  static final ValueNotifier<User?> user =
      ValueNotifier<User?>(_safeCurrentUser());

  static String _cachedIdToken = '';
  static DateTime _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static StreamSubscription<User?>? _sub;
  static Timer? _retryTimer;

  static const _kEmail = 'auth_saved_email';
  static const _kPassword = 'auth_saved_password';

  /// Вшиты ли учётные данные владельца прямо в сборку.
  /// В сборке для мастеров (`TECH_APP=true`) встроенный вход владельца отключён.
  static bool get hasBuiltInCredentials =>
      !kTechnicianAppBuild &&
      kOwnerEmail.trim().isNotEmpty &&
      kOwnerPassword.isNotEmpty;

  /// Причина принудительного выхода (например, «Доступ отключён владельцем»).
  static final ValueNotifier<String> forcedSignOutNotice =
      ValueNotifier<String>('');

  /// true пока идёт тихое восстановление сессии — AppLockGate
  /// показывает заставку вместо экрана входа.
  static final ValueNotifier<bool> autoSigningIn =
      ValueNotifier<bool>(false);
  static Completer<bool>? _signInCompleter;

  // ------------------------------------------------ инициализация

  static void init() {
    user.value = FirebaseAuth.instance.currentUser;
    _sub ??= FirebaseAuth.instance.idTokenChanges().listen((u) {
      user.value = u;
      if (u == null) {
        _cachedIdToken = '';
        unawaited(_runAutoSignIn());
      } else {
        _retryTimer?.cancel();
        _retryTimer = null;
        unawaited(_refreshToken(u));
      }
    });
    if (user.value == null) {
      unawaited(_runAutoSignIn());
    } else {
      unawaited(_refreshToken(user.value!));
    }
  }

  static bool get signedIn => FirebaseAuth.instance.currentUser != null;

  /// Дожидается автоматического входа (если он ещё идёт или не выполнен).
  static Future<bool> ensureSignedIn({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    if (signedIn) return true;
    try {
      return await _runAutoSignIn().timeout(timeout, onTimeout: () => signedIn);
    } catch (_) {
      return signedIn;
    }
  }

  // ------------------------------------------------ ручной вход

  static Future<void> signIn(String email, String password) async {
    forcedSignOutNotice.value = '';
    await FirebaseAuth.instance.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    final u = FirebaseAuth.instance.currentUser;
    user.value = u;
    if (u != null) await _refreshToken(u);
    unawaited(_saveCredentials(email.trim(), password));
  }

  static Future<void> signOut({String reason = ''}) async {
    _retryTimer?.cancel();
    _retryTimer = null;
    _cachedIdToken = '';
    if (reason.trim().isNotEmpty) {
      forcedSignOutNotice.value = reason.trim();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kEmail);
      await prefs.remove(_kPassword);
    } catch (_) {}
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {}
    user.value = null;
    autoSigningIn.value = false;
  }

  // ------------------------------------------------ авто-вход

  static Future<void> _saveCredentials(
      String email, String password) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kEmail, email);
      await prefs.setString(_kPassword, password);
    } catch (e) {
      debugPrint('AuthService: сохранение учётных данных не удалось: $e');
    }
  }

  /// Читает встроенные или сохранённые учётные данные и выполняет вход.
  static Future<bool> tryAutoSignIn() async {
    if (signedIn) return true;
    try {
      String email = kTechnicianAppBuild ? '' : kOwnerEmail.trim();
      String password = kTechnicianAppBuild ? '' : kOwnerPassword;
      if (email.isEmpty || password.isEmpty) {
        final prefs = await SharedPreferences.getInstance();
        email = (prefs.getString(_kEmail) ?? '').trim();
        password = prefs.getString(_kPassword) ?? '';
      }
      if (email.isEmpty || password.isEmpty) {
        return false;
      }
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      final u = FirebaseAuth.instance.currentUser;
      user.value = u;
      if (u != null) await _refreshToken(u);
      return u != null;
    } catch (e) {
      debugPrint('AuthService: авто-вход не удался: $e');
      return false;
    }
  }

  static Future<bool> _runAutoSignIn() async {
    if (signedIn) return true;
    final existing = _signInCompleter;
    if (existing != null) return existing.future;

    final completer = Completer<bool>();
    _signInCompleter = completer;
    autoSigningIn.value = true;
    try {
      final ok = await tryAutoSignIn();
      if (!ok && !signedIn && hasBuiltInCredentials) {
        _scheduleRetry();
      }
      completer.complete(ok || signedIn);
      return ok || signedIn;
    } finally {
      _signInCompleter = null;
      if (signedIn || !hasBuiltInCredentials) {
        autoSigningIn.value = false;
      }
    }
  }

  static void _scheduleRetry() {
    if (_retryTimer?.isActive ?? false) return;
    _retryTimer = Timer(const Duration(seconds: 3), () {
      _retryTimer = null;
      if (!signedIn) unawaited(_runAutoSignIn());
    });
  }

  // ------------------------------------------------ токен

  static Future<void> _refreshToken(User u, {bool force = false}) async {
    try {
      final token = await u.getIdToken(force);
      if (token != null && token.isNotEmpty) {
        _cachedIdToken = token;
        _cachedAt = DateTime.now();
      }
    } catch (e) {
      debugPrint('AuthService: не удалось обновить токен: $e');
    }
  }

  /// Свежий ID-токен (обновляет, если старше 30 минут). Пустая строка офлайн.
  static Future<String> idToken() async {
    var u = FirebaseAuth.instance.currentUser;
    if (u == null) {
      await ensureSignedIn();
      u = FirebaseAuth.instance.currentUser;
    }
    if (u == null) return '';
    final stale =
        DateTime.now().difference(_cachedAt) > const Duration(minutes: 30);
    if (_cachedIdToken.isEmpty || stale) {
      await _refreshToken(u).timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
    }
    if (_cachedIdToken.isEmpty) {
      await _refreshToken(u, force: true).timeout(
        const Duration(seconds: 8),
        onTimeout: () {},
      );
    }
    return _cachedIdToken;
  }

  /// Последний известный токен без await (для синхронных URL).
  static String get cachedIdToken => _cachedIdToken;

  /// Заголовки для HTTP-вызовов функций: Content-Type + Authorization.
  static Future<Map<String, String>> headers() async {
    final token = await idToken();
    if (token.isEmpty) {
      debugPrint('AuthService: запрос уходит БЕЗ токена — сервер ответит 401');
    }
    return {
      'Content-Type': 'application/json',
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  /// Добавляет `auth=<token>` к URL функции (для аудиоплеера и т.п.).
  static String withAuthQuery(String url) {
    final token = _cachedIdToken;
    if (token.isEmpty) return url;
    final sep = url.contains('?') ? '&' : '?';
    return '$url${sep}auth=${Uri.encodeQueryComponent(token)}';
  }
}
