import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

class SubscriptionInfo {
  const SubscriptionInfo({
    required this.status,
    this.trialEndsAt,
    this.currentPeriodEnd,
    this.plan = 'shop',
  });

  final String status;
  final DateTime? trialEndsAt;
  final DateTime? currentPeriodEnd;
  final String plan;

  static const none = SubscriptionInfo(status: 'none');

  factory SubscriptionInfo.fromMap(Map<String, dynamic>? raw) {
    if (raw == null) return none;
    DateTime? ts(dynamic value) {
      if (value == null) return null;
      if (value is DateTime) return value.toUtc();
      if (value is Timestamp) return value.toDate().toUtc();
      return DateTime.tryParse(value.toString())?.toUtc();
    }

    return SubscriptionInfo(
      status: (raw['status'] ?? 'none').toString(),
      trialEndsAt: ts(raw['trialEndsAt']),
      currentPeriodEnd: ts(raw['currentPeriodEnd']),
      plan: (raw['plan'] ?? 'shop').toString(),
    );
  }

  bool get isEntitled {
    final now = DateTime.now().toUtc();
    if (status == 'active') {
      if (currentPeriodEnd != null && !currentPeriodEnd!.isAfter(now)) {
        return false;
      }
      return true;
    }
    if (status == 'trial') {
      return trialEndsAt != null && trialEndsAt!.isAfter(now);
    }
    return false;
  }

  DateTime? get endsAt {
    if (status == 'trial') return trialEndsAt;
    if (status == 'active') return currentPeriodEnd;
    return null;
  }
}

/// Runtime tenant. Paths stay `companies/{id}/...`; the id comes from the signed-in account.
class CompanySession extends ChangeNotifier {
  CompanySession._();
  static final CompanySession instance = CompanySession._();

  String? _companyId;
  String? _companyName;
  String? _role;
  SubscriptionInfo _subscription = SubscriptionInfo.none;

  bool get isReady => _companyId != null && _companyId!.isNotEmpty;

  String get companyId {
    final id = _companyId;
    if (id == null || id.isEmpty) {
      throw StateError('Company session is not ready');
    }
    return id;
  }

  String get companyName => _companyName ?? '';
  String get role => _role ?? '';
  SubscriptionInfo get subscription => _subscription;
  bool get isEntitled => isReady && _subscription.isEntitled;

  void bind({
    required String companyId,
    required String companyName,
    required String role,
    required SubscriptionInfo subscription,
  }) {
    _companyId = companyId;
    _companyName = companyName;
    _role = role;
    _subscription = subscription;
    notifyListeners();
  }

  void clear() {
    _companyId = null;
    _companyName = null;
    _role = null;
    _subscription = SubscriptionInfo.none;
    notifyListeners();
  }
}
