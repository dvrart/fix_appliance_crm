import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api_keys.dart';
import '../core/tester_build.dart';
import '../models/technician.dart';
import 'service_guide_service.dart';
import 'settings_service.dart';

/// Firebase Auth: автоматический вход владельца и ID-токен для защищённых
/// HTTP-функций и правил Firestore/Storage.
class AuthService {
  AuthService._();

  static User? _safeCurrentUser() {
    try {
      return FirebaseAuth.instance.currentUser;
    } catch (_) {
      return null;
    }
  }

  static String _resolvedCompanyId = '';
  static String _resolvedOwnerUid = '';

  static String get currentUserUid => _safeCurrentUser()?.uid.trim() ?? '';

  static String get currentOwnerUid {
    if (!kTesterAppBuild) return 'Ew8vDgXvuMMwt9gYQUOi7rujNxO2';
    if (_resolvedOwnerUid.isNotEmpty) return _resolvedOwnerUid;
    final uid = _safeCurrentUser()?.uid.trim() ?? '';
    return uid.isNotEmpty ? uid : 'Ew8vDgXvuMMwt9gYQUOi7rujNxO2';
  }

  static String get currentCompanyId {
    if (!kTesterAppBuild) return 'fix_appliance_ca';
    if (_resolvedCompanyId.isNotEmpty) return _resolvedCompanyId;
    final uid = _safeCurrentUser()?.uid.trim() ?? '';
    return uid.isNotEmpty ? 'tester_$uid' : 'tester_offline';
  }

  static final ValueNotifier<User?> user =
      ValueNotifier<User?>(_safeCurrentUser());
  static final ValueNotifier<int> roleRevision = ValueNotifier<int>(0);

  static String _cachedIdToken = '';
  static DateTime _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static StreamSubscription<User?>? _sub;
  static StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _testerSub;
  static String? _boundTesterUid;
  static Timer? _retryTimer;

  static const _kEmail = 'auth_saved_email';
  static const _kPassword = 'auth_saved_password';

  /// Вшиты ли учётные данные владельца прямо в сборку.
  /// В сборке для мастеров (`TECH_APP=true`) и тестировщиков (`TESTER_APP=true`) отключён.
  static bool get hasBuiltInCredentials =>
      !kTechnicianAppBuild &&
      !kTesterAppBuild &&
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
      if (kTesterAppBuild) _bindTesterSession(u);
      if (u == null) {
        _cachedIdToken = '';
        unawaited(_runAutoSignIn());
      } else {
        _retryTimer?.cancel();
        _retryTimer = null;
        unawaited(_refreshToken(u));
      }
    });
    if (kTesterAppBuild) _bindTesterSession(user.value);
    if (user.value == null) {
      unawaited(_runAutoSignIn());
    } else {
      unawaited(_refreshToken(user.value!));
    }
  }

  static void _applyTesterRoleDoc(String uid, Map<String, dynamic>? data) {
    final isSubTech =
        data != null &&
        data['role'] == 'technician' &&
        (data['parentCompanyId'] ?? '').toString().trim().isNotEmpty;
    final nextCompany = isSubTech
        ? data['parentCompanyId'].toString().trim()
        : 'tester_$uid';
    final nextOwner = isSubTech
        ? ((data['parentOwnerUid'] ?? '').toString().trim().isNotEmpty
              ? data['parentOwnerUid'].toString().trim()
              : nextCompany.replaceFirst('tester_', ''))
        : uid;
    final changed =
        _resolvedCompanyId != nextCompany || _resolvedOwnerUid != nextOwner;
    _resolvedCompanyId = nextCompany;
    _resolvedOwnerUid = nextOwner;
    if (changed) {
      roleRevision.value++;
    }
  }

  static void _bindTesterSession(User? u) {
    final uid = u?.uid.trim() ?? '';
    if (uid == _boundTesterUid && (uid.isEmpty || _testerSub != null)) {
      return;
    }
    _testerSub?.cancel();
    _testerSub = null;
    _boundTesterUid = uid.isEmpty ? null : uid;
    if (u == null || uid.isEmpty) {
      _resolvedCompanyId = '';
      _resolvedOwnerUid = '';
      return;
    }

    unawaited(_syncTesterAccount(u));

    _testerSub = FirebaseFirestore.instance
        .collection('testers')
        .doc(uid)
        .snapshots(includeMetadataChanges: true)
        .listen(
          (snap) {
            if (!snap.exists) return;
            final data = snap.data();
            _applyTesterRoleDoc(uid, data);
            if (!snap.metadata.isFromCache &&
                data != null &&
                data['active'] == false) {
              unawaited(
                signOut(reason: 'Тестовый доступ отключён владельцем'),
              );
            }
          },
          onError: (Object e) => debugPrint('AuthService.testerSub: $e'),
        );
  }

  static Future<void> _syncTesterAccount(
    User u, {
    String? customName,
    String? customPhone,
  }) async {
    try {
      final db = FirebaseFirestore.instance;
      final docRef = db.collection('testers').doc(u.uid);
      final snap = await docRef.get().timeout(const Duration(seconds: 6));
      final name = (customName ?? u.displayName ?? '').trim();
      final email = (u.email ?? '').trim();
      final phone = (customPhone ?? '').trim();
      if (!snap.exists) {
        _applyTesterRoleDoc(u.uid, null);
        await docRef.set({
          'uid': u.uid,
          'email': email,
          'name': name,
          if (phone.isNotEmpty) 'phone': phone,
          'role': 'owner',
          'companyId': 'tester_${u.uid}',
          'active': true,
          'createdAt': FieldValue.serverTimestamp(),
          'lastSeenAt': FieldValue.serverTimestamp(),
        });
        unawaited(_initTesterCompany(phone: phone));
      } else {
        final data = snap.data();
        _applyTesterRoleDoc(u.uid, data);
        await docRef.set({
          if (email.isNotEmpty) 'email': email,
          if (name.isNotEmpty) 'name': name,
          if (phone.isNotEmpty) 'phone': phone,
          'lastSeenAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        if (data == null || data['role'] != 'technician') {
          unawaited(_initTesterCompany(phone: phone));
        }
      }
    } catch (e) {
      debugPrint('AuthService._syncTesterAccount: $e');
    }
  }

  static Future<void> saveTesterCellPhone(String phone) async {
    if (!kTesterAppBuild) return;
    final u = _safeCurrentUser();
    if (u == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('testers')
          .doc(u.uid)
          .set({'phone': phone.trim()}, SetOptions(merge: true));
    } catch (e) {
      debugPrint('AuthService.saveTesterCellPhone: $e');
    }
  }

  static Future<void> _initTesterCompany({
    String? workshopName,
    String? email,
    String? phone,
  }) async {
    try {
      final cleanPhone = (phone ?? '').trim();
      if (cleanPhone.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection('companies')
            .doc(currentCompanyId)
            .collection('settings')
            .doc('config')
            .set({
              'masterCellNumber': cleanPhone,
              'callRouteOutgoing': 'auto',
            }, SetOptions(merge: true));
      }
      if ((workshopName ?? '').trim().isNotEmpty ||
          (email ?? '').trim().isNotEmpty ||
          cleanPhone.isNotEmpty) {
        final docsRef = FirebaseFirestore.instance
            .collection('companies')
            .doc(currentCompanyId)
            .collection('settings')
            .doc('documents');
        final snap = await docsRef.get().timeout(const Duration(seconds: 6));
        if (!snap.exists) {
          final cleanName = (workshopName ?? '').trim();
          final cleanEmail = (email ?? '').trim();
          await docsRef.set({
            'companyName':
                cleanName.isNotEmpty ? cleanName : 'Appliance Repair',
            'companyEmail': cleanEmail,
            'companyPhone': cleanPhone,
            'technicianName': cleanName,
            'companyAddress': '',
            'smsHeader': '',
          }, SetOptions(merge: true));
        }
      }
      unawaited(ServiceGuideService.ensureServerSeeded(force: true));
      unawaited(SettingsService.ensureAiVoiceSettings());
      unawaited(SettingsService.ensureServiceAreaLabel());
      unawaited(SettingsService.ensureEnglishClientCopy());
    } catch (e) {
      debugPrint('AuthService._initTesterCompany: $e');
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
    if (u != null) {
      await _refreshToken(u);
      if (kTesterAppBuild) _bindTesterSession(u);
    }
    unawaited(_saveCredentials(email.trim(), password));
  }

  static Future<void> register({
    required String name,
    required String email,
    required String password,
    String phone = '',
  }) async {
    forcedSignOutNotice.value = '';
    final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    final u = cred.user ?? FirebaseAuth.instance.currentUser;
    if (u != null && name.trim().isNotEmpty) {
      try {
        await u.updateDisplayName(name.trim());
      } catch (_) {}
    }
    user.value = u;
    if (u != null) {
      await _refreshToken(u);
      if (kTesterAppBuild) {
        await _syncTesterAccount(
          u,
          customName: name.trim(),
          customPhone: phone.trim(),
        );
        await _initTesterCompany(
          workshopName: name.trim(),
          email: email.trim(),
          phone: phone.trim(),
        );
        _bindTesterSession(u);
      }
    }
    unawaited(_saveCredentials(email.trim(), password));
  }

  static Future<void> signOut({String reason = ''}) async {
    _retryTimer?.cancel();
    _retryTimer = null;
    _testerSub?.cancel();
    _testerSub = null;
    _boundTesterUid = null;
    _resolvedCompanyId = '';
    _resolvedOwnerUid = '';
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
      String email =
          (kTechnicianAppBuild || kTesterAppBuild) ? '' : kOwnerEmail.trim();
      String password =
          (kTechnicianAppBuild || kTesterAppBuild) ? '' : kOwnerPassword;
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
