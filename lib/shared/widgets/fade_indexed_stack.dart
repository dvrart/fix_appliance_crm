import 'package:flutter/material.dart';

/// Как [IndexedStack], но скрытые вкладки не перекрывают видимую.
/// Исходящая вкладка остаётся на экране до конца fade — иначе анимация
/// срабатывает один раз и дальше прыгает без перехода.
class FadeIndexedStack extends StatefulWidget {
  final int index;
  final List<Widget> children;
  final Duration duration;

  const FadeIndexedStack({
    super.key,
    required this.index,
    required this.children,
    this.duration = const Duration(milliseconds: 300),
  });

  @override
  State<FadeIndexedStack> createState() => _FadeIndexedStackState();
}

class _FadeIndexedStackState extends State<FadeIndexedStack> {
  late int _index;
  int? _outgoing;

  @override
  void initState() {
    super.initState();
    _index = widget.index;
  }

  @override
  void didUpdateWidget(FadeIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index == widget.index) return;
    _outgoing = _index;
    _index = widget.index;
  }

  void _onFadeEnd(int i) {
    if (!mounted || i != _outgoing) return;
    setState(() => _outgoing = null);
  }

  bool _onStage(int i) => i == _index || i == _outgoing;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          Offstage(
            offstage: !_onStage(i),
            child: TickerMode(
              enabled: _onStage(i),
              child: IgnorePointer(
                ignoring: i != _index,
                child: AnimatedOpacity(
                  opacity: i == _index ? 1 : 0,
                  duration: widget.duration,
                  curve: Curves.easeOutCubic,
                  onEnd: () => _onFadeEnd(i),
                  child: widget.children[i],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
