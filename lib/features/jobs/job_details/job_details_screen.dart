import 'package:flutter/material.dart';
import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../services/services.dart';
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

  @override
  Widget build(BuildContext context) {
    final applianceType = trAny(widget.jobData['applianceType'] ?? 'Заявка');
    final brand = widget.jobData['brand'] ?? '';
    final title = brand.isNotEmpty ? '$applianceType $brand' : applianceType;

    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        return PopScope(
          canPop: _canPopJob,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            _handleBack();
          },
          child: Scaffold(
            appBar: AppBar(
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        toolbarHeight: 44,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete, color: Colors.red),
            tooltip: 'Удалить заявку'.tr,
            onPressed: _deleteJob,
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        physics: _controller.financeMode == 'builder'
            ? const NeverScrollableScrollPhysics()
            : null,
        children: [
          DetailsTab(controller: _controller),
          FinanceTab(controller: _controller),
          ChatTab(controller: _controller),
        ],
      ),
      // Внизу только вкладки — под большим пальцем. Отдельной кнопки
      // «Сохранить» нет: правки сохраняются по «Назад» — окно спросит
      // «Подтвердить / Продолжить / Не сохранять».
      bottomNavigationBar: _controller.financeMode == 'builder'
          ? null
          : Material(
              color: AppColors.primary,
              child: SafeArea(
                top: false,
                child: TabBar(
                    controller: _tabController,
                    onTap: _onJobTabTap,
                    indicatorColor: AppColors.accent,
                    labelColor: AppColors.accent,
                    unselectedLabelColor: Colors.white,
                    labelStyle: const TextStyle(fontWeight: FontWeight.bold),
                    tabs: [
                      Tab(text: 'ДЕТАЛИ'.tr),
                      Tab(text: 'ФИНАНСЫ'.tr),
                      Tab(text: 'ЧАТ'.tr),
                    ],
                  ),
                ),
              ),
    ),
        );
      },
    );
  }
}
