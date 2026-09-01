import 'package:flutter/material.dart';

const String kAppLogoAsset = 'assets/branding/app_logo.png';

/// Пульсирующий логотип для сплэша и индикаторов загрузки.
class AnimatedAppLogo extends StatefulWidget {
  final double size;

  const AnimatedAppLogo({super.key, this.size = 160});

  @override
  State<AnimatedAppLogo> createState() => _AnimatedAppLogoState();
}

class _AnimatedAppLogoState extends State<AnimatedAppLogo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  late final Animation<double> _glow;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _scale = Tween<double>(begin: 0.92, end: 1.06).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    _glow = Tween<double>(begin: 0.18, end: 0.55).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.scale(
          scale: _scale.value,
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFFCC520).withValues(alpha: _glow.value),
                  blurRadius: 28,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: child,
          ),
        );
      },
      child: ClipOval(
        child: Image.asset(
          kAppLogoAsset,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

class AppLoading extends StatelessWidget {
  final double size;

  const AppLoading({super.key, this.size = 88});

  @override
  Widget build(BuildContext context) {
    return Center(child: AnimatedAppLogo(size: size));
  }
}
