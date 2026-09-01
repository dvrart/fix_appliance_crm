import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_feedback.dart';
import '../../core/constants.dart';
import 'call_screen.dart';
import '../../core/l10n/app_locale.dart';

/// Клавиатура для набора номера и исходящего звонка через Twilio.
class DialPadScreen extends StatefulWidget {
  const DialPadScreen({super.key});

  static Future<void> open(BuildContext context) {
    AppFeedback.pleasant();
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(builder: (_) => const DialPadScreen()),
    );
  }

  @override
  State<DialPadScreen> createState() => _DialPadScreenState();
}

class _DialPadScreenState extends State<DialPadScreen> {
  static const _callGreen = Color(0xFF25D366);

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
    if (_calling) return;
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
            const Spacer(flex: 3),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
              child: Row(
                children: [
                  Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: canCall && !_calling ? (_) => _call() : null,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 320),
                      curve: Curves.easeOutCubic,
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: !canCall
                            ? Colors.white24
                            : callLit
                                ? const Color(0xFF1DB954)
                                : _callGreen,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.call,
                        color: canCall ? Colors.white : const Color(0xFFB9F6CA),
                        size: 24,
                      ),
                    ),
                  ),
                  Expanded(
                    child: GestureDetector(
                      onTap: _paste,
                      onLongPress: _paste,
                      onDoubleTap: _paste,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        child: Text(
                          _display.isEmpty ? 'Вставить номер'.tr : _display,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _display.isEmpty ? Colors.white54 : Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                            height: 1.1,
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 56,
                    height: 56,
                    child: _digits.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Стереть'.tr,
                            onPressed: _backspace,
                            onLongPress: () => setState(() => _digits = ''),
                            icon: const Icon(
                              Icons.backspace_outlined,
                              color: Colors.white,
                              size: 24,
                            ),
                          ),
                  ),
                ],
              ),
            ),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                  child: Column(
                    children: [
                      for (final row in const [
                        ['1', '2', '3'],
                        ['4', '5', '6'],
                        ['7', '8', '9'],
                        ['*', '0', '#'],
                      ])
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              for (var i = 0; i < row.length; i++) ...[
                                if (i > 0) const SizedBox(width: 8),
                                Expanded(
                                  child: _Key(
                                    label: row[i],
                                    onTap: () => _append(row[i]),
                                    onLongPress:
                                        row[i] == '0' ? () => _append('+') : null,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

class _Key extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _Key({
    required this.label,
    required this.onTap,
    this.onLongPress,
  });

  @override
  State<_Key> createState() => _KeyState();
}

class _KeyState extends State<_Key> with SingleTickerProviderStateMixin {
  late final AnimationController _glow;

  @override
  void initState() {
    super.initState();
    _glow = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 780),
    );
  }

  @override
  void dispose() {
    _glow.dispose();
    super.dispose();
  }

  void _light() {
    _glow
      ..stop()
      ..value = 1;
  }

  void _fadeOut() {
    _glow.animateTo(
      0,
      duration: const Duration(milliseconds: 780),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final yellow = AppColors.accent;
    const idle = Color(0x1FFFFFFF);
    const shape = StadiumBorder();
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) {
        _light();
        if (widget.onLongPress == null) widget.onTap();
      },
      onPointerUp: (_) => _fadeOut(),
      onPointerCancel: (_) => _fadeOut(),
      child: AnimatedBuilder(
        animation: _glow,
        builder: (context, _) {
          final t = _glow.value;
          return Material(
            color: Color.lerp(idle, yellow, t),
            shape: shape,
            child: InkWell(
              customBorder: shape,
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
              onTap: widget.onLongPress == null ? () {} : widget.onTap,
              onLongPress: widget.onLongPress,
              child: SizedBox(
                height: 48,
                child: Center(
                  child: Text(
                    widget.label,
                    style: TextStyle(
                      color: Color.lerp(Colors.white, Colors.black, t),
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
