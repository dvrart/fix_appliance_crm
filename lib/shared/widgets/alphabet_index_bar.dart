import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Правый индекс букв: свайп листает список, выбранная буква крупнее
/// и сдвинута в список, чтобы её было видно из-под пальца.
class AlphabetIndexBar extends StatefulWidget {
  final List<String> letters;
  final ValueChanged<String> onLetter;

  const AlphabetIndexBar({
    super.key,
    required this.letters,
    required this.onLetter,
  });

  @override
  State<AlphabetIndexBar> createState() => _AlphabetIndexBarState();
}

class _AlphabetIndexBarState extends State<AlphabetIndexBar> {
  String? _active;
  double _barScale = 1.0;
  int? _pinchId1;
  int? _pinchId2;
  Offset? _pinchP1;
  Offset? _pinchP2;
  double? _pinchStartDistance;
  double? _pinchStartScale;
  double _activeY = 0;

  void _selectAt(Offset local, double height) {
    if (widget.letters.isEmpty || height <= 0) return;
    final t = (local.dy / height).clamp(0.0, 0.999);
    final index = (t * widget.letters.length).floor();
    final letter = widget.letters[index];
    final y = (index + 0.5) * (height / widget.letters.length);
    if (letter == _active) {
      _activeY = y;
      return;
    }
    HapticFeedback.selectionClick();
    setState(() {
      _active = letter;
      _activeY = y;
    });
    widget.onLetter(letter);
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_pinchId1 == null) {
      _pinchId1 = event.pointer;
      _pinchP1 = event.position;
    } else if (_pinchId2 == null) {
      _pinchId2 = event.pointer;
      _pinchP2 = event.position;
      _pinchStartDistance = (_pinchP1! - _pinchP2!).distance;
      _pinchStartScale = _barScale;
    }
  }

  void _onPointerMove(PointerMoveEvent event, double height) {
    if (event.pointer == _pinchId1) _pinchP1 = event.position;
    if (event.pointer == _pinchId2) _pinchP2 = event.position;
    if (_pinchId1 != null &&
        _pinchId2 != null &&
        _pinchStartDistance != null &&
        _pinchStartDistance! > 8 &&
        _pinchStartScale != null) {
      final scale = (_pinchP1! - _pinchP2!).distance / _pinchStartDistance!;
      final next = (_pinchStartScale! * scale).clamp(1.0, 2.2);
      if ((next - _barScale).abs() > 0.02) {
        setState(() => _barScale = next);
      }
      return;
    }
    _selectAt(event.localPosition, height);
  }

  void _onPointerUp(PointerEvent event) {
    if (event.pointer == _pinchId1) {
      _pinchId1 = _pinchId2;
      _pinchP1 = _pinchP2;
      _pinchId2 = null;
      _pinchP2 = null;
    } else if (event.pointer == _pinchId2) {
      _pinchId2 = null;
      _pinchP2 = null;
    }
    _pinchStartDistance = null;
    _pinchStartScale = null;
    if (_pinchId1 == null) {
      setState(() => _active = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.letters.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final fontSize = (11.0 * _barScale).clamp(11.0, 18.0);
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            _onPointerDown(event);
            _selectAt(event.localPosition, height);
          },
          onPointerMove: (event) => _onPointerMove(event, height),
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerUp,
          child: SizedBox(
            width: 44,
            height: height,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Column(
                  children: [
                    for (var i = 0; i < widget.letters.length; i++)
                      Expanded(
                        child: Center(
                          child: AnimatedScale(
                            scale: widget.letters[i] == _active ? 2.7 : 1.0,
                            duration: const Duration(milliseconds: 80),
                            child: Transform.translate(
                              offset: widget.letters[i] == _active
                                  ? const Offset(-22, 0)
                                  : Offset.zero,
                              child: Text(
                                widget.letters[i],
                                style: TextStyle(
                                  color: widget.letters[i] == _active
                                      ? const Color(0xFF0D47A1)
                                      : const Color(0xFF14557F),
                                  fontWeight: FontWeight.w800,
                                  fontSize: widget.letters[i] == _active
                                      ? 22
                                      : fontSize,
                                  height: 1,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                if (_active != null)
                  Positioned(
                    right: 56,
                    top: (_activeY - 40).clamp(0.0, height - 80),
                    child: IgnorePointer(
                      child: _LetterBubble(letter: _active!, scale: _barScale),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LetterBubble extends StatelessWidget {
  final String letter;
  final double scale;

  const _LetterBubble({required this.letter, required this.scale});

  @override
  Widget build(BuildContext context) {
    final size = (80.0 * scale.clamp(1.0, 1.5)).clamp(80.0, 108.0);
    return Material(
      color: const Color(0xFF14557F),
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Text(
            letter,
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: size * 0.52,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
