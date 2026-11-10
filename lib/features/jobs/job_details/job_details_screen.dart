import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/app_feedback.dart';
import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../core/utils/app_date_picker.dart';
import '../../../models/client.dart';
import '../../../models/job.dart';
import '../../../services/services.dart';
import '../../clients/client_details_screen.dart';
import '../../care_plan/care_plan_widgets.dart';
import '../../../shared/widgets/unsaved_changes_dialog.dart';
import '../../../shared/app_nav.dart';
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
    UnsavedNavigationGate.push(
      _allowNavigateAway,
      unsaved: () => _controller.hasUnsavedChanges,
    );
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
      // Финансы — вторая вкладка. Ушли с неё — закрываем открытый документ.
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

  /// Ответ списка «Что удалить?»: вся заявка, а не отдельный визит.
  static const String _wholeJobChoice = '*job*';

  /// Корзина в шапке. Пока визит один — как раньше. Если их несколько, она
  /// сначала спрашивает, что убрать: один выезд или всю заявку. Раньше она
  /// молча уносила всё вместе со счётом и оплатами (FIX, 11.10.2026).
  Future<void> _deleteJob() async {
    final visits = _controller.visits;
    if (visits.length > 1) {
      final choice = await _pickDeleteTarget(visits);
      if (choice == null || !mounted) return;
      if (choice != _wholeJobChoice) {
        await _deleteOneVisit(visits, choice);
        return;
      }
    }

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

  Future<void> _deleteOneVisit(List<JobVisit> visits, String visitId) async {
    JobVisit? visit;
    for (final item in visits) {
      if (item.id == visitId) visit = item;
    }
    if (visit == null) return;
    final ok = await showConfirmCancelSheet(
      context,
      title: 'Удалить визит?'.tr,
      message:
          '${appDateTimeLabel(visit.startAt, withTime: visit.hasTime)}\n\n${'Остальные визиты, счёт и оплаты останутся на месте.'.tr}',
      confirmLabel: 'Удалить'.tr,
    );
    if (!ok || !mounted) return;
    await _controller.removeVisit(visitId);
    await _controller.commitChanges();
  }

  /// Список выездов заявки: свежий сверху. Возвращает id визита,
  /// [_wholeJobChoice] или null, если закрыли не выбрав.
  Future<String?> _pickDeleteTarget(List<JobVisit> visits) {
    final sorted = [...visits]..sort((a, b) => b.startAt.compareTo(a.startAt));
    return showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Что удалить?'.tr,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'В этой заявке несколько выездов. Нажмите на тот, который убрать — остальные останутся.'
                          .tr,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppColors.inkMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 20),
              for (final visit in sorted)
                ListTile(
                  leading: Icon(
                    Icons.event_rounded,
                    color: AppColors.inkMuted,
                  ),
                  title: Text(
                    appDateTimeLabel(visit.startAt, withTime: visit.hasTime),
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                  subtitle: Text(_visitStateLabel(visit)),
                  trailing: Icon(
                    Icons.delete_outline,
                    color: Colors.red.shade700,
                  ),
                  onTap: () => Navigator.pop(sheetContext, visit.id),
                ),
              const Divider(height: 20),
              ListTile(
                leading: Icon(Icons.delete_forever, color: Colors.red.shade700),
                title: Text(
                  'Удалить всю заявку'.tr,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    color: Colors.red.shade700,
                  ),
                ),
                subtitle: Text(
                  '${'Визитов'.tr}: ${visits.length} — ${'вместе со счетами, оплатами и фото'.tr}',
                ),
                onTap: () => Navigator.pop(sheetContext, _wholeJobChoice),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  String _visitStateLabel(JobVisit visit) {
    if (visit.isDone) return 'Выполнен'.tr;
    if (visit.isCancelled) return 'Отменён'.tr;
    return 'Запланирован'.tr;
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
    final phone = (ctrl.jobData['clientPhone'] ?? '').toString().trim();
    final name = Client.stripClientWord(
      (ctrl.jobData['clientName'] ?? '').toString(),
    );
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

    AppNav.openCard(
      context,
      key: AppNav.clientKey(clientId),
      builder: (context) => ClientDetailsScreen(
        clientId: clientId,
        clientData: {
          'name': name,
          'fullName': name,
          'phone': phone,
          'address': address,
          'email': email,
          'isRegular':
              ctrl.jobData['clientIsRegular'] == true ||
              ClientService.isRegularClient(
                clientId: clientId,
                phone: phone,
                email: email,
              ),
        },
      ),
    );
  }

  /// Шапка: имя клиента вместо названия техники — тап открывает карточку.
  Widget _clientTitle() {
    final name = Client.stripClientWord(
      (_controller.jobData['clientName'] ?? '').toString(),
    );
    return ValueListenableBuilder<int>(
      valueListenable: ClientService.regularRevision,
      builder: (context, _, _) {
        final isRegular =
            _controller.jobData['clientIsRegular'] == true ||
            ClientService.isRegularClient(
              clientId: _controller.clientId,
              phone: (_controller.jobData['clientPhone'] ?? '').toString(),
              email: _controller.clientEmail,
            );
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
                    child: const Icon(
                      Icons.person,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                // Имени нет — пишем «Клиент», а не телефон.
                                // Настоящее имя придёт из карточки клиента.
                                name.isEmpty ? 'Клиент'.tr : name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 17,
                                  height: 1.1,
                                ),
                              ),
                            ),
                            if (isRegular)
                              const RegularClientStar(size: 18, onDark: true),
                            CarePlanMark(
                              clientId: _controller.clientId,
                              phone: (_controller.jobData['clientPhone'] ?? '')
                                  .toString(),
                              planId: (_controller.jobData['carePlanId'] ?? '')
                                  .toString(),
                              size: 19,
                              onDark: true,
                            ),
                          ],
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
      },
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
              // «Удалить» слева, напоминание и карточка клиента справа.
              leading: IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                tooltip: 'Удалить заявку'.tr,
                onPressed: _deleteJob,
              ),
              title: Row(
                children: [
                  ValueListenableBuilder<int>(
                    valueListenable: JobReminderService.revision,
                    builder: (context, _, _) {
                      final remindAt = JobReminderService.reminderFor(
                        widget.jobId,
                        _controller.jobData,
                      );
                      final hasReminder = remindAt != null;
                      final due =
                          remindAt != null && !remindAt.isAfter(DateTime.now());
                      return IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: hasReminder
                            ? '${context.tr('Напоминание', 'Reminder')}: ${appDateTimeLabel(remindAt)}'
                            : context.tr(
                                'Напомнить о карточке',
                                'Remind about job',
                              ),
                        icon: Icon(
                          hasReminder
                              ? Icons.notifications_active_rounded
                              : Icons.notifications_none_rounded,
                          color: due
                              ? const Color(0xFFFF5252)
                              : hasReminder
                                  ? AppColors.accent
                                  : Colors.white,
                          size: 24,
                        ),
                        onPressed: () {
                          JobReminderService.showPickerSheet(
                            context,
                            jobId: widget.jobId,
                            clientId: _controller.clientId,
                            jobData: _controller.jobData,
                            onChanged: (dt) {
                              if (!mounted) return;
                              setState(() {
                                if (dt == null) {
                                  _controller.jobData.remove('reminderAt');
                                } else {
                                  _controller.jobData['reminderAt'] =
                                      dt.toIso8601String();
                                }
                              });
                            },
                          );
                        },
                      );
                    },
                  ),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: _clientTitle(),
                    ),
                  ),
                ],
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
            body: Column(
              children: [
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    physics: builder ? const NeverScrollableScrollPhysics() : null,
                    children: [
                      DetailsTab(controller: _controller),
                      FinanceTab(controller: _controller),
                      ChatTab(
                        controller: _controller,
                        chatVisible: _tabController.index == 2,
                      ),
                    ],
                  ),
                ),
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
      AppColors.primaryOnCard,
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
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg,
                    fontSize: 12,
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

