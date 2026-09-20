import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Firebase Auth: вход владельца и ID-токен для защищённых HTTP-функций.
///
/// Токен кэшируется, чтобы синхронный код (URL для аудиоплеера) мог
/// подставить его без await. Обновляется слушателем idTokenChanges
/// и принудительно при запросе заголовков.
///
/// Учётные данные сохраняются в зашифрованное хранилище устройства.
/// При потере сессии приложение восстанавливает вход автоматически —
/// без показа экрана с полями email/пароль.
class AuthService {
  AuthService._();

  static final ValueNotifier<User?> user =
      ValueNotifier<User?>(FirebaseAuth.instance.currentUser);

  static String _cachedIdToken = '';
  static DateTime _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static StreamSubscription<User?>? _sub;

  // ------------------------------------------------ авто-вход

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _kEmail = 'auth_saved_email';
  static const _kPassword = 'auth_saved_password';

  /// true пока идёт тихое восстановление сессии — AppLockGate
  /// показывает заставку вместо экрана входа.
  static final ValueNotifier<bool> autoSigningIn =
      ValueNotifier<bool>(false);
  static bool _autoSignInInProgress = false;

  // ------------------------------------------------ инициализация

  static void init() {
    user.value = FirebaseAuth.instance.currentUser;
    _sub ??= FirebaseAuth.instance.idTokenChanges().listen((u) {
      user.value = u;
      if (u == null) {
        _cachedIdToken = '';
        // Сессия пропала во время работы — пробуем войти тихо.
        if (!_autoSignInInProgress) unawaited(_runAutoSignIn());
      } else {
        unawaited(_refreshToken(u));
      }
    });
    // Не вошли при старте — пробуем восстановить сессию из хранилища.
    if (user.value == null) unawaited(_runAutoSignIn());
  }

  static bool get signedIn => FirebaseAuth.instance.currentUser != null;

  // ------------------------------------------------ ручной вход

  static Future<void> signIn(String email, String password) async {
    await FirebaseAuth.instance.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    final u = FirebaseAuth.instance.currentUser;
    if (u != null) await _refreshToken(u);
    // Запоминаем для будущего авто-входа.
    unawaited(_saveCredentials(email.trim(), password));
  }

  // ------------------------------------------------ авто-вход

  static Future<void> _saveCredentials(
      String email, String password) async {
    try {
      await _storage.write(key: _kEmail, value: email);
      await _storage.write(key: _kPassword, value: password);
    } catch (e) {
      debugPrint('AuthService: сохранение учётных данных не удалось: $e');
    }
  }

  /// Читает сохранённые учётные данные и выполняет вход. Возвращает true
  /// при успехе. Не показывает ошибку — вызывающий сам решит, что делать.
  static Future<bool> tryAutoSignIn() async {
    try {
      final email = await _storage.read(key: _kEmail);
      final password = await _storage.read(key: _kPassword);
      if (email == null ||
          password == null ||
          email.isEmpty ||
          password.isEmpty) {
        return false;
      }
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      final u = FirebaseAuth.instance.currentUser;
      if (u != null) await _refreshToken(u);
      return u != null;
    } catch (e) {
      debugPrint('AuthService: авто-вход не удался: $e');
      return false;
    }
  }

  static Future<void> _runAutoSignIn() async {
    if (_autoSignInInProgress) return;
    _autoSignInInProgress = true;
    autoSigningIn.value = true;
    try {
      await tryAutoSignIn();
    } finally {
      _autoSignInInProgress = false;
      autoSigningIn.value = false;
    }
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
    final u = FirebaseAuth.instance.currentUser;
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
      // Без токена запрос уходит без заголовка и сервер отвечает 401 — а на
      // экране это выглядело просто как «не удалось отправить SMS». Пробуем
      // выпросить токен принудительно, прежде чем сдаваться.
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
