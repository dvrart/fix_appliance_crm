import 'package:flutter/material.dart';

import '../core/app_commands.dart';
import '../services/sms_service.dart';
import 'unsaved_navigation_gate.dart';

/// Стек карточек. Заявки, клиенты и переписки открываются только через
/// [AppNav.openCard], и тогда «Назад» не перематывает всё, что открывали за
/// день:
///
/// * уже открытая карточка не кладётся второй копией — навигатор возвращается
///   к той, что лежит в стеке (заявка → клиент → та же заявка = два экрана, а
///   не три);
/// * глубже [maxCards] карточек стек не растёт — самая старая снимается молча;
/// * выход на корень вкладки снимает промежуточные экраны без анимации, видно
///   только последний переход.
///
/// Чтобы это работало, к каждому навигатору должен быть подключён
/// [AppNavObserver] — он и есть источник порядка страниц.
class AppNav {
  AppNav._();

  /// Сколько карточек держим в одной ветке. Шестая снимает самую старую:
  /// «Назад» обязан выводить на главную за несколько нажатий.
  static const int maxCards = 5;

  static const String _cardPrefix = 'card:';

  static final Map<NavigatorState, AppNavObserver> _observers =
      <NavigatorState, AppNavObserver>{};

  static NavigatorState? Function()? _tabNavigatorGetter;

  /// Привязывает навигатор текущей вкладки [MainScreen], чтобы все экраны
  /// открывались внутри области над нижним меню.
  static void bindTabNavigator(NavigatorState? Function()? getter) {
    _tabNavigatorGetter = getter;
  }

  /// Активный навигатор вкладки внутри [MainScreen] (если он смонтирован).
  static NavigatorState? get activeTabNavigator {
    final nav = _tabNavigatorGetter?.call();
    if (nav != null && nav.mounted) return nav;
    return null;
  }

  /// Навигатор для открытия любого экрана так, чтобы нижнее меню оставалось
  /// на месте. Если [context] находится в корневом навигаторе (боковое меню,
  /// шторка уведомлений, модальное окно), переключается на навигатор активной
  /// вкладки; в изолированных тестах без [MainScreen] берёт [Navigator.of].
  static NavigatorState navigatorOf(BuildContext context) {
    final tabNav = activeTabNavigator;
    if (tabNav != null) {
      final local = Navigator.maybeOf(context);
      if (local != null &&
          local.mounted &&
          !identical(local, rootNavigatorKey.currentState)) {
        return local;
      }
      return tabNav;
    }
    return Navigator.of(context);
  }

  /// Наблюдатель корневого навигатора (`MaterialApp.navigatorObservers`).
  static final AppNavObserver rootObserver = AppNavObserver();

  static String jobKey(String id) => '${_cardPrefix}job:${id.trim()}';

  static String clientKey(String id) => '${_cardPrefix}client:${id.trim()}';

  /// Переписка узнаётся по собеседнику: телефон (последние 10 цифр, как в
  /// [SmsService.normalizePhone]), иначе почта. Если переписка открыта из
  /// конкретной заявки ([jobId]), ключ включает заявку, чтобы выбор
  /// «Хозяин / Арендатор адреса» не смешивался с карточкой клиента.
  static String chatKey({
    String phone = '',
    String? email,
    String? jobId,
    bool websiteInbox = false,
  }) {
    if (websiteInbox) return '${_cardPrefix}chat:website';
    final jid = (jobId ?? '').trim();
    final scope = jid.isEmpty ? '' : ':job:$jid';
    final digits = SmsService.normalizePhone(phone);
    if (digits.isNotEmpty) return '${_cardPrefix}chat:$digits$scope';
    return '${_cardPrefix}chat:${(email ?? '').trim().toLowerCase()}$scope';
  }

  static bool isCard(Route<dynamic> route) =>
      route.settings.name?.startsWith(_cardPrefix) ?? false;

  /// Страницы навигатора снизу вверх. Диалоги и шторки сюда не попадают.
  static List<Route<dynamic>> pagesOf(NavigatorState navigator) =>
      _observers[navigator]?.pages ?? const <Route<dynamic>>[];

  /// Открывает карточку [key]. Если она уже в стеке — возвращается к ней.
  static Future<T?> openCard<T>(
    BuildContext context, {
    required String key,
    required WidgetBuilder builder,
    bool rootNavigator = false,
  }) async {
    final navigator = navigatorOf(context);
    final existing = _find(navigator, key);
    if (existing != null) {
      if (!existing.isCurrent) {
        if (!await UnsavedNavigationGate.allowLeave(host: context)) return null;
        if (!navigator.mounted || !existing.isActive) return null;
        backTo(navigator, existing);
      }
      // Ждём закрытия карточки, как ждал бы `Navigator.push`.
      return existing.popped.then((value) => value is T ? value : null);
    }
    final result = navigator.push<T>(
      MaterialPageRoute<T>(builder: builder, settings: RouteSettings(name: key)),
    );
    _trim(navigator);
    return result;
  }

  /// Возвращает к [target]: всё, что над ним, снимается молча, и только
  /// верхняя страница уходит со своей анимацией.
  static void backTo(NavigatorState navigator, Route<dynamic> target) {
    final pages = pagesOf(navigator);
    final from = pages.indexOf(target);
    if (from < 0) return;
    for (final route in pages.skip(from + 1)) {
      if (route.isActive && !route.isCurrent) navigator.removeRoute(route);
    }
    navigator.popUntil((route) => route == target);
  }

  /// Выход на корень навигатора: промежуточные экраны снимаются без анимации.
  /// Если есть несохранённые правки, один раз спрашиваем подтверждение через
  /// [UnsavedNavigationGate.allowLeave], а затем снимаем верхний экран напрямую
  /// через [NavigatorState.pop] (без бесконечного цикла `maybePop`, когда
  /// экран держит `PopScope(canPop: false)` ради переключения внутренних вкладок).
  static Future<void> popToRoot(NavigatorState navigator) async {
    if (!navigator.mounted || !navigator.canPop()) return;
    if (UnsavedNavigationGate.hasUnsavedWork) {
      final allowed = await UnsavedNavigationGate.allowLeave(
        host: navigator.context,
      );
      if (!allowed || !navigator.mounted || !navigator.canPop()) return;
    }
    collapse(navigator);
    if (navigator.mounted && navigator.canPop()) {
      navigator.pop();
    }
  }

  /// Снимает всё между корнем и верхней страницей — без анимации и без вопросов.
  static void collapse(NavigatorState navigator) {
    for (final route in pagesOf(navigator).skip(1)) {
      if (route.isActive && !route.isCurrent) navigator.removeRoute(route);
    }
  }

  /// Полный сброс стека до корня, без анимации: для вкладки, которую покинули.
  /// Несохранённые правки не трогаем — иначе работа пропадёт молча.
  static void resetToRoot(NavigatorState navigator) {
    if (UnsavedNavigationGate.hasUnsavedWork) return;
    for (final route in pagesOf(navigator).skip(1).toList().reversed) {
      if (route.isActive) navigator.removeRoute(route);
    }
  }

  static Route<dynamic>? _find(NavigatorState navigator, String key) {
    Route<dynamic>? found;
    for (final route in pagesOf(navigator)) {
      if (route.isActive && route.settings.name == key) found = route;
    }
    return found;
  }

  /// Снимает самые старые карточки сверх [maxCards]. Если где-то есть
  /// несохранённые правки — пропускаем: лучше длинный стек, чем потерянная
  /// работа.
  static void _trim(NavigatorState navigator) {
    if (UnsavedNavigationGate.hasUnsavedWork) return;
    final cards = pagesOf(navigator).where(isCard).toList();
    for (var i = 0; cards.length - i > maxCards; i++) {
      final route = cards[i];
      if (!route.isActive || route.isFirst || route.isCurrent) continue;
      navigator.removeRoute(route);
    }
  }
}

/// Возврат на панель, которой нет в стеке маршрутов: левое меню, правая
/// шторка «Все визиты», нижний лист «Без даты визита», поиск. Такая панель при
/// открытии экрана закрывается, и «Назад» возвращал не её, а то, что лежало
/// под ней, — список приходилось открывать заново.
///
/// [open] запоминает страницу, над которой открылся экран, и возвращает
/// панель, только если экран закрыли именно «Назад»: стек вернулся ровно на
/// ту же страницу и никто не отменил возврат. Экран могли снять и без
/// «Назад» — лимитом [AppNav.maxCards], сбросом покинутой вкладки
/// ([AppNav.resetToRoot]) или выходом на главную; тогда панели поверх чужого
/// экрана делать нечего.
class PanelReturn {
  PanelReturn._();

  /// Пауза перед возвратом: панель во весь экран, и без неё её выезд
  /// накладывается на ещё непрозрачный уходящий экран.
  static const Duration _settle = Duration(milliseconds: 140);

  static int _generation = 0;

  /// Отменяет все ожидающие возвраты. Зовётся на переходах, которые уводят
  /// совсем в другое место: смена вкладки, выход на главную.
  static void cancel() => _generation++;

  /// Открывает экран через [push] и возвращает панель вызовом [back].
  /// Пустой [back] — обычное открытие, возвращать нечего.
  static Future<T?> open<T>(
    NavigatorState navigator, {
    required Future<T?> Function() push,
    required VoidCallback? back,
  }) async {
    final before = AppNav.pagesOf(navigator);
    final under = before.isEmpty ? null : before.last;
    final generation = _generation;
    final result = await push();
    if (back == null || under == null) return result;
    await Future<void>.delayed(_settle);
    if (_generation != generation || !navigator.mounted) return result;
    final pages = AppNav.pagesOf(navigator);
    if (pages.isNotEmpty && identical(pages.last, under)) back();
    return result;
  }
}

/// Помнит порядок страниц своего навигатора: без него нельзя снять экран из
/// середины стека — у [NavigatorState] такого списка наружу нет.
class AppNavObserver extends NavigatorObserver {
  final List<Route<dynamic>> _pages = <Route<dynamic>>[];
  NavigatorState? _owner;

  /// Копия списка: по нему ходят, пока удаляют маршруты.
  List<Route<dynamic>> get pages => List<Route<dynamic>>.unmodifiable(_pages);

  /// Навигатор пересоздали (перезапуск приложения, новый тест) — старые
  /// страницы к нему отношения не имеют.
  void _attach() {
    final nav = navigator;
    if (nav == null || identical(nav, _owner)) return;
    AppNav._observers.remove(_owner);
    _owner = nav;
    _pages.clear();
    AppNav._observers[nav] = this;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _attach();
    if (route is PageRoute) _pages.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _pages.remove(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _pages.remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _attach();
    final at = oldRoute == null ? -1 : _pages.indexOf(oldRoute);
    if (at < 0) {
      if (newRoute is PageRoute) _pages.add(newRoute);
      return;
    }
    if (newRoute is PageRoute) {
      _pages[at] = newRoute;
    } else {
      _pages.removeAt(at);
    }
  }
}
