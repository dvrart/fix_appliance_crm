import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants.dart';
import 'call_screen.dart';
import '../../core/l10n/app_locale.dart';

/// Клавиатура для набора номера и исходящего звонка через Twilio.
class DialPadScreen extends StatefulWidget {
  const DialPadScreen({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(builder: (_) => const DialPadScreen()),
    );
  }

  @override
  State<DialPadScreen> createState() => _DialPadScreenState();
}

class _DialPadScreenState extends State<DialPadScreen> {
  String _digits = '';
  bool _callPressed = false;
  bool _calling = false;

  void _append(String value) {
    HapticFeedback.lightImpact();
    if (_digits.length >= 16) return;
    setState(() => _digits += value);
  }

  void _backspace() {
    if (_digits.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() => _digits = _digits.substring(0, _digits.length - 1));
  }

  String get _display {
    final d = _digits.replaceAll(RegExp(r'\D'), '');
    if (d.isEmpty) return '';
    if (d.length <= 3) return d;
    if (d.length <= 6) return '(${d.substring(0, 3)}) ${d.substring(3)}';
    if (d.length <= 10) {
      return '(${d.substring(0, 3)}) ${d.substring(3, 6)}-${d.substring(6)}';
    }
    if (d.length == 11 && d.startsWith('1')) {
      return '+1 (${d.substring(1, 4)}) ${d.substring(4, 7)}-${d.substring(7)}';
    }
    return '+$d';
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = data?.text ?? '';
    final cleaned = raw.replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('В буфере нет номера'.tr)),
      );
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() => _digits = cleaned.length > 16 ? cleaned.substring(0, 16) : cleaned);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Номер вставлен'.tr)),
    );
  }

  Future<void> _call() async {
    final digits = _digits.replaceAll(RegExp(r'[^\d+]'), '');
    if (digits.replaceAll('+', '').length < 10) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _callPressed = true;
      _calling = true;
    });
    try {
      await CallScreen.open(context, phoneNumber: digits);
    } finally {
      if (mounted) {
        setState(() {
          _callPressed = false;
          _calling = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final canCall = _digits.replaceAll(RegExp(r'\D'), '').length >= 10;
    final callLit = canCall && (_callPressed || _calling);
    return Scaffold(
      backgroundColor: AppColors.primary,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text('Набор номера'.tr),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: GestureDetector(
                onLongPress: _paste,
                onDoubleTap: _paste,
                child: Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(minHeight: 72),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                  child: Column(
                    children: [
                      Text(
                        _display.isEmpty ? 'Введите номер'.tr : _display,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _display.isEmpty ? Colors.white54 : Colors.white,
                          fontSize: _display.isEmpty ? 22 : 32,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Зажмите, чтобы вставить'.tr,
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                children: [
                  for (final row in const [
                    ['1', '2', '3'],
                    ['4', '5', '6'],
                    ['7', '8', '9'],
                    ['*', '0', '#'],
                  ])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          for (final key in row)
                            _Key(
                              label: key,
                              subtitle: key == '0' ? '+' : null,
                              onTap: () => _append(key),
                              onLongPress: key == '0' ? () => _append('+') : null,
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                SizedBox(
                  width: 84,
                  height: 84,
                  child: IconButton(
                    tooltip: 'Вставить номер'.tr,
                    onPressed: _paste,
                    icon: const Icon(Icons.content_paste, color: Colors.white70, size: 26),
                  ),
                ),
                Listener(
                  onPointerDown: canCall
                      ? (_) => setState(() => _callPressed = true)
                      : null,
                  onPointerUp: (_) => setState(() => _callPressed = _calling),
                  onPointerCancel: (_) => setState(() => _callPressed = _calling),
                  child: GestureDetector(
                    onTap: canCall ? _call : null,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 90),
                      width: 78,
                      height: 78,
                      decoration: BoxDecoration(
                        color: !canCall
                            ? Colors.white24
                            : callLit
                                ? const Color(0xFF2E7D32)
                                : Colors.white.withValues(alpha: 0.18),
                        shape: BoxShape.circle,
                        boxShadow: callLit
                            ? [
                                BoxShadow(
                                  color: const Color(0xFF2E7D32).withValues(alpha: 0.55),
                                  blurRadius: 22,
                                  offset: const Offset(0, 8),
                                ),
                              ]
                            : null,
                      ),
                      child: Icon(
                        Icons.call,
                        color: callLit ? Colors.white : Colors.white70,
                        size: 32,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 84,
                  height: 84,
                  child: _digits.isEmpty
                      ? null
                      : IconButton(
                          onPressed: _backspace,
                          onLongPress: () => setState(() => _digits = ''),
                          icon: const Icon(Icons.backspace_outlined, color: Colors.white, size: 28),
                        ),
                ),
              ],
            ),
            const SizedBox(height: 28),
          ],
        ),
      ),
    );
  }
}

class _Key extends StatefulWidget {
  final String label;
  final String? subtitle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _Key({
    required this.label,
    required this.onTap,
    this.subtitle,
    this.onLongPress,
  });

  @override
  State<_Key> createState() => _KeyState();
}

class _KeyState extends State<_Key> {
  bool _pressed = false;
  Timer? _linger;

  @override
  void dispose() {
    _linger?.cancel();
    super.dispose();
  }

  void _setPressed(bool value) {
    _linger?.cancel();
    if (!mounted) return;
    setState(() => _pressed = value);
  }

  void _flashOff() {
    _linger?.cancel();
    _linger = Timer(const Duration(milliseconds: 140), () {
      if (mounted) setState(() => _pressed = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final yellow = AppColors.accent;
    return Listener(
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _flashOff(),
      onPointerCancel: (_) => _setPressed(false),
      child: Material(
        color: _pressed ? yellow : Colors.white.withValues(alpha: 0.12),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          splashColor: yellow.withValues(alpha: 0.65),
          highlightColor: yellow,
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          child: SizedBox(
            width: 84,
            height: 84,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.label,
                  style: TextStyle(
                    color: _pressed ? Colors.black : Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (widget.subtitle != null)
                  Text(
                    widget.subtitle!,
                    style: TextStyle(
                      color: _pressed ? Colors.black54 : Colors.white54,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
