import 'package:flutter/material.dart';

import '../../core/app_commands.dart';
import '../../core/constants.dart';
import '../../core/ui_scale.dart';
import '../../core/l10n/app_locale.dart';
import '../../models/models.dart';
import '../../services/services.dart';
import '../../features/ai/assistant/assistant_host.dart';
import '../../features/warehouse/warehouse_screen.dart';
import '../../features/jobs/basket_screen.dart';
import '../../features/jobs/active_jobs_screen.dart';
import '../../features/jobs/parts_queue_screen.dart';
import '../../features/reports/reports_screen.dart';
import '../../features/reports/statistics_screen.dart';
import '../../features/expenses/expenses_screen.dart';
import '../../features/finance/documents_list_screen.dart';
import '../../features/search/global_search_overlay.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/settings/widgets/company_logo.dart';
import '../unsaved_navigation_gate.dart';

class CustomDrawer extends StatelessWidget {
  const CustomDrawer({super.key});

  void _openSettings(BuildContext context) async {
    if (!await UnsavedNavigationGate.allowLeave(host: context)) return;
    if (!context.mounted) return;
    Navigator.pop(context);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  void _open(BuildContext context, Widget page) async {
    if (!await UnsavedNavigationGate.allowLeave(host: context)) return;
    if (!context.mounted) return;
    Navigator.pop(context);
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  void _openSearch(BuildContext context) async {
    if (!await UnsavedNavigationGate.allowLeave(host: context)) return;
    if (!context.mounted) return;
    Navigator.pop(context);
    final overlayContext = rootNavigatorKey.currentContext;
    if (overlayContext != null && overlayContext.mounted) {
      await GlobalSearchOverlay.open(overlayContext);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppUiSettings.instance,
      builder: (context, _) {
        return Drawer(
          backgroundColor: Colors.grey.shade100,
          child: Column(
            children: [
              StreamBuilder<DocumentSettings>(
                stream: SettingsService.watchDocumentSettings(),
                builder: (context, snapshot) {
                  final docs = snapshot.data;
                  final name = docs?.companyName ?? 'Fix Appliance';
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.only(
                      top: 60,
                      bottom: 20,
                      left: 20,
                      right: 20,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.only(
                        bottomRight: Radius.circular(30),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CompanyLogo(
                              url: docs?.logoUrl,
                              size: 64,
                              onTap: () => _openSettings(context),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: GestureDetector(
                                onTap: () => _openSettings(context),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      name,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 19,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Text(
                                      context.tr(
                                        'Нажмите логотип — настройки',
                                        'Tap the logo for settings',
                                      ),
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        _buildQuickStats(context),
                      ],
                    ),
                  );
                },
              ),
              Expanded(
                child: StreamBuilder<Map<String, dynamic>>(
                  stream: SettingsService.watchConfig(),
                  builder: (context, snapshot) {
                    final config = snapshot.data ?? <String, dynamic>{};
                    final tiles = <Widget>[
                      if (SettingsService.menuFlag(config, 'menuShowAi'))
                        _buildTile(
                          context,
                          title: context.tr('Ассистент', 'Assistant'),
                          icon: Icons.mic,
                          color: Colors.deepPurple,
                          onTap: () async {
                            if (!await UnsavedNavigationGate.allowLeave(
                              host: context,
                            ))
                              return;
                            if (!context.mounted) return;
                            final open = AssistantHost.opener(context);
                            Navigator.pop(context);
                            open?.call();
                          },
                        ),
                      if (SettingsService.menuFlag(config, 'menuShowWarehouse'))
                        _buildTile(
                          context,
                          title: context.tr('Склад', 'Warehouse'),
                          icon: Icons.inventory_2_outlined,
                          color: Colors.orange,
                          onTap: () => _open(context, const WarehouseScreen()),
                        ),
                      if (SettingsService.menuFlag(
                        config,
                        'menuShowStatistics',
                      ))
                        _buildTile(
                          context,
                          title: context.tr('Статистика', 'Statistics'),
                          icon: Icons.query_stats,
                          color: const Color(0xFF1565C0),
                          onTap: () => _open(context, const StatisticsScreen()),
                        ),
                      if (SettingsService.menuFlag(config, 'menuShowReports'))
                        _buildTile(
                          context,
                          title: context.tr('Отчеты', 'Reports'),
                          icon: Icons.bar_chart,
                          color: Colors.green,
                          onTap: () => _open(context, const ReportsScreen()),
                        ),
                      if (SettingsService.menuFlag(config, 'menuShowExpenses'))
                        _buildTile(
                          context,
                          title: context.tr('Расходы', 'Expenses'),
                          icon: Icons.receipt_long_outlined,
                          color: Colors.deepOrange,
                          onTap: () => _open(context, const ExpensesScreen()),
                        ),
                      if (SettingsService.menuFlag(
                            config,
                            'menuShowInvoices',
                          ) ||
                          SettingsService.menuFlag(config, 'menuShowEstimates'))
                        _buildTile(
                          context,
                          title: context.tr('Счета', 'Invoices'),
                          icon: Icons.receipt_long,
                          color: Colors.teal,
                          onTap: () =>
                              _open(context, const DocumentsListScreen()),
                        ),
                      _buildTile(
                        context,
                        title: context.tr('Настройки', 'Settings'),
                        icon: Icons.settings_outlined,
                        color: Colors.grey.shade700,
                        onTap: () => _openSettings(context),
                      ),
                    ];

                    return Column(
                      children: [
                        Expanded(
                          child: GridView.count(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                            crossAxisCount: 2,
                            crossAxisSpacing: 16,
                            mainAxisSpacing: 16,
                            childAspectRatio: 1,
                            children: tiles,
                          ),
                        ),
                        SafeArea(
                          top: false,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                            child: Row(
                              children: [
                                if (SettingsService.menuFlag(
                                  config,
                                  'menuShowTrash',
                                ))
                                  _buildFooterTile(
                                    context,
                                    color: const Color(0xFFE53935),
                                    icon: Icons.delete_outline,
                                    title: context.tr('Корзина', 'Trash'),
                                    onTap: () =>
                                        _open(context, const BasketScreen()),
                                  ),
                                if (SettingsService.menuFlag(
                                  config,
                                  'menuShowTrash',
                                ))
                                  const Spacer(),
                                _buildFooterTile(
                                  context,
                                  color: const Color(0xFF6A1B9A),
                                  iconWidget: const _AmazonParcelIcon(size: 28),
                                  title: context.tr('Запчасти', 'Parts'),
                                  onTap: () =>
                                      _open(context, const PartsQueueScreen()),
                                ),
                                const Spacer(),
                                _buildFooterTile(
                                  context,
                                  color: AppColors.primary,
                                  icon: Icons.search,
                                  title: context.tr('Поиск', 'Search'),
                                  onTap: () => _openSearch(context),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildQuickStats(BuildContext context) {
    return StreamBuilder<List<Job>>(
      stream: JobService.streamAll(),
      builder: (context, snapshot) {
        final jobs = snapshot.data ?? [];
        final now = DateTime.now();

        final todayCount = jobs.where((j) => j.hasVisitOn(now)).length;

        final activeCount = jobs
            .where((j) => !JobStatuses.isClosed(j.status))
            .length;

        return Row(
          children: [
            Expanded(
              child: _statChip(
                icon: Icons.calendar_today,
                label: context.tr('Сегодня', 'Today'),
                value: todayCount,
                onTap: () => _open(context, ActiveJobsScreen.today()),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _statChip(
                icon: Icons.build_circle_outlined,
                label: context.tr('Активные', 'Active'),
                value: activeCount,
                onTap: () => _open(context, const ActiveJobsScreen()),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _statChip({
    required IconData icon,
    required String label,
    required int value,
    VoidCallback? onTap,
  }) {
    final body = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppColors.accent, size: 20),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$value',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  height: 1.1,
                ),
              ),
              Text(
                label,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
    if (onTap == null) return body;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: body,
      ),
    );
  }

  Widget _buildFooterTile(
    BuildContext context, {
    required Color color,
    IconData? icon,
    Widget? iconWidget,
    required String title,
    required VoidCallback onTap,
  }) {
    assert(icon != null || iconWidget != null);
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(14),
      elevation: 2,
      shadowColor: Colors.black26,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 72,
          height: 72,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              iconWidget ?? Icon(icon, color: Colors.white, size: 26),
              const SizedBox(height: 4),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 10,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTile(
    BuildContext context, {
    required String title,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      elevation: 2,
      shadowColor: Colors.black12,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 36),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14,
                color: Colors.black87,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Kraft shipping parcel (Amazon-style box, no brand mark / smile / text).
class _AmazonParcelIcon extends StatelessWidget {
  final double size;

  const _AmazonParcelIcon({this.size = 28});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _AmazonParcelPainter()),
    );
  }
}

class _AmazonParcelPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Isometric-ish closed kraft box.
    final topY = h * 0.18;
    final midY = h * 0.38;
    final bottomY = h * 0.92;
    final leftX = w * 0.08;
    final rightX = w * 0.92;
    final cx = w * 0.50;

    final kraft = Paint()..color = const Color(0xFFD2A66A);
    final kraftDark = Paint()..color = const Color(0xFFB88445);
    final kraftDeep = Paint()..color = const Color(0xFF9A6B35);
    final edge = Paint()
      ..color = const Color(0xFF6E4A22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.035
      ..strokeJoin = StrokeJoin.round;

    // Left face
    final left = Path()
      ..moveTo(leftX, midY)
      ..lineTo(cx, bottomY * 0.55)
      ..lineTo(cx, bottomY)
      ..lineTo(leftX, h * 0.72)
      ..close();
    canvas.drawPath(left, kraftDark);

    // Right face
    final right = Path()
      ..moveTo(rightX, midY)
      ..lineTo(cx, bottomY * 0.55)
      ..lineTo(cx, bottomY)
      ..lineTo(rightX, h * 0.72)
      ..close();
    canvas.drawPath(right, kraftDeep);

    // Top lid
    final top = Path()
      ..moveTo(cx, topY)
      ..lineTo(rightX, midY)
      ..lineTo(cx, bottomY * 0.55)
      ..lineTo(leftX, midY)
      ..close();
    canvas.drawPath(top, kraft);

    canvas.drawPath(left, edge);
    canvas.drawPath(right, edge);
    canvas.drawPath(top, edge);

    // Center flap seam on the lid
    final seam = Paint()
      ..color = const Color(0xFF8A5E2E)
      ..strokeWidth = w * 0.028
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(cx, topY + h * 0.02), Offset(cx, bottomY * 0.55), seam);

    // Packing tape across the lid (no smile / brand)
    final tape = Paint()..color = const Color(0xFF2B2B2B);
    final tapePath = Path()
      ..moveTo(leftX + w * 0.06, midY - h * 0.02)
      ..lineTo(cx, topY + h * 0.14)
      ..lineTo(rightX - w * 0.06, midY - h * 0.02)
      ..lineTo(rightX - w * 0.10, midY + h * 0.06)
      ..lineTo(cx, topY + h * 0.24)
      ..lineTo(leftX + w * 0.10, midY + h * 0.06)
      ..close();
    canvas.drawPath(tapePath, tape);

    // Small blank shipping label on the right face
    final label = RRect.fromRectAndRadius(
      Rect.fromLTWH(cx + w * 0.06, h * 0.58, w * 0.22, h * 0.14),
      Radius.circular(w * 0.02),
    );
    canvas.drawRRect(label, Paint()..color = const Color(0xFFF5F0E6));
    canvas.drawRRect(
      label,
      Paint()
        ..color = const Color(0xFF6E4A22)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.02,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
