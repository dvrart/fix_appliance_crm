import 'package:flutter/material.dart';

import '../../../core/app_commands.dart';
import 'assistant_controller.dart';
import 'assistant_face.dart';

class AssistantOverlay extends StatefulWidget {
  final AssistantController controller;
  final VoidCallback onClose;

  const AssistantOverlay({
    super.key,
    required this.controller,
    required this.onClose,
  });

  @override
  State<AssistantOverlay> createState() => _AssistantOverlayState();
}

class _AssistantOverlayState extends State<AssistantOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    widget.controller.addListener(_onChanged);
    AppCommands.angryFaceTick.addListener(_onChanged);
  }

  @override
  void dispose() {
    AppCommands.angryFaceTick.removeListener(_onChanged);
    widget.controller.removeListener(_onChanged);
    _pulse.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    final ctrl = widget.controller;
    if (ctrl.isPaused || ctrl.isConnecting) {
      _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final listening = ctrl.isOpen && !ctrl.isPaused && !ctrl.isConnecting;
    final mood = assistantMoodOf(ctrl);
    final disc = facePoseNow(mood).color;
    final faceSize = ctrl.isConnecting ? 168.0 : 220.0;
    final bottomPad = MediaQuery.paddingOf(context).bottom + 84;
    final middleText = (ctrl.errorText ?? '').trim().isNotEmpty
        ? ctrl.errorText!
        : ctrl.transcript.trim();

    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onClose,
              child: Container(color: Colors.black.withValues(alpha: 0.55)),
            ),
          ),
          if (middleText.isNotEmpty)
            Align(
              alignment: Alignment.center,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  middleText,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: ctrl.errorText != null
                        ? Colors.orangeAccent
                        : Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
              ),
            ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(bottom: bottomPad),
              child: GestureDetector(
                onTap: ctrl.isConnecting ? null : ctrl.togglePause,
                child: AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, child) {
                    final scale = listening ? 1.0 + (_pulse.value * 0.08) : 1.0;
                    return Transform.scale(scale: scale, child: child);
                  },
                  child: Container(
                    width: faceSize + 10,
                    height: faceSize + 10,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: disc,
                      boxShadow: [
                        BoxShadow(
                          color: disc.withValues(alpha: 0.55),
                          blurRadius: 28,
                          spreadRadius: 8,
                        ),
                      ],
                    ),
                    child: LivingAssistantFace(
                      size: faceSize,
                      mood: mood,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
