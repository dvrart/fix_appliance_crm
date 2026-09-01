import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../models/job.dart';
import '../../services/job_service.dart';
import 'parts_queue_screen.dart';

/// Bouncing delivery van in the top-right. Tap opens waiting parts.
class DeliveryVanButton extends StatefulWidget {
  final VoidCallback? onTap;
  final Color color;
  final double iconSize;

  const DeliveryVanButton({
    super.key,
    this.onTap,
    this.color = Colors.white,
    this.iconSize = 28,
  });

  @override
  State<DeliveryVanButton> createState() => _DeliveryVanButtonState();
}

class _DeliveryVanButtonState extends State<DeliveryVanButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Job>>(
      stream: JobService.streamByStatus(JobStatuses.waitingPart),
      builder: (context, snapshot) {
        final jobs = snapshot.data ?? const <Job>[];
        final icon = Badge(
          isLabelVisible: jobs.isNotEmpty,
          backgroundColor: AppColors.accent,
          textColor: Colors.black,
          label: Text('${jobs.length}'),
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final dx = (_controller.value - 0.5) * 10;
              return Transform.translate(
                offset: Offset(dx, 0),
                child: child,
              );
            },
            child: Icon(
              jobs.isEmpty ? Icons.local_shipping_outlined : Icons.local_shipping,
              color: widget.color,
              size: widget.iconSize,
            ),
          ),
        );
        return Tooltip(
          message: 'Ожидаемые запчасти'.tr,
          child: IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 44, minHeight: 40),
            onPressed: () {
              HapticFeedback.selectionClick();
              if (widget.onTap != null) {
                widget.onTap!();
                return;
              }
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PartsQueueScreen()),
              );
            },
            icon: icon,
          ),
        );
      },
    );
  }
}
