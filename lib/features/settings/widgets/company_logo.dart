import 'package:flutter/material.dart';

import '../../../shared/widgets/animated_app_logo.dart';

class CompanyLogo extends StatelessWidget {
  final String? url;
  final double size;
  final VoidCallback? onTap;

  const CompanyLogo({
    super.key,
    this.url,
    this.size = 56,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final network = url?.trim() ?? '';
    final avatar = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2)),
        ],
        image: DecorationImage(
          image: network.isNotEmpty
              ? NetworkImage(network)
              : const AssetImage(kAppLogoAsset) as ImageProvider,
          fit: BoxFit.cover,
        ),
      ),
    );

    if (onTap == null) return avatar;
    return GestureDetector(
      onTap: onTap,
      child: avatar,
    );
  }
}
