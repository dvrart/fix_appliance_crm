import 'package:flutter/material.dart';

import '../../core/l10n/app_locale.dart';
import 'appliance_picture.dart';

class ApplianceLogo extends StatelessWidget {
  final String type;
  final double size;
  final bool onDark;

  const ApplianceLogo({
    super.key,
    required this.type,
    this.size = 40,
    this.onDark = false,
  });

  @override
  Widget build(BuildContext context) {
    return AppliancePicture(
      type: type.isEmpty ? 'Техника'.tr : type,
      size: size,
      onDark: onDark,
    );
  }
}
