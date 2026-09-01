import 'package:flutter/material.dart';

import '../../core/app_feedback.dart';
import '../../core/constants.dart';

/// Folder-tab “cornice”: same color as the dock, merged into the bar.
/// On tap it grows upward out of the bar, then settles back.
class DockFolderTab extends StatefulWidget {
  static const restTall = 32.0;
  static const stem = 12.0;
  static const extra = 16.0;

  final Widget child;
  final String tooltip;
  final bool slantRight;
  final double width;
  final Future<void> Function() onOpen;

  const DockFolderTab({
    super.key,
    required this.child,
    required this.tooltip,
    required this.onOpen,
    this.slantRight = true,
    this.width = 54,
  });

  @override
  State<DockFolderTab> createState() => _DockFolderTabState();
}

class _DockFolderTabState extends State<DockFolderTab>
    with SingleTickerProviderStateMixin {
  late final AnimationController _out;

  @override
  void initState() {
    super.initState();
    _out = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
      reverseDuration: const Duration(milliseconds: 220),
    );
  }

  @override
  void dispose() {
    _out.dispose();
    super.dispose();
  }

  Future<void> _tap() async {
    if (_out.status == AnimationStatus.forward ||
        _out.status == AnimationStatus.completed) {
      return;
    }
    AppFeedback.pleasant();
    await _out.forward();
    try {
      await widget.onOpen();
    } finally {
      if (mounted) await _out.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(
      parent: _out,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return Tooltip(
      message: widget.tooltip,
      child: AnimatedBuilder(
        animation: curve,
        builder: (context, child) {
          final extra = DockFolderTab.extra * curve.value;
          return SizedBox(
            width: widget.width,
            height: DockFolderTab.restTall + DockFolderTab.stem + extra,
            child: child,
          );
        },
        child: ClipPath(
          clipper: _FolderTabClipper(slantRight: widget.slantRight),
          child: Material(
            color: AppColors.primary,
            child: InkWell(
              onTap: _tap,
              splashColor: Colors.white24,
              highlightColor: Colors.white10,
              child: Padding(
                padding: const EdgeInsets.only(bottom: DockFolderTab.stem),
                child: Center(child: widget.child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FolderTabClipper extends CustomClipper<Path> {
  final bool slantRight;

  const _FolderTabClipper({required this.slantRight});

  @override
  Path getClip(Size size) => folderTabPath(size, slantRight: slantRight);

  @override
  bool shouldReclip(_FolderTabClipper oldClipper) {
    return oldClipper.slantRight != slantRight;
  }
}

Path folderTabPath(Size size, {required bool slantRight}) {
  const radius = 12.0;
  const slant = 15.0;
  const stem = DockFolderTab.stem;
  final w = size.width;
  final h = size.height;
  final joinY = (h - stem).clamp(radius + 4, h);
  final path = Path();
  if (slantRight) {
    path.moveTo(0, h);
    path.lineTo(0, radius);
    path.quadraticBezierTo(0, 0, radius, 0);
    path.lineTo(w - slant - 2, 0);
    path.quadraticBezierTo(w - slant + 10, 2, w, joinY);
    path.lineTo(w, h);
  } else {
    path.moveTo(w, h);
    path.lineTo(w, radius);
    path.quadraticBezierTo(w, 0, w - radius, 0);
    path.lineTo(slant + 2, 0);
    path.quadraticBezierTo(slant - 10, 2, 0, joinY);
    path.lineTo(0, h);
  }
  path.close();
  return path;
}
