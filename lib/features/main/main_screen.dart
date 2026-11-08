import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/app_commands.dart';
import '../../core/app_feedback.dart';
import '../../core/constants.dart';
import '../../core/ui_scale.dart';
import '../../shared/app_nav.dart';
import '../../shared/widgets/custom_drawer.dart';
import '../../shared/unsaved_navigation_gate.dart';
import '../../shared/widgets/confirm_action_sheet.dart';
import '../../shared/widgets/count_badge.dart';
import '../../shared/widgets/fade_indexed_stack.dart';
import '../../shared/widgets/offline_chip.dart';
import '../calendar/calendar_screen.dart';
import '../jobs/active_jobs_screen.dart';
import '../clients/clients_screen.dart';
import '../comms/comms_hub_screen.dart';
import '../calls/call_screen.dart';
import '../calls/dial_pad_screen.dart';
import '../messages/messages_screen.dart';
import '../messages/compose_speed_dial.dart';
import '../messages/conversation_screen.dart';
import '../ai/assistant/assistant_face.dart';
import '../../core/l10n/app_locale.dart';
import '../../services/care_plan_service.dart';
import '../../services/comms_badge_service.dart';
import '../../services/job_reminder_service.dart';
import '../../services/job_service.dart';
import '../../services/notification_service.dart';
import '../../services/offline_queue_service.dart';
import '../../services/twilio_service.dart';
import '../../services/error_log_service.dart';

const double _handleWidth = 30;
const double _dockHeight = 46;

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen>
    with UiSettingsAware, SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  /// Вкладка с карточкой, из которой ушли по нижнему меню. Её стек не
  /// сбрасывается сразу: «Назад» с чужой вкладки возвращает в ту самую
  /// заявку или карточку клиента, а не выбрасывает на главную.
  int? _cardReturnTab;
  bool _onRoot = true;
  bool _handlingBack = false;
  bool _composeOpen = false;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
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
    AppNav.bindTabNavigator(() => _navigatorKeys[_currentIndex].currentState);
    OfflineQueueService.flush();
    // Care Plan и паспорта — одна подписка на всё приложение: значок
    // «гарантийный клиент» на звонке и в заявке появляется без запросов.
    CarePlanService.start();
    unawaited(JobReminderService.start());
    unawaited(JobService.completeLegacyJobsIfNeeded());
    AppCommands.selectTab.addListener(_onSelectTabCommand);
    AppCommands.commsTab.addListener(_onCommsTabChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(NotificationService.promptIfDisabled(context));
    });
  }

  @override
  void dispose() {
    AppNav.bindTabNavigator(null);
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
    _markCallsSeenIfVisible();
  }

  /// «Новое» на вкладке «Звонки» гаснет, когда список действительно перед
  /// глазами. Подвкладка живёт в дереве всегда, поэтому одного её индекса
  /// мало — нужна ещё и выбранная вкладка «Связь».
  void _markCallsSeenIfVisible() {
    if (_currentIndex == 1 && AppCommands.commsTab.value == 0) {
      CommsBadgeService.markCallsSeen();
    }
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
    // Сменили вкладку — панели, ждущие возврата, ждут напрасно.
    PanelReturn.cancel();
    if (_menuOpen) unawaited(_closeMenu());
    final scaffold = _scaffoldKey.currentState;
    if (scaffold != null && scaffold.isEndDrawerOpen) {
      scaffold.closeEndDrawer();
    }
    if (_currentIndex == index) {
      AppFeedback.pleasant();
      await _popToRoot(_navigatorKeys[index].currentState);
      _syncRoot();
      _markCallsSeenIfVisible();
      return;
    }
    if (!await UnsavedNavigationGate.allowLeave(host: context)) return;
    if (!mounted) return;
    AppFeedback.pleasant();
    final leaving = _currentIndex;
    final keepCard = _onCardTab(leaving);
    setState(() {
      _currentIndex = index;
      _composeOpen = false;
    });
    ErrorLogService.markScreen(
      switch (index) {
        0 => 'Главная',
        1 => 'Связь',
        2 => 'Клиенты',
        _ => 'Главная',
      },
    );
    _dropCardReturn(except: index);
    if (keepCard) {
      _cardReturnTab = leaving;
    } else {
      _forgetTab(leaving);
    }
    _syncRoot();
    _markCallsSeenIfVisible();
  }

  /// Наверху вкладки — карточка (заявка, клиент, переписка), открытая через
  /// [AppNav.openCard].
  bool _onCardTab(int index) {
    final navigator = _navigatorKeys[index].currentState;
    if (navigator == null || !navigator.canPop()) return false;
    final pages = AppNav.pagesOf(navigator);
    return pages.isNotEmpty && AppNav.isCard(pages.last);
  }

  /// Отложенный возврат больше не нужен: вкладка с карточкой сбрасывается на
  /// корень, как при обычном уходе с неё.
  void _dropCardReturn({int? except}) {
    final index = _cardReturnTab;
    _cardReturnTab = null;
    if (index == null || index == except || index == _currentIndex) return;
    _forgetTab(index);
  }

  /// Вкладку, с которой ушли, возвращаем на корень: нажал «Календарь» —
  /// видишь календарь, а не заявку, открытую полчаса назад. Ждём конец
  /// кроссфейда, иначе сброс видно на уходящей вкладке.
  void _forgetTab(int index) {
    Future.delayed(const Duration(milliseconds: 360), () {
      if (!mounted || _currentIndex == index) return;
      final navigator = _navigatorKeys[index].currentState;
      if (navigator == null) return;
      AppNav.resetToRoot(navigator);
      _syncRoot();
    });
  }

  Future<void> _popToRoot(NavigatorState? navigator) async {
    if (navigator == null) return;
    await AppNav.popToRoot(navigator);
  }

  bool get _isDefaultHome {
    return _currentIndex == 0 && _onRoot && AppCommands.calendarAtHome.value;
  }

  Future<void> _goDefaultHome() async {
    PanelReturn.cancel();
    _dropCardReturn();
    if (_currentIndex != 0) {
      if (!await UnsavedNavigationGate.allowLeave(host: context)) return;
      if (!mounted) return;
      final leaving = _currentIndex;
      setState(() => _currentIndex = 0);
      _forgetTab(leaving);
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

    // Ушли из карточки по нижнему меню — «Назад» возвращает в неё.
    final card = _cardReturnTab;
    if (card != null && card != _currentIndex && _onCardTab(card)) {
      await _selectTab(card);
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

  void _openVisits() {
    _scaffoldKey.currentState?.openEndDrawer();
  }

  void _closeVisits() {
    _scaffoldKey.currentState?.closeEndDrawer();
  }

  /// Возвращает шторку «Все визиты», из которой ушли в карточку: «Назад» из
  /// карточки ведёт туда, откуда её открыли, а не на вкладку под шторкой.
  /// Когда возврат уместен, решает [PanelReturn].
  void _returnToVisits() {
    if (!mounted || _menuOpen) return;
    final scaffold = _scaffoldKey.currentState;
    if (scaffold == null || scaffold.isEndDrawerOpen) return;
    scaffold.openEndDrawer();
  }

  /// То же для левого меню: «Назад» из «Расходов» или «Настроек» возвращает
  /// меню, с которого их открыли.
  void _returnToMenu() {
    if (!mounted || _menuOpen) return;
    final scaffold = _scaffoldKey.currentState;
    if (scaffold != null && scaffold.isEndDrawerOpen) return;
    unawaited(_openMenu());
  }

  void _toggleVisits() {
    final scaffold = _scaffoldKey.currentState;
    if (scaffold == null) return;
    if (scaffold.isEndDrawerOpen) {
      scaffold.closeEndDrawer();
    } else {
      scaffold.openEndDrawer();
    }
  }

  /// Свайп вверх по нижней панели больше ничего не открывает: «Все визиты»
  /// переехали в правую шторку, и вертикальный жест остался бы единственным
  /// способом попасть в уже закрытый экран.
  void _onDockPanEnd(DragEndDetails details) {
    final dx = details.velocity.pixelsPerSecond.dx;
    final dy = details.velocity.pixelsPerSecond.dy;
    if (dx.abs() < 280 || dx.abs() < dy.abs()) return;
    AppFeedback.pleasant();
    if (dx > 0) {
      unawaited(_openMenu());
    } else {
      _openVisits();
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
        backgroundColor: AppColors.footer,
        endDrawer: _AllVisitsDrawer(
          hostContext: context,
          onClose: _closeVisits,
          onReturn: _returnToVisits,
        ),
        endDrawerEnableOpenDragGesture: false,
        body: Stack(
          children: [
            _buildBody(),
            _SideMenuLayer(
              controller: _menu,
              onClose: _closeMenu,
              child: CustomDrawer(onClose: _closeMenu, onReturn: _returnToMenu),
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
                  height: 44,
                  child: Stack(
                    alignment: Alignment.center,
                    children: const [
                      Center(child: AssistantFaceButton(size: 40)),
                      Positioned(left: 12, child: OfflineChip()),
                    ],
                  ),
                ),
              ),
            ),
            const _ActiveCallReturnBar(),
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
                                    (_dockHeight + MediaQuery.paddingOf(context).bottom))
                                .clamp(0.0, double.infinity),
                      ),
                    ),
                    child: FadeIndexedStack(
                      index: _currentIndex,
                      children: [_buildTab(0), _buildTab(1), _buildTab(2)],
                    ),
                  ),
                  if (_onRoot && _currentIndex == 1)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 12,
                      child: Center(child: _tabRoundButton()),
                    ),
                ],
              ),
            ),
            ColoredBox(
              color: AppColors.footer,
              child: Stack(
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onPanEnd: _onDockPanEnd,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(height: _dockHeight, child: _buildBottomDock()),
                        const SafeArea(top: false, child: SizedBox.shrink()),
                      ],
                    ),
                  ),
                  _LeftMenuHandle(onOpen: _openMenu),
                  _RightVisitsHandle(
                    onToggle: _toggleVisits,
                    onOpen: _openVisits,
                    onClose: _closeVisits,
                  ),
                ],
              ),
            ),
          ],
        );
  }

  Widget _buildBottomDock() {
    return SizedBox(
      height: _dockHeight,
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
      heroTag: 'dock-dial',
      backgroundColor: AppColors.accent,
      foregroundColor: AppColors.primary,
      elevation: 4,
      onPressed: () {
        AppFeedback.pleasant();
        _openDialPad();
      },
      child: const Icon(Icons.dialpad, size: 30),
    );
  }

  Widget _dockTab(int index, IconData icon) {
    final selected = _currentIndex == index;
    final scale = AppUiSettings.instance.scale;
    Widget glyph = Icon(
      icon,
      size: 24 * scale,
      color: selected ? AppColors.footer : Colors.white,
    );
    // Новый звонок и непрочитанное сообщение теперь видно там, где их
    // разбирают, а не в колокольчике.
    if (index == 1) {
      glyph = CountBadge(count: CommsBadgeService.total, child: glyph);
    }
    return InkWell(
      onTap: () => _selectTab(index),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 7 * scale),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.symmetric(
            horizontal: 8 * scale,
            vertical: 4 * scale,
          ),
          decoration: BoxDecoration(
            color: selected ? AppColors.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: glyph,
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

class _TabNavObserver extends AppNavObserver {
  final VoidCallback onChange;

  _TabNavObserver(this.onChange);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    onChange();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    onChange();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    onChange();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    onChange();
  }
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

/// Правая шторка: все визиты подряд по датам. Раньше этот список открывался
/// свайпом вверх по нижней панели, а в шторке жил колокольчик — он переехал
/// в правый верхний угол календаря.
class _AllVisitsDrawer extends StatelessWidget {
  final BuildContext hostContext;
  final VoidCallback onClose;
  final VoidCallback onReturn;

  const _AllVisitsDrawer({
    required this.hostContext,
    required this.onClose,
    required this.onReturn,
  });

  @override
  Widget build(BuildContext context) {
    return Drawer(
      width: MediaQuery.sizeOf(context).width,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(),
      clipBehavior: Clip.hardEdge,
      child: RepaintBoundary(
        child: AllVisitsScreen(
          onLeave: onClose,
          hostContext: hostContext,
          onReturn: onReturn,
        ),
      ),
    );
  }
}

class _RightVisitsHandle extends StatefulWidget {
  final VoidCallback onToggle;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  const _RightVisitsHandle({
    required this.onToggle,
    required this.onOpen,
    required this.onClose,
  });

  @override
  State<_RightVisitsHandle> createState() => _RightVisitsHandleState();
}

class _RightVisitsHandleState extends State<_RightVisitsHandle> {
  double _dragDx = 0;

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.horizontal(left: Radius.circular(14));
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
              child: Icon(
                Icons.event_note,
                color: Color(0xFF14557F),
                size: 19,
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
      right: left ? const Radius.circular(14) : Radius.zero,
      left: left ? Radius.zero : const Radius.circular(14),
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
          child: Icon(Icons.more_vert, color: Color(0xFF14557F), size: 19),
        ),
      ),
    );
  }
}

class _ActiveCallReturnBar extends StatelessWidget {
  const _ActiveCallReturnBar();

  static bool _isLive(String status) {
    return status == 'connected' ||
        status == 'calling' ||
        status == 'connecting' ||
        status == 'ringing' ||
        status == 'answering' ||
        status == 'reconnecting';
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<String>(
      stream: TwilioService.callStatusStream,
      initialData: TwilioService.callStatus,
      builder: (context, snapshot) {
        final status = snapshot.data ?? TwilioService.callStatus;
        if (!_isLive(status) || CallScreen.isShown) {
          return const SizedBox.shrink();
        }
        final active = TwilioService.activeCall;
        final phone = active != null
            ? activeCallDisplayNumber(active)
            : '';
        return Material(
          color: const Color(0xFF2E7D32),
          child: InkWell(
            onTap: () {
              CallScreen.clearMinimized();
              CallScreen.open(
                context,
                phoneNumber: phone,
                isIncoming: active?.callDirection.name == 'incoming',
                resumeExisting: true,
              );
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.phone_in_talk,
                    color: Colors.white,
                    size: 17,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      phone.isNotEmpty
                          ? '${context.tr('Идёт разговор', 'Call in progress')} ($phone) · ${context.tr('Вернуться', 'Return')}'
                          : '${context.tr('Идёт разговор', 'Call in progress')} · ${context.tr('Вернуться к звонку', 'Return to call')}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
