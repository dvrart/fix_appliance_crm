import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/app_commands.dart';
import '../../core/app_feedback.dart';
import '../../core/constants.dart';
import '../../core/ui_scale.dart';
import '../../shared/widgets/custom_drawer.dart';
import '../../shared/unsaved_navigation_gate.dart';
import '../../shared/widgets/confirm_action_sheet.dart';
import '../../shared/widgets/fade_indexed_stack.dart';
import '../../shared/widgets/offline_chip.dart';
import '../calendar/calendar_screen.dart';
import '../jobs/create_job_screen.dart';
import '../clients/clients_screen.dart';
import '../comms/comms_hub_screen.dart';
import '../calls/dial_pad_screen.dart';
import '../messages/messages_screen.dart';
import '../messages/compose_speed_dial.dart';
import '../messages/conversation_screen.dart';
import '../ai/assistant/assistant_face.dart';
import '../ai/assistant/review_bell_button.dart';
import '../../services/job_service.dart';
import '../../services/notification_service.dart';
import '../../services/offline_queue_service.dart';
import '../../services/error_log_service.dart';

const double _handleWidth = 36;

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen>
    with UiSettingsAware, SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  bool _onRoot = true;
  bool _openingJob = false;
  bool _handlingBack = false;
  bool _composeOpen = false;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _inboxKey = GlobalKey<ReviewInboxPanelState>();
  late final List<_TabNavObserver> _navObservers;
  late final AnimationController _menu = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 340),
    reverseDuration: const Duration(milliseconds: 280),
  );

  final List<GlobalKey<NavigatorState>> _navigatorKeys = [
    GlobalKey<NavigatorState>(),
    GlobalKey<NavigatorState>(),
    GlobalKey<NavigatorState>(),
  ];

  final List<Widget> _screens = [
    const CalendarScreen(),
    const CommsHubScreen(),
    const ClientsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    ErrorLogService.markScreen('Главная');
    _navObservers = [
      _TabNavObserver(_syncRoot),
      _TabNavObserver(_syncRoot),
      _TabNavObserver(_syncRoot),
    ];
    OfflineQueueService.flush();
    unawaited(JobService.recoverMissingCallJobs());
    unawaited(JobService.completeLegacyJobsIfNeeded());
    AppCommands.selectTab.addListener(_onSelectTabCommand);
    AppCommands.commsTab.addListener(_onCommsTabChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(NotificationService.promptIfDisabled(context));
    });
  }

  @override
  void dispose() {
    AppCommands.selectTab.removeListener(_onSelectTabCommand);
    AppCommands.commsTab.removeListener(_onCommsTabChanged);
    _menu.dispose();
    super.dispose();
  }

  bool get _menuOpen => !_menu.isDismissed;

  Future<void> _openMenu() async {
    try {
      await _menu.forward().orCancel;
    } on TickerCanceled {
      // Прервано другим жестом — панель уже там, куда её повели.
    }
  }

  Future<void> _closeMenu() async {
    if (_menu.isDismissed) return;
    try {
      await _menu.reverse().orCancel;
    } on TickerCanceled {
      // См. выше.
    }
  }

  void _onCommsTabChanged() {
    if (!mounted) return;
    setState(() => _composeOpen = false);
  }

  void _syncRoot() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final nav = _navigatorKeys[_currentIndex].currentState;
      final onRoot = nav == null || !nav.canPop();
      if (onRoot != _onRoot) {
        setState(() {
          _onRoot = onRoot;
          if (!onRoot) _composeOpen = false;
        });
      }
    });
  }

  void _onSelectTabCommand() {
    final index = AppCommands.selectTab.value;
    if (index == null || !mounted) return;
    AppCommands.selectTab.value = null;
    _selectTab(index);
  }

  Future<void> _selectTab(int index) async {
    if (_currentIndex == index) {
      AppFeedback.pleasant();
      await _popToRoot(_navigatorKeys[index].currentState);
      _syncRoot();
      return;
    }
    if (!await UnsavedNavigationGate.allowLeave(host: context)) return;
    if (!mounted) return;
    AppFeedback.pleasant();
    setState(() {
      _currentIndex = index;
      _composeOpen = false;
    });
    _syncRoot();
  }

  Future<void> _popToRoot(NavigatorState? navigator) async {
    if (navigator == null) return;
    while (navigator.canPop()) {
      final popped = await navigator.maybePop();
      if (!popped) return;
    }
  }

  bool get _isDefaultHome {
    return _currentIndex == 0 && _onRoot && AppCommands.calendarAtHome.value;
  }

  Future<void> _goDefaultHome() async {
    if (_currentIndex != 0) {
      if (!await UnsavedNavigationGate.allowLeave(host: context)) return;
      if (!mounted) return;
      setState(() => _currentIndex = 0);
    }
    await _popToRoot(_navigatorKeys[0].currentState);
    if (!mounted) return;
    AppCommands.showCalendarHome();
    _syncRoot();
  }

  Future<void> _onSystemBack() async {
    if (_composeOpen) {
      setState(() => _composeOpen = false);
      return;
    }
    if (_menuOpen) {
      unawaited(_closeMenu());
      return;
    }
    if (AppCommands.dismissSelections()) return;

    final scaffold = _scaffoldKey.currentState;
    if (scaffold != null && scaffold.isEndDrawerOpen) {
      scaffold.closeEndDrawer();
      return;
    }

    final navigator = _navigatorKeys[_currentIndex].currentState;
    if (navigator != null && navigator.canPop()) {
      await navigator.maybePop();
      _syncRoot();
      return;
    }

    if (!_isDefaultHome) {
      await _goDefaultHome();
      if (!mounted) return;
      if (!_isDefaultHome) return;
    }

    final leave = await showExitAppSheet(context);
    if (leave && mounted) {
      SystemNavigator.pop();
    }
  }

  void _openNotifications() {
    _scaffoldKey.currentState?.openEndDrawer();
  }

  void _closeNotifications() {
    _scaffoldKey.currentState?.closeEndDrawer();
  }

  void _toggleNotifications() {
    final scaffold = _scaffoldKey.currentState;
    if (scaffold == null) return;
    if (scaffold.isEndDrawerOpen) {
      scaffold.closeEndDrawer();
    } else {
      scaffold.openEndDrawer();
    }
  }

  void _onDockPanEnd(DragEndDetails details) {
    final dx = details.velocity.pixelsPerSecond.dx;
    final dy = details.velocity.pixelsPerSecond.dy;
    if (dx.abs() < 280 || dx.abs() < dy.abs()) return;
    AppFeedback.pleasant();
    if (dx > 0) {
      unawaited(_openMenu());
    } else {
      _openNotifications();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || _handlingBack) return;
        _handlingBack = true;
        try {
          await _onSystemBack();
        } finally {
          if (mounted) _handlingBack = false;
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        resizeToAvoidBottomInset: false,
        backgroundColor: AppColors.primary,
        endDrawer: ReviewInboxDrawer(
          hostContext: context,
          panelKey: _inboxKey,
          onClose: _closeNotifications,
        ),
        endDrawerEnableOpenDragGesture: false,
        onEndDrawerChanged: (open) {
          if (open) {
            _inboxKey.currentState?.onHostOpened();
          } else {
            _inboxKey.currentState?.onHostClosed();
          }
        },
        body: Stack(
          children: [
            _buildBody(),
            _SideMenuLayer(
              controller: _menu,
              onClose: _closeMenu,
              child: CustomDrawer(onClose: _closeMenu),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    return Column(
          children: [
            ColoredBox(
              color: AppColors.primary,
              child: SafeArea(
                bottom: false,
                child: SizedBox(
                  height: 56,
                  child: Stack(
                    alignment: Alignment.center,
                    children: const [
                      Center(child: AssistantFaceButton(size: 52)),
                      Positioned(left: 12, child: OfflineChip()),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      padding: MediaQuery.paddingOf(
                        context,
                      ).copyWith(top: 0, bottom: 0),
                      viewPadding: MediaQuery.viewPaddingOf(
                        context,
                      ).copyWith(top: 0, bottom: 0),
                      viewInsets: MediaQuery.viewInsetsOf(context).copyWith(
                        bottom:
                            (MediaQuery.viewInsetsOf(context).bottom -
                                    (64 + MediaQuery.paddingOf(context).bottom))
                                .clamp(0.0, double.infinity),
                      ),
                    ),
                    child: FadeIndexedStack(
                      index: _currentIndex,
                      children: [_buildTab(0), _buildTab(1), _buildTab(2)],
                    ),
                  ),
                  if (_onRoot && (_currentIndex == 0 || _currentIndex == 1))
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 16,
                      child: Center(child: _tabRoundButton()),
                    ),
                ],
              ),
            ),
            ColoredBox(
              color: AppColors.primary,
              child: Stack(
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(height: 64, child: _buildBottomDock()),
                      const SafeArea(top: false, child: SizedBox.shrink()),
                    ],
                  ),
                  _LeftMenuHandle(onOpen: _openMenu),
                  _RightNotifyHandle(
                    onToggle: _toggleNotifications,
                    onOpen: _openNotifications,
                    onClose: _closeNotifications,
                  ),
                ],
              ),
            ),
          ],
        );
  }

  Future<void> _openCreateJob() async {
    if (_openingJob) return;
    _openingJob = true;
    try {
      var nav = _navigatorKeys[_currentIndex].currentState;
      if (nav == null) {
        await Future<void>.delayed(Duration.zero);
        if (!mounted) return;
        nav = _navigatorKeys[_currentIndex].currentState;
      }
      if (nav == null) return;
      await nav.push(_slideUpJobRoute());
      _syncRoot();
    } finally {
      _openingJob = false;
    }
  }

  Route<void> _slideUpJobRoute() {
    return PageRouteBuilder<void>(
      pageBuilder: (context, animation, secondary) {
        return const CreateJobScreen();
      },
      transitionDuration: const Duration(milliseconds: 380),
      reverseTransitionDuration: const Duration(milliseconds: 320),
      transitionsBuilder: (context, animation, secondary, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: const Cubic(0.16, 1, 0.3, 1),
          reverseCurve: Curves.easeInOutCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
    );
  }

  Widget _buildBottomDock() {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanEnd: _onDockPanEnd,
      child: SizedBox(
        height: 64,
        child: Row(
          children: [
            const SizedBox(width: _handleWidth),
            Expanded(
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _dockTab(0, Icons.calendar_month),
                    _dockTab(1, Icons.forum),
                    _dockTab(2, Icons.people),
                  ],
                ),
              ),
            ),
            const SizedBox(width: _handleWidth),
          ],
        ),
      ),
    );
  }

  void _openDialPad() {
    DialPadScreen.open(context);
  }

  Future<void> _openCompose(ConversationChannel channel) async {
    setState(() => _composeOpen = false);
    final host = _navigatorKeys[1].currentContext ?? context;
    await MessagesScreen.startNewConversation(host, channel: channel);
  }

  Widget _tabRoundButton() {
    final commsChat = _currentIndex == 1 && AppCommands.commsTab.value == 1;
    final dial = _currentIndex == 1 && !commsChat;
    if (commsChat) {
      return ComposeSpeedDial(
        open: _composeOpen,
        onToggle: () {
          AppFeedback.pleasant();
          setState(() => _composeOpen = !_composeOpen);
        },
        onSms: () => _openCompose(ConversationChannel.sms),
        onEmail: () => _openCompose(ConversationChannel.email),
      );
    }
    return FloatingActionButton(
      heroTag: dial ? 'dock-dial' : 'dock-add',
      backgroundColor: AppColors.accent,
      foregroundColor: AppColors.primary,
      elevation: 4,
      onPressed: () {
        AppFeedback.pleasant();
        if (dial) {
          _openDialPad();
        } else {
          _openCreateJob();
        }
      },
      child: Icon(dial ? Icons.dialpad : Icons.add, size: dial ? 30 : 34),
    );
  }

  Widget _dockTab(int index, IconData icon) {
    final selected = _currentIndex == index;
    final scale = AppUiSettings.instance.scale;
    return InkWell(
      onTap: () => _selectTab(index),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 10 * scale),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.symmetric(
            horizontal: 10 * scale,
            vertical: 6 * scale,
          ),
          decoration: BoxDecoration(
            color: selected ? AppColors.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(
            icon,
            size: 32 * scale,
            color: selected ? AppColors.primary : Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildTab(int index) {
    return Navigator(
      key: _navigatorKeys[index],
      observers: [_navObservers[index]],
      onGenerateRoute: (routeSettings) {
        return MaterialPageRoute(
          builder: (context) {
            return ColoredBox(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: _screens[index],
            );
          },
        );
      },
    );
  }
}

class _TabNavObserver extends NavigatorObserver {
  final VoidCallback onChange;

  _TabNavObserver(this.onChange);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onChange();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onChange();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onChange();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      onChange();
}

class _LeftMenuHandle extends StatelessWidget {
  final VoidCallback onOpen;

  const _LeftMenuHandle({required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      width: _handleWidth,
      child: _DockSideButton(left: true, onTap: onOpen),
    );
  }
}

/// Своя боковая панель вместо `Scaffold.drawer`: содержимое живёт в дереве
/// постоянно (стримы уже подписаны, сетка построена), поэтому при открытии
/// ничего не собирается с нуля и анимация не проседает на первых кадрах.
class _SideMenuLayer extends StatefulWidget {
  final AnimationController controller;
  final Future<void> Function() onClose;
  final Widget child;

  const _SideMenuLayer({
    required this.controller,
    required this.onClose,
    required this.child,
  });

  @override
  State<_SideMenuLayer> createState() => _SideMenuLayerState();
}

class _SideMenuLayerState extends State<_SideMenuLayer> {
  late final CurvedAnimation _eased = CurvedAnimation(
    parent: widget.controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  double _panelWidth = 304;

  /// Пока панель ведут пальцем (и пока доигрывает «доводка» после
  /// отпускания), позиция берётся напрямую из контроллера, без кривой:
  /// иначе в момент отпускания панель прыгала бы на значение кривой.
  bool _raw = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addStatusListener(_onStatus);
  }

  @override
  void dispose() {
    widget.controller.removeStatusListener(_onStatus);
    _eased.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      _raw = false;
    }
  }

  void _onDragStart(DragStartDetails _) {
    _raw = true;
    widget.controller.stop();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    widget.controller.value += details.primaryDelta! / _panelWidth;
  }

  void _onDragEnd(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0;
    final value = widget.controller.value;
    final close = v < -300 || (v.abs() <= 300 && value < 0.5);
    // Доводим из текущей точки с замедлением; длительность — по остатку пути.
    final remaining = close ? value : 1 - value;
    final duration = Duration(
      milliseconds: (80 + 220 * remaining).round(),
    );
    widget.controller.animateTo(
      close ? 0 : 1,
      duration: duration,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    _panelWidth = (DrawerTheme.of(context).width ?? 304).clamp(0, width);
    return AnimatedBuilder(
      animation: widget.controller,
      child: RepaintBoundary(child: widget.child),
      builder: (context, child) {
        final closed = widget.controller.isDismissed;
        final t = _raw ? widget.controller.value : _eased.value;
        return Offstage(
          offstage: closed,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: _onDragStart,
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: _onDragEnd,
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onClose,
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.42 * t),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: _panelWidth,
                  child: Transform.translate(
                    offset: Offset(-_panelWidth * (1 - t), 0),
                    child: child,
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

class _RightNotifyHandle extends StatefulWidget {
  final VoidCallback onToggle;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  const _RightNotifyHandle({
    required this.onToggle,
    required this.onOpen,
    required this.onClose,
  });

  @override
  State<_RightNotifyHandle> createState() => _RightNotifyHandleState();
}

class _RightNotifyHandleState extends State<_RightNotifyHandle> {
  double _dragDx = 0;

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.horizontal(left: Radius.circular(18));
    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      width: _handleWidth,
      child: Material(
        color: AppColors.accent,
        elevation: 0,
        clipBehavior: Clip.none,
        shape: const RoundedRectangleBorder(borderRadius: radius),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) => _dragDx = 0,
          onHorizontalDragUpdate: (details) => _dragDx += details.delta.dx,
          onHorizontalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            if (velocity < -240 || _dragDx < -24) {
              widget.onOpen();
            } else if (velocity > 240 || _dragDx > 24) {
              widget.onClose();
            }
          },
          child: InkWell(
            customBorder: const RoundedRectangleBorder(borderRadius: radius),
            onTap: widget.onToggle,
            child: const Center(
              child: ReviewBellPickleIcon(
                color: Color(0xFF14557F),
                size: 22,
                badgeAlignment: Alignment.topLeft,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DockSideButton extends StatelessWidget {
  final bool left;
  final VoidCallback onTap;

  const _DockSideButton({required this.left, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.horizontal(
      right: left ? const Radius.circular(18) : Radius.zero,
      left: left ? Radius.zero : const Radius.circular(18),
    );
    return Material(
      color: AppColors.accent,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: radius),
      child: InkWell(
        customBorder: RoundedRectangleBorder(borderRadius: radius),
        onTap: onTap,
        child: const Center(
          child: Icon(Icons.more_vert, color: Color(0xFF14557F), size: 22),
        ),
      ),
    );
  }
}
