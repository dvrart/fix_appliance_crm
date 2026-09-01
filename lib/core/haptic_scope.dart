import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'app_feedback.dart';

/// Vibration only on real controls (buttons, chips, tabs), not every tap.
class AppHapticScope extends StatefulWidget {
  final Widget child;

  const AppHapticScope({super.key, required this.child});

  @override
  State<AppHapticScope> createState() => _AppHapticScopeState();
}

class _AppHapticScopeState extends State<AppHapticScope> {
  int? _pointer;
  Offset? _down;
  int _viewId = 0;

  static const _tapSlop = 28.0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerUp: _onUp,
      onPointerCancel: _onCancel,
      child: widget.child,
    );
  }

  void _onDown(PointerDownEvent event) {
    if (!_isFinger(event)) return;
    _pointer = event.pointer;
    _down = event.position;
    _viewId = event.viewId;
  }

  void _onUp(PointerUpEvent event) {
    if (event.pointer != _pointer || _down == null) return;
    final delta = event.position - _down!;
    final down = _down!;
    final viewId = _viewId;
    _clear();
    if (!_isFinger(event)) return;
    if (delta.distance > _tapSlop) return;
    if (_isTypingField(down, viewId)) return;
    if (!_isControl(down, viewId)) return;
    AppFeedback.pleasant();
  }

  void _onCancel(PointerCancelEvent event) {
    if (event.pointer == _pointer) _clear();
  }

  void _clear() {
    _pointer = null;
    _down = null;
  }

  bool _isFinger(PointerEvent event) {
    return event.kind == PointerDeviceKind.touch ||
        event.kind == PointerDeviceKind.stylus;
  }

  bool _isTypingField(Offset position, int viewId) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, position, viewId);
    for (final entry in result.path) {
      if (entry.target is RenderEditable) return true;
    }
    return false;
  }

  bool _isControl(Offset position, int viewId) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, position, viewId);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is! RenderObject) continue;
      final creator = target.debugCreator;
      if (creator is! DebugCreator) continue;
      if (_widgetIsControl(creator.element.widget)) return true;
    }
    return false;
  }

  bool _widgetIsControl(Widget widget) {
    if (widget is ButtonStyleButton ||
        widget is IconButton ||
        widget is FloatingActionButton ||
        widget is InkWell ||
        widget is InkResponse ||
        widget is ListTile ||
        widget is Switch ||
        widget is SwitchListTile ||
        widget is Checkbox ||
        widget is DropdownButton ||
        widget is SegmentedButton ||
        widget is Tab ||
        widget is CloseButton ||
        widget is BackButton ||
        widget is DrawerButton ||
        widget is PopupMenuButton) {
      return true;
    }
    if (widget is GestureDetector) return widget.onTap != null;
    return false;
  }
}
