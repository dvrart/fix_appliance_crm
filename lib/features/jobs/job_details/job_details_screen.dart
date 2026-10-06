import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/app_feedback.dart';
import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../models/client.dart';
import '../../../services/services.dart';
import '../../clients/client_details_screen.dart';
import '../../../shared/widgets/confirm_action_sheet.dart';
import '../../../shared/widgets/unsaved_changes_dialog.dart';
import '../../../shared/stale_routes.dart';
import '../../../shared/unsaved_navigation_gate.dart';
import 'job_details_controller.dart';
import 'tabs/details_tab.dart';
import 'tabs/finance_tab.dart';
import 'tabs/chat_tab.dart';
import '../../../services/error_log_service.dart';

class JobDetailsScreen extends StatefulWidget {
  final String jobId;
  final String clientId;
  final Map<String, dynamic> jobData;
  final int initialTab;
  final int? openDocumentIndex;

  const JobDetailsScreen({
    super.key,
    required this.jobId,
    required this.clientId,
    required this.jobData,
    this.initialTab = 0,
    this.openDocumentIndex,
  });

  @override
  State<JobDetailsScreen> createState() => _JobDetailsScreenState();
}

class _JobDetailsScreenState extends State<JobDetailsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late JobDetailsController _controller;

  @override
  void initState() {
    super.initState();
    ErrorLogService.markScreen('Карточка заявки');
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 2),
      animationDuration: const Duration(milliseconds: 520),
    );
    _controller = JobDetailsController(
      jobId: widget.jobId,
      clientId: widget.clientId,
      jobData: widget.jobData,
    );
    UnsavedNavigationGate.push(_allowNavigateAway);
    StaleRoutes.watchJob(widget.jobId, this);

    if (widget.openDocumentIndex != null) {
      _controller.setViewingDocumentIndex(widget.openDocumentIndex);
      _controller.setFinanceMode('view_document');
    }

    _controller.addListener(_onControllerChanged);

    var tabIndex = _tabController.index;
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging && _tabController.index != tabIndex) {
        tabIndex = _tabController.index;
        if (mounted) setState(() {});
      }
      if (_controller.financeMode == 'builder') return;
      if (_tabController.index != 1 && _controller.financeMode != 'main') {
        _controller.setFinanceMode('main');
      }
    });
  }

  void _onControllerChanged() {
    if (!_controller.financeTabRequested) return;
    _controller.consumeFinanceTabRequest();
    if (_tabController.index != 1) {
      _tabController.animateTo(1);
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    UnsavedNavigationGate.pop(_allowNavigateAway);
    StaleRoutes.unwatchJob(widget.jobId, this);
    _tabController.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _deleteJob() async {
    final confirm = await showConfirmCancelSheet(
      context,
      title: 'Удалить заявку?'.tr,
      message:
          'Заявка попадёт в корзину на 30 дней. Потом удалится навсегда.'.tr,
      confirmLabel: 'Удалить'.tr,
    );

    if (!confirm || !mounted) return;
    final jobId = widget.jobId;
    _controller.abandonUnsaved();
    await JobService.delete(jobId);
    // Закрывает эту карточку и все её копии глубже в стеке (заявка → клиент →
    // та же заявка), иначе «Назад» вернёт на удалённую заявку.
    StaleRoutes.dropJob(jobId);
  }

  Future<bool> _applyLeaveAction(
    UnsavedChangesAction action, {
    required bool pop,
  }) async {
    if (action == UnsavedChangesAction.cancel) return false;
    if (action == UnsavedChangesAction.save) {
      final ok = await _controller.commitChanges();
      if (!mounted) return false;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось сохранить'.tr)),
        );
        return false;
      }
      if (_controller.photosQueued) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Нет сети — фото сохранится и загрузится позже'.tr),
          ),
        );
      }
    } else {
      _controller.discardChanges();
    }
    if (pop && mounted) Navigator.pop(context);
    return true;
  }

  Future<bool> _allowNavigateAway() async {
    if (!_controller.hasUnsavedChanges) return true;
    if (!mounted) return true;
    final action = await showUnsavedChangesDialog(context);
    if (!mounted) return false;
    return _applyLeaveAction(action, pop: false);
  }

  Future<void> _onLeaveCard() async {
    final action = await showUnsavedChangesDialog(context);
    if (!mounted) return;
    await _applyLeaveAction(action, pop: true);
  }

  void _onJobTabTap(int index) {
    if (index != 1) return;
    if (_controller.financeMode != 'view_document') return;
    _controller.setFinanceMode('main');
  }

  Future<void> _handleBack() async {
    if (_controller.financeMode == 'builder') {
      await _onLeaveCard();
      return;
    }
    if (_controller.financeMode != 'main') {
      _controller.setFinanceMode('main');
      if (_tabController.index != 0) {
        _tabController.animateTo(0);
      }
      return;
    }
    if (_tabController.index != 0) {
      _tabController.animateTo(0);
      return;
    }
    if (_controller.hasUnsavedChanges) {
      await _onLeaveCard();
      return;
    }
    if (mounted) Navigator.pop(context);
  }

  bool get _canPopJob =>
      _controller.financeMode == 'main' &&
      _tabController.index == 0 &&
      !_controller.hasUnsavedChanges;

  Future<void> _openClientCard() async {
    final ctrl = _controller;
    var clientId = ctrl.clientId.trim();
    final name = (ctrl.jobData['clientName'] ?? '').toString().trim();
    final phone = (ctrl.jobData['clientPhone'] ?? '').toString().trim();
    final address = (ctrl.jobData['clientAddress'] ?? '').toString().trim();
    final email = ctrl.clientEmail.trim();

    // Если заявка не привязана к карточке клиента — найти по телефону
    // или создать новую карточку и сразу привязать к заявке.
    if (clientId.isEmpty) {
      Client? found;
      if (phone.isNotEmpty) {
        found = await ClientService.findByPhone(phone);
      }
      if (!mounted) return;

      if (found != null) {
        // Нашли существующего клиента (в т.ч. из корзины) — привязываем
        clientId = found.id;
      } else if (name.isNotEmpty || phone.isNotEmpty) {
        // Создаём новую карточку из данных заявки
        clientId = await ClientService.createOrUpdate(
          fullName: name.isNotEmpty ? name : phone,
          phone: phone,
          address: address,
          email: email.isEmpty ? null : email,
        );
      }
      if (!mounted) return;

      // Записываем clientId в заявку фоном
      if (clientId.isNotEmpty) {
        unawaited(JobService.update(ctrl.jobId, {'clientId': clientId}));
      }
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ClientDetailsScreen(
          clientId: clientId,
          clientData: {
            'name': name,
            'fullName': name,
            'phone': phone,
            'address': address,
            'email': email,
          },
        ),
      ),
    );
  }

  /// Шапка: имя клиента вместо названия техники — тап открывает карточку.
  Widget _clientTitle() {
    final name = (_controller.jobData['clientName'] ?? '').toString().trim();
    return Tooltip(
      message: 'Карточка клиента'.tr,
      child: InkWell(
        onTap: _openClientCard,
        onLongPress: name.isNotEmpty
            ? () => AppFeedback.copy(context, name)
            : null,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 8, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: Colors.white.withValues(alpha: 0.18),
                child: const Icon(Icons.person, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.isEmpty ? 'Клиент'.tr : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                        height: 1.1,
                      ),
                    ),
                    Text(
                      'Карточка клиента'.tr,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.2,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: Colors.white.withValues(alpha: 0.7),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final builder = _controller.financeMode == 'builder';
        return PopScope(
          canPop: _canPopJob,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            _handleBack();
          },
          child: Scaffold(
            appBar: AppBar(
              // «Удалить» слева, карточка клиента справа — так попросил FIX.
              leading: IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                tooltip: 'Удалить заявку'.tr,
                onPressed: _deleteJob,
              ),
              title: Align(
                alignment: Alignment.centerRight,
                child: _clientTitle(),
              ),
              titleSpacing: 4,
              toolbarHeight: 52,
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              automaticallyImplyLeading: false,
              // Вкладки — сверху, как папки в картотеке. Отдельной кнопки
              // «Сохранить» нет: правки сохраняются по «Назад» — окно
              // спросит «Подтвердить / Продолжить / Не сохранять».
              bottom: builder
                  ? null
                  : _FolderTabs(controller: _tabController, onTap: _onJobTabTap),
            ),
            body: TabBarView(
              controller: _tabController,
              physics: builder ? const NeverScrollableScrollPhysics() : null,
              children: [
                DetailsTab(controller: _controller),
                FinanceTab(controller: _controller),
                ChatTab(controller: _controller),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Вкладки-папки: открытая сливается с листом под ней, остальные — корешки.
class _FolderTabs extends StatelessWidget implements PreferredSizeWidget {
  final TabController controller;
  final ValueChanged<int> onTap;

  const _FolderTabs({required this.controller, required this.onTap});

  static const double _height = 46;

  @override
  Size get preferredSize => const Size.fromHeight(_height);

  @override
  Widget build(BuildContext context) {
    final sheet = Theme.of(context).scaffoldBackgroundColor;
    final tabs = [
      (icon: Icons.assignment_outlined, label: 'Детали'.tr),
      (icon: Icons.payments_outlined, label: 'Финансы'.tr),
      (icon: Icons.chat_bubble_outline, label: 'Чат'.tr),
    ];
    return SizedBox(
      height: _height,
      child: AnimatedBuilder(
        animation: controller.animation!,
        builder: (context, _) {
          final position = controller.animation!.value;
          return Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < tabs.length; i++) ...[
                  if (i > 0) const SizedBox(width: 4),
                  Expanded(
                    child: _folder(
                      icon: tabs[i].icon,
                      label: tabs[i].label,
                      // 1 — открыта, 0 — нет; между ними — во время свайпа.
                      openness: (1 - (position - i).abs()).clamp(0.0, 1.0),
                      sheet: sheet,
                      onTap: () {
                        controller.animateTo(i);
                        onTap(i);
                      },
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _folder({
    required IconData icon,
    required String label,
    required double openness,
    required Color sheet,
    required VoidCallback onTap,
  }) {
    final bg = Color.lerp(
      Colors.white.withValues(alpha: 0.12),
      sheet,
      openness,
    )!;
    final fg = Color.lerp(
      Colors.white.withValues(alpha: 0.85),
      AppColors.primary,
      openness,
    )!;
    const radius = BorderRadius.vertical(top: Radius.circular(12));
    return Material(
      color: bg,
      borderRadius: radius,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: SizedBox(
          height: 34 + 6 * openness,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg,
                    fontSize: 14,
                    fontWeight: openness > 0.5
                        ? FontWeight.w800
                        : FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
