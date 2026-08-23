import 'package:flutter/material.dart';

import '../../core/haptics.dart';

/// Узкий ярлычок у края экрана — меню слева, уведомления справа.
class EdgePeekButton extends StatelessWidget {
  final Alignment alignment;
  final IconData icon;
  final String tooltip;
  final Color color;
  final Color iconColor;
  final VoidCallback onTap;
  final int badgeCount;

  const EdgePeekButton({
    super.key,
    required this.alignment,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color = const Color(0xFF14557F),
    this.iconColor = const Color(0xFFFCC520),
    this.badgeCount = 0,
  });

  bool get _fromLeft => alignment == Alignment.centerLeft;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.only(
      topLeft: _fromLeft ? Radius.zero : const Radius.circular(14),
      bottomLeft: _fromLeft ? Radius.zero : const Radius.circular(14),
      topRight: _fromLeft ? const Radius.circular(14) : Radius.zero,
      bottomRight: _fromLeft ? const Radius.circular(14) : Radius.zero,
    );

    return Tooltip(
      message: tooltip,
      child: Material(
        color: color,
        elevation: 3,
        shadowColor: Colors.black26,
        borderRadius: radius,
        child: InkWell(
          onTap: () {
            AppHaptics.button();
            onTap();
          },
          borderRadius: radius,
          child: SizedBox(
            width: 20,
            height: 52,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Center(
                  child: Icon(icon, size: 16, color: iconColor),
                ),
                if (badgeCount > 0)
                  Positioned(
                    top: 4,
                    right: _fromLeft ? 2 : null,
                    left: _fromLeft ? null : 2,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Color(0xFFFF9800),
                        shape: BoxShape.circle,
                      ),
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
