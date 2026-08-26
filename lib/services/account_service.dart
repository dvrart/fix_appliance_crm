import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../core/company_session.dart';

class AccountSnapshot {
  const AccountSnapshot._({
    required this.needsCompany,
  });

  final bool needsCompany;

  static const signedIn = AccountSnapshot._(needsCompany: false);
  static const needsCompanySetup = AccountSnapshot._(needsCompany: true);
}

class AccountService {
  AccountService._();
  static final AccountService instance = AccountService._();

  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;

  static const trialDays = 14;

  User? get currentUser => _auth.currentUser;
  Stream<User?> authChanges() => _auth.authStateChanges();

  Future<UserCredential> signIn({
    required String email,
    required String password,
  }) {
    return _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  Future<UserCredential> register({
    required String email,
    required String password,
  }) {
    return _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  Future<UserCredential> signInWithGoogle() {
    final provider = GoogleAuthProvider()
      ..addScope('email')
      ..addScope('profile');
    return _auth.signInWithProvider(provider);
  }

  Future<UserCredential> signInWithApple() {
    final provider = AppleAuthProvider()
      ..addScope('email')
      ..addScope('name');
    return _auth.signInWithProvider(provider);
  }

  Future<void> signOut() async {
    CompanySession.instance.clear();
    await _auth.signOut();
  }

  Future<AccountSnapshot> load(User user) async {
    final userSnap = await _db.collection('users').doc(user.uid).get();
    if (!userSnap.exists) return AccountSnapshot.needsCompanySetup;
    final data = userSnap.data() ?? {};
    final companyId = (data['companyId'] ?? '').toString().trim();
    if (companyId.isEmpty) return AccountSnapshot.needsCompanySetup;

    final companySnap = await _db.collection('companies').doc(companyId).get();
    if (!companySnap.exists) return AccountSnapshot.needsCompanySetup;
    final company = companySnap.data() ?? {};
    final subRaw = company['subscription'];
    CompanySession.instance.bind(
      companyId: companyId,
      companyName: (company['name'] ?? '').toString(),
      role: (data['role'] ?? 'owner').toString(),
      subscription: SubscriptionInfo.fromMap(
        subRaw is Map ? Map<String, dynamic>.from(subRaw) : null,
      ),
    );
    return AccountSnapshot.signedIn;
  }

  Future<void> createCompany({
    required User user,
    required String name,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Company name is empty');
    }
    final id = _newCompanyId(trimmed);
    final trialEnd = DateTime.now().toUtc().add(const Duration(days: trialDays));
    final batch = _db.batch();
    final companyRef = _db.collection('companies').doc(id);
    batch.set(companyRef, {
      'name': trimmed,
      'ownerUid': user.uid,
      'createdAt': FieldValue.serverTimestamp(),
      'subscription': {
        'status': 'trial',
        'plan': 'shop',
        'trialEndsAt': Timestamp.fromDate(trialEnd),
      },
    });
    batch.set(companyRef.collection('members').doc(user.uid), {
      'role': 'owner',
      'email': user.email,
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.set(_db.collection('users').doc(user.uid), {
      'companyId': id,
      'email': user.email,
      'role': 'owner',
      'createdAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
    await load(user);
  }

  String _newCompanyId(String name) {
    final slug = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final suffix = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final base = slug.isEmpty ? 'shop' : slug;
    final id = '${base}_$suffix';
    return id.length <= 48 ? id : id.substring(0, 48);
  }
}
