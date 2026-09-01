import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';

/// Жёлтый плюс: из него выезжают конверт и SMS.
class ComposeSpeedDial extends StatelessWidget {
  final bool open;
  final VoidCallback onToggle;
  final VoidCallback onSms;
  final VoidCallback onEmail;

  const ComposeSpeedDial({
    super.key,
    required this.open,
    required this.onToggle,
    required this.onSms,
    required this.onEmail,
  });

  static const _boxW = 220.0;
  static const _boxH = 180.0;
  static const _btn = 52.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _boxW,
      height: _boxH,
      child: Stack(
        alignment: Alignment.bottomCenter,
        clipBehavior: Clip.none,
        children: [
          _shot(
            open: open,
            left: 12,
            color: const Color(0xFFEA4335),
            icon: Icons.mail_outline,
            tooltip: 'Email'.tr,
            onTap: onEmail,
          ),
          _shot(
            open: open,
            left: _boxW - 12 - _btn,
            color: const Color(0xFF1E88E5),
            icon: Icons.sms_outlined,
            tooltip: 'SMS'.tr,
            onTap: onSms,
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: 56,
              height: 56,
              child: FloatingActionButton(
                heroTag: 'dock-compose',
                backgroundColor: AppColors.accent,
                foregroundColor: AppColors.primary,
                elevation: 4,
                onPressed: onToggle,
                child: AnimatedRotation(
                  turns: open ? 0.125 : 0,
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOutCubic,
                  child: const Icon(Icons.add, size: 34),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _shot({
    required bool open,
    required double left,
    required Color color,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return AnimatedPositioned(
      duration: Duration(milliseconds: open ? 380 : 220),
      curve: open ? Curves.easeOutCubic : Curves.easeInCubic,
      left: open ? left : (_boxW - _btn) / 2,
      bottom: open ? 92 : 2,
      width: _btn,
      height: _btn,
      child: IgnorePointer(
        ignoring: !open,
        child: AnimatedOpacity(
          opacity: open ? 1 : 0,
          duration: Duration(milliseconds: open ? 220 : 160),
          child: Tooltip(
            message: tooltip,
            child: Material(
              color: color,
              shape: const CircleBorder(),
              elevation: open ? 5 : 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: SizedBox(
                  width: _btn,
                  height: _btn,
                  child: Icon(icon, color: Colors.white, size: 26),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
