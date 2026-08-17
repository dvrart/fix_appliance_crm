import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Для правильного закрытия приложения
import '../widgets/custom_drawer.dart';
import 'jobs_screen.dart';
import 'calendar_screen.dart';
import 'clients_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  // Создаем три независимых навигатора (по одному для каждой вкладки)
  final List<GlobalKey<NavigatorState>> _navigatorKeys = [
    GlobalKey<NavigatorState>(),
    GlobalKey<NavigatorState>(),
    GlobalKey<NavigatorState>(),
  ];

  final List<Widget> _screens = [
    const JobsScreen(),
    const CalendarScreen(),
    const ClientsScreen(),
  ];

  final List<String> _titles = ['Заявки', 'Календарь', 'Клиенты'];

  void _selectTab(int index) {
    if (_currentIndex == index) {
      // Если мы уже на этой вкладке и нажимаем её еще раз — сбрасываем историю в начало (как в Instagram)
      _navigatorKeys[index].currentState?.popUntil((route) => route.isFirst);
    } else {
      setState(() => _currentIndex = index);
    }
  }

  @override
  Widget build(BuildContext context) {
    // PopScope правильно обрабатывает системную кнопку "Назад" (на Android)
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;

        final navigator = _navigatorKeys[_currentIndex].currentState;
        if (navigator != null && navigator.canPop()) {
          // Если внутри текущей вкладки открыта карточка — просто идем назад
          navigator.pop();
        } else {
          // Если история вкладки пуста
          if (_currentIndex != 0) {
            _selectTab(0); // Перекидываем на главную (Заявки)
          } else {
            SystemNavigator.pop(); // Закрываем приложение, если мы уже на главной
          }
        }
      },
      child: Scaffold(
        // ВАЖНО: Мы убрали AppBar отсюда! Он теперь создается индивидуально для каждой вкладки.
        // За счет этого нижнее меню всегда будет "прибито" к низу экрана.
        body: IndexedStack(
          index: _currentIndex,
          children: [_buildTab(0), _buildTab(1), _buildTab(2)],
        ),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: _selectTab,
          type: BottomNavigationBarType.fixed,
          selectedItemColor: const Color(0xFF14557F),
          unselectedItemColor: Colors.grey,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.list_alt),
              label: 'Заявки',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.calendar_month),
              label: 'Календарь',
            ),
            BottomNavigationBarItem(icon: Icon(Icons.people), label: 'Клиенты'),
          ],
        ),
      ),
    );
  }

  // Волшебная функция, которая оборачивает каждый экран в свой собственный "пузырь" навигации
  Widget _buildTab(int index) {
    return Navigator(
      key: _navigatorKeys[index],
      onGenerateRoute: (routeSettings) {
        return MaterialPageRoute(
          builder: (context) {
            return Scaffold(
              appBar: AppBar(
                title: Text(
                  _titles[index],
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                backgroundColor: const Color(0xFF14557F),
                foregroundColor: Colors.white,
              ),
              drawer:
                  const CustomDrawer(), // У каждой вкладки теперь есть свое боковое меню
              body: _screens[index],
            );
          },
        );
      },
    );
  }
}
