import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/company_session.dart';
import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../services/account_service.dart';
import '../../services/app_time_service.dart';
import '../../services/settings_service.dart';
import '../../shared/widgets/animated_app_logo.dart';
import 'create_company_screen.dart';
import 'login_screen.dart';
import 'paywall_screen.dart';

enum _AuthPhase { loading, signedOut, needsCompany, paywall, app, error }

class AuthGate extends StatefulWidget {
  const AuthGate({super.key, required this.child});

  final Widget child;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  StreamSubscription<User?>? _sub;
  _AuthPhase _phase = _AuthPhase.loading;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sub = AccountService.instance.authChanges().listen(_onAuth);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _onAuth(User? user) async {
    if (!mounted) return;
    if (user == null) {
      CompanySession.instance.clear();
      setState(() {
        _phase = _AuthPhase.signedOut;
        _error = null;
      });
      return;
    }
    setState(() {
      _phase = _AuthPhase.loading;
      _error = null;
    });
    try {
      final snap = await AccountService.instance.load(user);
      if (!mounted) return;
      if (snap.needsCompany) {
        setState(() => _phase = _AuthPhase.needsCompany);
        return;
      }
      if (!CompanySession.instance.isEntitled) {
        setState(() => _phase = _AuthPhase.paywall);
        return;
      }
      await _enterShop();
      if (!mounted) return;
      setState(() => _phase = _AuthPhase.app);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _AuthPhase.error;
        _error = e.toString();
      });
    }
  }

  Future<void> _enterShop() async {
    await SettingsService.ensureAiVoiceSettings();
    await SettingsService.ensureServiceAreaLabel();
    await SettingsService.ensureEnglishClientCopy();
    await AppTimeService.ensureInitialized();
    await AppLocale.instance.load();
  }

  Future<void> _createdCompany() async {
    final user = AccountService.instance.currentUser;
    await _onAuth(user);
  }

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _AuthPhase.loading:
        return Scaffold(
          backgroundColor: AppColors.primary,
          body: const Center(child: AnimatedAppLogo(size: 196)),
        );
      case _AuthPhase.signedOut:
        return const LoginScreen();
      case _AuthPhase.needsCompany:
        return CreateCompanyScreen(onCreated: _createdCompany);
      case _AuthPhase.paywall:
        return PaywallScreen(onChanged: () => _onAuth(AccountService.instance.currentUser));
      case _AuthPhase.app:
        return widget.child;
      case _AuthPhase.error:
        return Scaffold(
          backgroundColor: AppColors.primary,
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(
                _error ?? '',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        );
    }
  }
}
