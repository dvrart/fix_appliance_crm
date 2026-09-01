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

const double _handleWidth = 36;

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with UiSettingsAware {
  int _currentIndex = 0;
  bool _onRoot = true;
  bool _openingJob = false;
  bool _handlingBack = false;
  bool _composeOpen = false;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _inboxKey = GlobalKey<ReviewInboxPanelState>();
  late final List<_TabNavObserver> _navObservers;

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
    super.dispose();
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
    if (AppCommands.dismissSelections()) return;

    final scaffold = _scaffoldKey.currentState;
    if (scaffold != null &&
        (scaffold.isDrawerOpen || scaffold.isEndDrawerOpen)) {
      scaffold.closeDrawer();
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

  void _openMenu() {
    _scaffoldKey.currentState?.openDrawer();
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
      _openMenu();
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
        drawer: const CustomDrawer(),
        endDrawer: ReviewInboxDrawer(
          hostContext: context,
          panelKey: _inboxKey,
          onClose: _closeNotifications,
        ),
        drawerEnableOpenDragGesture: false,
        endDrawerEnableOpenDragGesture: false,
        onEndDrawerChanged: (open) {
          if (open) {
            _inboxKey.currentState?.onHostOpened();
          } else {
            _inboxKey.currentState?.onHostClosed();
          }
        },
        body: Column(
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
                  const _LeftMenuHandle(),
                  _RightNotifyHandle(
                    onToggle: _toggleNotifications,
                    onOpen: _openNotifications,
                    onClose: _closeNotifications,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
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
  const _LeftMenuHandle();

  @override
  Widget build(BuildContext context) {
    return const Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      width: _handleWidth,
      child: _DockSideButton(left: true, onOpenMenu: true),
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
  final bool onOpenMenu;

  const _DockSideButton({required this.left, required this.onOpenMenu});

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
        onTap: () {
          if (onOpenMenu) {
            Scaffold.of(context).openDrawer();
          }
        },
        child: const Center(
          child: Icon(Icons.more_vert, color: Color(0xFF14557F), size: 22),
        ),
      ),
    );
  }
}
