import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../services/app_lock_service.dart';
import '../../../shared/widgets/app_lock_gate.dart';
import '../widgets/settings_ui.dart';

class AppLockSettingsPage extends StatefulWidget {
  const AppLockSettingsPage({super.key});

  @override
  State<AppLockSettingsPage> createState() => _AppLockSettingsPageState();
}

class _AppLockSettingsPageState extends State<AppLockSettingsPage>
    with WidgetsBindingObserver {
  bool _biometricSupported = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkBiometrics();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Палец могли добавить в настройках телефона и вернуться — перепроверяем.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkBiometrics();
  }

  Future<void> _checkBiometrics() async {
    final supported = await AppLockService.canUseBiometrics();
    if (!mounted || supported == _biometricSupported) return;
    setState(() => _biometricSupported = supported);
  }

  Future<String?> _askPin() {
    return Navigator.push<String>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const PinLockScreen(setupMode: true),
      ),
    );
  }

  Future<void> _toggleLock(bool value) async {
    if (!value) {
      await AppLockService.disable();
      if (!mounted) return;
      setState(() {});
      return;
    }
    final pin = await _askPin();
    if (pin == null || !mounted) return;
    await AppLockService.setPin(pin);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _changePin() async {
    final pin = await _askPin();
    if (pin == null || !mounted) return;
    await AppLockService.setPin(pin);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.tr('PIN изменён', 'PIN changed'))),
    );
  }

  String _graceLabel(int minutes) {
    if (minutes <= 0) return context.tr('Сразу', 'Right away');
    if (minutes == 1) return context.tr('Через 1 минуту', 'After 1 minute');
    if (minutes < 60) {
      return context.tr('Через $minutes минут', 'After $minutes minutes');
    }
    return context.tr('Через час', 'After an hour');
  }

  Future<void> _pickGrace() async {
    final next = await showModalBottomSheet<int>(
      context: context,
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                context.tr('Спрашивать PIN', 'Ask for the PIN'),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                context.tr(
                  'После того как свернули приложение',
                  'After the app goes to the background',
                ),
              ),
            ),
            for (final minutes in AppLockService.graceOptions)
              ListTile(
                title: Text(_graceLabel(minutes)),
                trailing: minutes == AppLockService.graceMinutes
                    ? const Icon(Icons.check, color: Colors.green)
                    : null,
                onTap: () => Navigator.pop(context, minutes),
              ),
          ],
        ),
      ),
    );
    if (next == null || !mounted) return;
    await AppLockService.setGraceMinutes(next);
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final on = AppLockService.enabled;
    return SettingsPageScaffold(
      title: context.tr('Замок', 'Lock'),
      body: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              context.tr(
                'PIN хранится только на этом телефоне. Если забудете — переустановите приложение.',
                'The PIN stays on this phone only. If you forget it, reinstall the app.',
              ),
              style: const TextStyle(
                fontSize: 13,
                color: Colors.black54,
                height: 1.3,
              ),
            ),
          ),
          SettingsGroup(
            children: [
              SettingsRow(
                title: context.tr('Замок на вход', 'Lock the app'),
                subtitle: on
                    ? context.tr('Включён', 'On')
                    : context.tr('Выключен', 'Off'),
                icon: Icons.lock_outline,
                iconColor: on ? Colors.green : Colors.grey,
                showDivider: on,
                trailing: Switch(
                  value: on,
                  activeThumbColor: Colors.green,
                  onChanged: _toggleLock,
                ),
              ),
              if (on)
                SettingsRow(
                  title: context.tr('Сменить PIN', 'Change the PIN'),
                  subtitle: context.tr('4 цифры', '4 digits'),
                  icon: Icons.pin_outlined,
                  iconColor: AppColors.primary,
                  onTap: _changePin,
                ),
              if (on)
                SettingsRow(
                  title: context.tr('Отпечаток', 'Fingerprint'),
                    subtitle: _biometricSupported
                        ? context.tr(
                            'Разблокировать пальцем',
                            'Unlock with your finger',
                          )
                        : context.tr(
                            'Сначала добавьте отпечаток в настройках телефона',
                            'Add a fingerprint in the phone settings first',
                          ),
                  icon: Icons.fingerprint,
                  iconColor: _biometricSupported
                      ? Colors.deepPurple
                      : Colors.grey,
                  showDivider: true,
                  trailing: Switch(
                    value: AppLockService.biometricEnabled && _biometricSupported,
                    activeThumbColor: Colors.green,
                    onChanged: _biometricSupported
                        ? (value) async {
                            await AppLockService.setBiometric(value);
                            if (!mounted) return;
                            setState(() {});
                          }
                        : null,
                  ),
                ),
              if (on)
                SettingsRow(
                  title: context.tr('Спрашивать PIN', 'Ask for the PIN'),
                  subtitle: _graceLabel(AppLockService.graceMinutes),
                  icon: Icons.timer_outlined,
                  iconColor: Colors.orange,
                  showDivider: false,
                  onTap: _pickGrace,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
