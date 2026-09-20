import 'dart:async';

import 'package:flutter/material.dart';

import '../../ai/assistant/assistant_face.dart';
import '../../ai/assistant/voice_test_controller.dart';

/// Full-screen phone-call style dialog for testing a Gemini Live voice.
/// Opens, triggers the AI to greet, and lets the user have a short conversation.
class VoiceTestDialog extends StatefulWidget {
  final String voiceName;

  const VoiceTestDialog({super.key, required this.voiceName});

  /// Push as a full-screen route on [context].
  static Future<void> show(BuildContext context, String voiceName) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => VoiceTestDialog(voiceName: voiceName),
      ),
    );
  }

  @override
  State<VoiceTestDialog> createState() => _VoiceTestDialogState();
}

class _VoiceTestDialogState extends State<VoiceTestDialog>
    with SingleTickerProviderStateMixin {
  late final VoiceTestController _ctrl;
  late final AnimationController _pulse;
  Timer? _callTimer;
  int _elapsed = 0;

  @override
  void initState() {
    super.initState();
    _ctrl = VoiceTestController(widget.voiceName);
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _ctrl.addListener(_onChanged);
    unawaited(_ctrl.open());
  }

  void _onChanged() {
    if (!mounted) return;
    // Start call timer once connected and not connecting.
    if (_ctrl.isOpen && !_ctrl.isConnecting && _callTimer == null) {
      _callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _elapsed++);
      });
    }
    // Animate pulse only when active.
    final animate =
        _ctrl.isSpeaking || (_ctrl.isOpen && !_ctrl.isConnecting);
    if (animate && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!animate && _pulse.isAnimating) {
      _pulse.stop();
    }
    setState(() {});
  }

  String get _timerText {
    final m = (_elapsed ~/ 60).toString().padLeft(2, '0');
    final s = (_elapsed % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  AssistantFaceMood get _mood {
    if (!_ctrl.isOpen) return AssistantFaceMood.idle;
    if (_ctrl.isConnecting) return AssistantFaceMood.connecting;
    if (_ctrl.isSpeaking) return AssistantFaceMood.speaking;
    return AssistantFaceMood.listening;
  }

  Color get _discColor => switch (_mood) {
    AssistantFaceMood.connecting => const Color(0xFFFFE082),
    AssistantFaceMood.speaking => const Color(0xFF4DB6AC),
    AssistantFaceMood.listening => const Color(0xFF64B5F6),
    _ => const Color(0xFF90A4AE),
  };

  Future<void> _hangUp() async {
    _callTimer?.cancel();
    _callTimer = null;
    await _ctrl.close();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _callTimer?.cancel();
    _ctrl.removeListener(_onChanged);
    _ctrl.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disc = _discColor;
    final hasError = (_ctrl.errorText ?? '').isNotEmpty;
    final statusLine = hasError ? _ctrl.errorText! : _ctrl.statusText;

    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 48),
            // Company label
            Text(
              'FixApplianceCA',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 13,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 10),
            // Voice name
            Text(
              widget.voiceName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 34,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(height: 10),
            // Timer or "Connecting..."
            Text(
              _ctrl.isConnecting ? 'Connecting...' : _timerText,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 16,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const Spacer(),
            // Animated face circle
            AnimatedBuilder(
              animation: _pulse,
              builder: (ctx, child) {
                final active =
                    _ctrl.isOpen && !_ctrl.isConnecting;
                final scale = active ? 1.0 + _pulse.value * 0.07 : 1.0;
                return Transform.scale(scale: scale, child: child);
              },
              child: Container(
                width: 180,
                height: 180,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: disc.withValues(alpha: 0.12),
                  border: Border.all(color: disc, width: 2.5),
                  boxShadow: [
                    BoxShadow(
                      color: disc.withValues(alpha: 0.35),
                      blurRadius: 36,
                      spreadRadius: 10,
                    ),
                  ],
                ),
                child: LivingAssistantFace(size: 180, mood: _mood),
              ),
            ),
            const SizedBox(height: 28),
            // Status / error line
            if (statusLine.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  statusLine,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: hasError
                        ? Colors.orangeAccent
                        : Colors.white.withValues(alpha: 0.55),
                    fontSize: 14,
                  ),
                ),
              ),
            // Prompt: ask user to speak first
            if (_ctrl.isOpen &&
                !_ctrl.isConnecting &&
                !_ctrl.isSpeaking &&
                _ctrl.inputTranscript.isEmpty) ...[
              const SizedBox(height: 12),
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 32),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.15),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.mic,
                      size: 16,
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Say "Hello" to start',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // User speech transcript (italic, smaller)
            if (_ctrl.inputTranscript.isNotEmpty) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  '"${_ctrl.inputTranscript}"',
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
            const Spacer(),
            // Hang-up button
            GestureDetector(
              onTap: _hangUp,
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: const Color(0xFFE53935),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFE53935).withValues(alpha: 0.5),
                      blurRadius: 20,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: const Icon(Icons.call_end, color: Colors.white, size: 32),
              ),
            ),
            const SizedBox(height: 56),
          ],
        ),
      ),
    );
  }
}
