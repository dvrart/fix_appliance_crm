import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Firebase Auth: вход владельца и ID-токен для защищённых HTTP-функций.
///
/// Токен кэшируется, чтобы синхронный код (URL для аудиоплеера) мог
/// подставить его без await. Обновляется слушателем idTokenChanges
/// и принудительно при запросе заголовков.
class AuthService {
  AuthService._();

  static final ValueNotifier<User?> user =
      ValueNotifier<User?>(FirebaseAuth.instance.currentUser);

  static String _cachedIdToken = '';
  static DateTime _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static StreamSubscription<User?>? _sub;

  static void init() {
    user.value = FirebaseAuth.instance.currentUser;
    _sub ??= FirebaseAuth.instance.idTokenChanges().listen((u) {
      user.value = u;
      if (u == null) {
        _cachedIdToken = '';
      } else {
        unawaited(_refreshToken(u));
      }
    });
  }

  static bool get signedIn => FirebaseAuth.instance.currentUser != null;

  static Future<void> signIn(String email, String password) async {
    await FirebaseAuth.instance.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    final u = FirebaseAuth.instance.currentUser;
    if (u != null) await _refreshToken(u);
  }

  static Future<void> _refreshToken(User u) async {
    try {
      final token = await u.getIdToken();
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
    return _cachedIdToken;
  }

  /// Последний известный токен без await (для синхронных URL).
  static String get cachedIdToken => _cachedIdToken;

  /// Заголовки для HTTP-вызовов функций: Content-Type + Authorization.
  static Future<Map<String, String>> headers() async {
    final token = await idToken();
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
