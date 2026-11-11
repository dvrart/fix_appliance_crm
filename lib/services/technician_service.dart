import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/api_keys.dart';
import '../models/technician.dart';
import 'auth_service.dart';
import 'firestore_service.dart';
import 'network_status_service.dart';

/// Управление мастерами, ролью текущего пользователя и расчётами.
class TechnicianService {
  TechnicianService._();

  /// Список всех мастеров (живёт у владельца).
  static final ValueNotifier<List<TechnicianProfile>> list =
      ValueNotifier<List<TechnicianProfile>>(const []);

  /// Профиль самого мастера, если в приложение вошёл мастер.
  static final ValueNotifier<TechnicianProfile?> selfProfile =
      ValueNotifier<TechnicianProfile?>(null);

  static Map<String, TechnicianProfile> _byId = const {};
  static StreamSubscription? _allSub;
  static StreamSubscription? _selfSub;
  static String? _boundUid;
  static bool _listeningAuth = false;

  static bool isOwnerUid(String? uid) =>
      uid != null && uid.trim() == kOwnerUid;

  static User? _safeCurrentUser() {
    try {
      return FirebaseAuth.instance.currentUser;
    } catch (_) {
      return null;
    }
  }

  /// Вошёл ли в приложение сторонний мастер (а не владелец).
  /// Если пользователь ещё не вошёл (старт / тесты) — считаем режим владельца.
  static bool get isTechnician {
    final u = _safeCurrentUser();
    if (u == null) return false;
    return !isOwnerUid(u.uid);
  }

  static bool get isOwner => !isTechnician;

  static String get currentUid => _safeCurrentUser()?.uid ?? '';

  static TechnicianProfile? byId(String? uid) {
    final key = (uid ?? '').trim();
    if (key.isEmpty) return null;
    if (isTechnician && selfProfile.value?.uid == key) {
      return selfProfile.value;
    }
    return _byId[key];
  }

  static List<TechnicianProfile> get activeTechnicians =>
      list.value.where((t) => t.active).toList();

  static void start() {
    if (!_listeningAuth) {
      _listeningAuth = true;
      AuthService.user.addListener(_rebind);
    }
    _rebind();
  }

  static void _rebind() {
    final u = AuthService.user.value;
    final uid = u?.uid;
    if (uid == _boundUid && (_allSub != null || _selfSub != null)) return;
    _cancelStreams();
    _boundUid = uid;
    if (uid == null || uid.isEmpty) {
      list.value = const [];
      _byId = const {};
      selfProfile.value = null;
      return;
    }

    if (isOwnerUid(uid)) {
      selfProfile.value = null;
      _allSub = FirestoreService.techniciansRef.snapshots().listen(
        (snapshot) {
          final parsed = <TechnicianProfile>[];
          final map = <String, TechnicianProfile>{};
          for (final doc in snapshot.docs) {
            try {
              final data = doc.data();
              if (data is! Map) continue;
              final tech = TechnicianProfile.fromMap(
                Map<String, dynamic>.from(data),
                doc.id,
              );
              parsed.add(tech);
              map[tech.uid] = tech;
            } catch (_) {}
          }
          parsed.sort((a, b) {
            if (a.active != b.active) return a.active ? -1 : 1;
            return a.displayName
                .toLowerCase()
                .compareTo(b.displayName.toLowerCase());
          });
          _byId = map;
          list.value = parsed;
        },
        onError: (Object e) => debugPrint('TechnicianService.list: $e'),
      );
    } else {
      list.value = const [];
      _byId = const {};
      _selfSub = FirestoreService.techniciansRef
          .doc(uid)
          .snapshots(includeMetadataChanges: true)
          .listen(
            (snap) {
              if (!snap.exists) {
                if (!snap.metadata.isFromCache) {
                  selfProfile.value = null;
                  unawaited(
                    AuthService.signOut(
                      reason: 'Доступ отключён владельцем',
                    ),
                  );
                }
                return;
              }
              final data = snap.data();
              if (data is! Map) return;
              final tech = TechnicianProfile.fromMap(
                Map<String, dynamic>.from(data),
                snap.id,
              );
              selfProfile.value = tech;
              if (!tech.active && !snap.metadata.isFromCache) {
                unawaited(
                  AuthService.signOut(
                    reason: 'Доступ отключён владельцем',
                  ),
                );
              }
            },
            onError: (Object e) => debugPrint('TechnicianService.self: $e'),
          );
    }
  }

  static void _cancelStreams() {
    _allSub?.cancel();
    _selfSub?.cancel();
    _allSub = null;
    _selfSub = null;
  }

  static void stop() {
    if (_listeningAuth) {
      AuthService.user.removeListener(_rebind);
      _listeningAuth = false;
    }
    _boundUid = null;
    _cancelStreams();
  }

  static Stream<List<TechnicianProfile>> streamAll() {
    return FirestoreService.techniciansRef.snapshots().map((snapshot) {
      final items = <TechnicianProfile>[];
      for (final doc in snapshot.docs) {
        try {
          final data = doc.data();
          if (data is! Map) continue;
          items.add(
            TechnicianProfile.fromMap(
              Map<String, dynamic>.from(data),
              doc.id,
            ),
          );
        } catch (_) {}
      }
      items.sort((a, b) {
        if (a.active != b.active) return a.active ? -1 : 1;
        return a.displayName
            .toLowerCase()
            .compareTo(b.displayName.toLowerCase());
      });
      return items;
    });
  }

  // ------------------------------------------------ управление через сервер

  static Future<TechnicianProfile> createTechnician({
    required String name,
    required String email,
    required String password,
    String phone = '',
    int colorValue = 0xFF00897B,
    double profitSharePercent = 50,
    String businessName = '',
    bool collectsHst = false,
    String hstNumber = '',
    String etransferEmail = '',
  }) async {
    final res = await _callManage({
      'action': 'create',
      'name': name.trim(),
      'email': email.trim(),
      'password': password,
      'phone': phone.trim(),
      'colorValue': colorValue,
      'profitSharePercent': profitSharePercent.clamp(0.0, 100.0),
      'businessName': businessName.trim(),
      'collectsHst': collectsHst,
      'hstNumber': hstNumber.trim(),
      'etransferEmail': etransferEmail.trim(),
    });
    final map = res['technician'] is Map
        ? Map<String, dynamic>.from(res['technician'] as Map)
        : <String, dynamic>{};
    final uid = (res['uid'] ?? map['uid'] ?? '').toString().trim();
    return TechnicianProfile.fromMap(map, uid);
  }

  static Future<void> updateTechnician({
    required String uid,
    required String name,
    required String email,
    String newPassword = '',
    String phone = '',
    int colorValue = 0xFF00897B,
    double profitSharePercent = 50,
    String businessName = '',
    bool collectsHst = false,
    String hstNumber = '',
    String etransferEmail = '',
    bool active = true,
  }) async {
    await _callManage({
      'action': 'update',
      'uid': uid.trim(),
      'name': name.trim(),
      'email': email.trim(),
      if (newPassword.isNotEmpty) 'password': newPassword,
      'phone': phone.trim(),
      'colorValue': colorValue,
      'profitSharePercent': profitSharePercent.clamp(0.0, 100.0),
      'businessName': businessName.trim(),
      'collectsHst': collectsHst,
      'hstNumber': hstNumber.trim(),
      'etransferEmail': etransferEmail.trim(),
      'active': active,
    });
  }

  static Future<void> setTechnicianActive({
    required String uid,
    required bool active,
  }) async {
    await _callManage({
      'action': 'setActive',
      'uid': uid.trim(),
      'active': active,
    });
  }

  static Future<Map<String, dynamic>> _callManage(
    Map<String, dynamic> payload,
  ) async {
    final response = await http
        .post(
          Uri.parse('$kFirebaseFunctionsUrl/manageTechnician'),
          headers: await AuthService.headers(),
          body: json.encode(payload),
        )
        .timeout(const Duration(seconds: 30));

    Map<String, dynamic> decoded = const {};
    if (response.body.isNotEmpty) {
      try {
        final raw = json.decode(response.body);
        if (raw is Map) decoded = Map<String, dynamic>.from(raw);
      } catch (_) {}
    }
    if (response.statusCode != 200 || decoded['success'] != true) {
      final msg = (decoded['error'] ??
              'Ошибка сервера (${response.statusCode})')
          .toString();
      throw Exception(msg);
    }
    return decoded;
  }

  // ------------------------------------------------ сверка расчётов

  static Stream<List<TechnicianSettlement>> streamAllSettlements() {
    return FirestoreService.technicianSettlementsRef.snapshots().map((snap) {
      final items = <TechnicianSettlement>[];
      for (final doc in snap.docs) {
        try {
          final data = doc.data();
          if (data is! Map) continue;
          items.add(
            TechnicianSettlement.fromMap(
              Map<String, dynamic>.from(data),
              doc.id,
            ),
          );
        } catch (_) {}
      }
      items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return items;
    });
  }

  static Stream<List<TechnicianSettlement>> streamSettlementsFor(
    String technicianId,
  ) {
    final id = technicianId.trim();
    if (id.isEmpty) return Stream.value(const []);
    return FirestoreService.technicianSettlementsRef
        .where('technicianId', isEqualTo: id)
        .snapshots()
        .map((snap) {
          final items = <TechnicianSettlement>[];
          for (final doc in snap.docs) {
            try {
              final data = doc.data();
              if (data is! Map) continue;
              items.add(
                TechnicianSettlement.fromMap(
                  Map<String, dynamic>.from(data),
                  doc.id,
                ),
              );
            } catch (_) {}
          }
          items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
          return items;
        });
  }

  static Future<String> recordSettlement({
    required String technicianId,
    required String technicianName,
    required double amount,
    String note = '',
    List<String> jobIds = const [],
  }) async {
    final docRef = FirestoreService.technicianSettlementsRef.doc();
    final entry = TechnicianSettlement(
      id: docRef.id,
      technicianId: technicianId.trim(),
      technicianName: technicianName.trim(),
      amount: amount,
      note: note.trim(),
      jobIds: jobIds,
      createdAt: DateTime.now(),
    );
    await settleWrite(docRef.set(entry.toMap()));
    return docRef.id;
  }

  static Future<void> deleteSettlement(String settlementId) async {
    final id = settlementId.trim();
    if (id.isEmpty) return;
    await settleWrite(FirestoreService.technicianSettlementsRef.doc(id).delete());
  }
}
