import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_commands.dart';
import '../core/haptics.dart';
import '../shared/widgets/edge_peek_button.dart';
import '../widgets/custom_drawer.dart';
import 'calendar_screen.dart';
import 'clients_screen.dart';
import 'create_job_screen.dart';
import 'job_details_screen.dart';
import 'jobs_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  static const int _calendarTab = 1;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final List<GlobalKey<NavigatorState>> _navigatorKeys = [
    GlobalKey<NavigatorState>(),
    GlobalKey<NavigatorState>(),
    GlobalKey<NavigatorState>(),
  ];
  late final List<_TabNavObserver> _observers;

  int _currentIndex = 0;
  bool _showExitBar = false;
  bool _tabCanPop = false;

  final List<Widget> _screens = const [
    JobsScreen(),
    CalendarScreen(),
    ClientsScreen(),
  ];

  final List<String> _titles = const ['Заявки', 'Календарь', 'Клиенты'];

  @override
  void initState() {
    super.initState();
    _observers = [
      _TabNavObserver(onChanged: _syncCanPop),
      _TabNavObserver(onChanged: _syncCanPop),
      _TabNavObserver(onChanged: _syncCanPop),
    ];
    AppCommands.openTabIndex.addListener(_onOpenTabCommand);
  }

  @override
  void dispose() {
    AppCommands.openTabIndex.removeListener(_onOpenTabCommand);
    super.dispose();
  }

  void _onOpenTabCommand() {
    final index = AppCommands.openTabIndex.value;
    if (index < 0 || index > 2 || !mounted) return;
    AppCommands.openTabIndex.value = -1;
    _selectTab(index);
  }

  void _syncCanPop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final canPop =
          _navigatorKeys[_currentIndex].currentState?.canPop() ?? false;
      if (canPop != _tabCanPop) {
        setState(() => _tabCanPop = canPop);
      }
    });
  }

  void _selectTab(int index) {
    AppHaptics.tab();
    if (_currentIndex == index) {
      _navigatorKeys[index].currentState?.popUntil((route) => route.isFirst);
    }
    setState(() {
      _currentIndex = index;
      _showExitBar = false;
    });
    _syncCanPop();
  }

  Future<void> _handleBack() async {
    final navigator = _navigatorKeys[_currentIndex].currentState;
    if (navigator != null && navigator.canPop()) {
      AppHaptics.button();
      navigator.pop();
      _syncCanPop();
      return;
    }

    if (_currentIndex != _calendarTab) {
      AppHaptics.tab();
      setState(() {
        _currentIndex = _calendarTab;
        _showExitBar = false;
      });
      AppCommands.showCalendarWeek();
      _syncCanPop();
      return;
    }

    AppCommands.showCalendarWeek();

    if (!_showExitBar) {
      AppHaptics.button();
      setState(() => _showExitBar = true);
      return;
    }

    AppHaptics.button();
    SystemNavigator.pop();
  }

  void _openNotifications() {
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFF4F6F8),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => const _NotificationsSheet(),
    );
  }

  void _createJob() {
    AppHaptics.button();
    _navigatorKeys[_calendarTab].currentState?.push(
      MaterialPageRoute(builder: (_) => const CreateJobScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showFab = _currentIndex == _calendarTab && !_tabCanPop && !_showExitBar;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBack();
      },
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: const Color(0xFFF5F7FA),
        drawer: const CustomDrawer(),
        body: IndexedStack(
          index: _currentIndex,
          children: [
            _buildTab(0),
            _buildTab(1),
            _buildTab(2),
          ],
        ),
        floatingActionButton: showFab
            ? Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: FloatingActionButton(
                  heroTag: 'calendar_add_fab',
                  backgroundColor: const Color(0xFFFCC520),
                  foregroundColor: Colors.black,
                  onPressed: _createJob,
                  child: const Icon(Icons.add),
                ),
              )
            : null,
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_showExitBar) const _ExitAppBar(),
            SafeArea(
              top: false,
              child: SizedBox(
                height: 58,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    BottomNavigationBar(
                      currentIndex: _currentIndex,
                      onTap: _selectTab,
                      type: BottomNavigationBarType.fixed,
                      selectedItemColor: const Color(0xFF14557F),
                      unselectedItemColor: Colors.grey,
                      elevation: 8,
                      items: [
                        BottomNavigationBarItem(
                          icon: const Icon(Icons.list_alt),
                          label: _titles[0],
                        ),
                        BottomNavigationBarItem(
                          icon: const Icon(Icons.calendar_month),
                          label: _titles[1],
                        ),
                        BottomNavigationBarItem(
                          icon: const Icon(Icons.people),
                          label: _titles[2],
                        ),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: EdgePeekButton(
                        alignment: Alignment.centerLeft,
                        icon: Icons.menu,
                        tooltip: 'Меню',
                        onTap: () => _scaffoldKey.currentState?.openDrawer(),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: StreamBuilder<QuerySnapshot>(
                        stream: FirebaseFirestore.instance
                            .collection('companies')
                            .doc('fix_appliance_ca')
                            .collection('jobs')
                            .where('needsReview', isEqualTo: true)
                            .snapshots(),
                        builder: (context, snapshot) {
                          final count = snapshot.data?.docs.length ?? 0;
                          return EdgePeekButton(
                            alignment: Alignment.centerRight,
                            icon: count > 0
                                ? Icons.notifications_active
                                : Icons.notifications_none,
                            tooltip: 'Уведомления',
                            badgeCount: count,
                            onTap: _openNotifications,
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTab(int index) {
    return Navigator(
      key: _navigatorKeys[index],
      observers: [_observers[index]],
      onGenerateRoute: (_) {
        return MaterialPageRoute(
          builder: (_) => SafeArea(bottom: false, child: _screens[index]),
        );
      },
    );
  }
}

class _TabNavObserver extends NavigatorObserver {
  final VoidCallback onChanged;

  _TabNavObserver({required this.onChanged});

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onChanged();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onChanged();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onChanged();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      onChanged();
}

class _ExitAppBar extends StatelessWidget {
  const _ExitAppBar();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFD32F2F),
      child: InkWell(
        onTap: () {
          AppHaptics.button();
          SystemNavigator.pop();
        },
        child: const SafeArea(
          top: false,
          bottom: false,
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Center(
              child: Text(
                'Выйти из приложения',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NotificationsSheet extends StatelessWidget {
  const _NotificationsSheet();

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.9,
      builder: (context, controller) {
        return Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Уведомления',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF14557F),
                  ),
                ),
              ),
            ),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('companies')
                    .doc('fix_appliance_ca')
                    .collection('jobs')
                    .where('needsReview', isEqualTo: true)
                    .snapshots(),
                builder: (context, snapshot) {
                  final docs = snapshot.data?.docs ?? [];
                  if (docs.isEmpty) {
                    return const Center(
                      child: Text(
                        'Нет новых уведомлений',
                        style: TextStyle(color: Colors.black54),
                      ),
                    );
                  }
                  return ListView.builder(
                    controller: controller,
                    itemCount: docs.length,
                    itemBuilder: (context, index) {
                      final doc = docs[index];
                      final data = doc.data() as Map<String, dynamic>;
                      final name = (data['clientName'] ??
                              data['client_name'] ??
                              'Заявка')
                          .toString();
                      return ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: Color(0xFF14557F),
                          child: Icon(Icons.smart_toy, color: Color(0xFFFCC520)),
                        ),
                        title: Text(name),
                        subtitle: const Text('ИИ создал заявку — проверьте'),
                        onTap: () {
                          AppHaptics.button();
                          Navigator.pop(context);
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => JobDetailsScreen(
                                jobId: doc.id,
                                clientId: (data['clientId'] ?? '').toString(),
                                jobData: data,
                              ),
                            ),
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
