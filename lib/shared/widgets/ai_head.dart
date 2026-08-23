import 'package:flutter/material.dart';

/// Компактная «голова» ИИ для верхней панели — без лишних отступов.
class AiHead extends StatelessWidget {
  final double size;

  const AiHead({super.key, this.size = 32});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CircleAvatar(
        backgroundColor: const Color(0xFFFCC520),
        child: Icon(
          Icons.smart_toy,
          size: size * 0.58,
          color: const Color(0xFF14557F),
        ),
      ),
    );
  }
}
