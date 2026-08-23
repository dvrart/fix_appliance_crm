import 'package:flutter/material.dart';

import 'animated_app_logo.dart';

/// Смайлик ИИ в шапке. Нажатие включает слух на месте, без нового окна.
class AiHead extends StatelessWidget {
  final double size;

  const AiHead({super.key, this.size = 32});

  @override
  Widget build(BuildContext context) {
    return AnimatedAppLogo(size: size);
  }
}
