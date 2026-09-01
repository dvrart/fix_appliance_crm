import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Замок на вход. PIN хранится только на телефоне (хэш в SharedPreferences),
/// в Firestore он не уезжает.
class AppLockService {
  static const _kEnabled = 'appLockEnabled';
  static const _kPinHash = 'appLockPinHash';
  static const _kSalt = 'appLockSalt';
  static const _kBiometric = 'appLockBiometric';
  static const _kGraceMinutes = 'appLockGraceMinutes';

  static const int pinLength = 4;
  static const List<int> graceOptions = [0, 1, 5, 15, 60];

  static final ValueNotifier<bool> locked = ValueNotifier<bool>(false);

  static bool _enabled = false;
  static bool _biometric = true;
  static int _graceMinutes = 1;
  static DateTime? _lastUnlockedAt;
  static bool _loaded = false;

  static bool get enabled => _enabled;
  static bool get biometricEnabled => _biometric && _enabled;
  static int get graceMinutes => _graceMinutes;

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_kEnabled) ?? false;
      _biometric = prefs.getBool(_kBiometric) ?? true;
      _graceMinutes = prefs.getInt(_kGraceMinutes) ?? 1;
      final hash = prefs.getString(_kPinHash) ?? '';
      if (hash.isEmpty) _enabled = false;
    } catch (error) {
      debugPrint('AppLock load: $error');
      _enabled = false;
    }
    _loaded = true;
    locked.value = _enabled;
  }

  static bool get isReady => _loaded;

  static String _hash(String pin, String salt) {
    return sha256.convert(utf8.encode('$salt|$pin')).toString();
  }

  static Future<void> setPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final salt = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    await prefs.setString(_kSalt, salt);
    await prefs.setString(_kPinHash, _hash(pin, salt));
    await prefs.setBool(_kEnabled, true);
    _enabled = true;
    _lastUnlockedAt = DateTime.now();
    locked.value = false;
  }

  static Future<bool> verifyPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final salt = prefs.getString(_kSalt) ?? '';
    final hash = prefs.getString(_kPinHash) ?? '';
    if (hash.isEmpty) return true;
    return _hash(pin, salt) == hash;
  }

  static Future<void> disable() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kPinHash);
    await prefs.remove(_kSalt);
    await prefs.setBool(_kEnabled, false);
    _enabled = false;
    locked.value = false;
  }

  static Future<void> setBiometric(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBiometric, value);
    _biometric = value;
  }

  static Future<void> setGraceMinutes(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kGraceMinutes, value);
    _graceMinutes = value;
  }

  static void markUnlocked() {
    _lastUnlockedAt = DateTime.now();
    locked.value = false;
  }

  /// Экран уходил в фон — стоит ли спрашивать PIN снова.
  static void onResumed() {
    if (!_enabled || locked.value) return;
    final last = _lastUnlockedAt;
    if (last == null) {
      locked.value = true;
      return;
    }
    if (DateTime.now().difference(last).inMinutes >= _graceMinutes) {
      locked.value = true;
    }
  }

  static void onPaused() {
    if (!_enabled) return;
    _lastUnlockedAt = DateTime.now();
  }

  /// Палец есть в телефоне и его реально записали в настройках Android.
  /// `canCheckBiometrics` отвечает только про железо, поэтому его мало.
  static Future<bool> canUseBiometrics() async {
    try {
      final auth = LocalAuthentication();
      if (!await auth.isDeviceSupported()) return false;
      if (!await auth.canCheckBiometrics) return false;
      final available = await auth.getAvailableBiometrics();
      return available.isNotEmpty;
    } catch (error) {
      debugPrint('AppLock biometrics check: $error');
      return false;
    }
  }

  static Future<bool> authenticateBiometric(String reason) async {
    try {
      final auth = LocalAuthentication();
      return await auth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } catch (error) {
      debugPrint('AppLock biometrics: $error');
      return false;
    }
  }
}
