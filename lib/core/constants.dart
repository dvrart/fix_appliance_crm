import 'package:flutter/material.dart';
import 'api_keys.dart';
import 'l10n/app_locale.dart';
import 'ui_scale.dart';

/// ID текущей компании. Все данные живут в `companies/{kCompanyId}/...`.
/// Позже, когда появятся другие компании по подписке, этот id будет
/// браться из аккаунта, а не из константы — пути в Firestore не меняются.
const String kCompanyId = 'fix_appliance_ca';

/// Новый визит по умолчанию — 2 часа (как у секретаря в календаре).
const int kDefaultVisitMinutes = 120;

/// Письма с формы WordPress на сайте — отдельная переписка, не карточка клиента.
const String kWebsiteInboxTitle = 'веб-сайт';

/// Google API Key (для обратной совместимости)
const String kGoogleApiKey = kGoogleMapsApiKey;

/// Фирменные цвета. Меняются в Настройки → Экран и шрифт.
class AppColors {
  static bool get isDark => AppUiSettings.instance.darkNow;
  static NightShadePreset get _shade => AppUiSettings.instance.nightShade;
  static Color get primary => AppUiSettings.instance.primaryColor;
  static Color get footer => AppUiSettings.instance.footerColor;
  static Color get accent => AppUiSettings.instance.accentColor;
  static Color get danger => AppUiSettings.instance.dangerColor;
  static Color get surface => AppUiSettings.instance.surfaceColor;
  static Color get drawerHeader => AppUiSettings.instance.drawerHeaderColor;
  static Color get card => isDark ? _shade.card : Colors.white;
  static Color get cardMuted =>
      isDark ? _shade.cardMuted : const Color(0xFFF3F6F9);
  static Color get selectedCard =>
      isDark ? _shade.selectedCard : const Color(0xFFE8EEF4);
  static Color get ink => isDark ? _shade.ink : const Color(0xFF1A1A1A);
  static Color get inkMuted =>
      isDark ? _shade.inkMuted : const Color(0xFF5F6770);
  static Color get border => isDark ? _shade.border : const Color(0xFFE0E4E8);
  static Color get nonWorkingHour =>
      isDark ? _shade.nonWorking : const Color(0xFFF3F4F6);
  static Color get primaryOnCard =>
      isDark ? Color.lerp(primary, Colors.white, 0.48)! : primary;
  static Color tint(Color color, [double alpha = 0.12]) => Color.alphaBlend(
    color.withValues(alpha: isDark ? (alpha * 1.6).clamp(0.0, 0.45) : alpha),
    card,
  );
}

/// Звёздочка постоянного клиента рядом с именем.
class RegularClientStar extends StatelessWidget {
  final double size;
  final bool onDark;
  final EdgeInsetsGeometry padding;

  const RegularClientStar({
    super.key,
    this.size = 17,
    this.onDark = false,
    this.padding = const EdgeInsets.only(left: 4),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Tooltip(
        message: 'Постоянный клиент'.tr,
        child: Icon(
          Icons.star_rounded,
          size: size,
          color: onDark ? AppColors.accent : const Color(0xFFF59E0B),
        ),
      ),
    );
  }
}

/// Статусы заявок
class JobStatuses {
  static const String call = 'Вызов';
  static const String waiting = 'Ожидание';
  static const String inProgress = 'В работе';
  static const String deposit = 'Депозит';
  static const String rescheduled = 'Перенос';
  static const String waitingPart = 'Ожидание запчасти';
  static const String waitingPayment = 'Ожидание оплаты';
  static const String install = 'Установка';
  static const String callBack = 'Позвонить';
  static const String repeatVisit = 'Повторный визит';
  static const String repeat = 'Повтор';
  static const String completed = 'Завершено';
  static const String cancelled = 'Отменено';

  static const List<String> all = [
    call,
    waiting,
    waitingPayment,
    deposit,
    waitingPart,
    install,
    repeatVisit,
    callBack,
    repeat,
    rescheduled,
    completed,
    cancelled,
  ];

  /// Не предлагаем вручную: «В работе» убран, «Перенос» ставится сам,
  /// «Повтор» («Перенесено») ставит только createRepeatFrom — перенос визита
  /// делается статусами «Установка» и «Повторный визит», и новый визит
  /// добавляется в ту же заявку.
  static const List<String> hideFromPicker = [inProgress, rescheduled, repeat];

  static String defaultLabel(String status) {
    switch (status) {
      case waiting:
      case 'ОЖИДАНИЕ':
        return 'Ожидание';
      case waitingPayment:
        return 'Ожидание Оплаты';
      case waitingPart:
        return 'Запчасти';
      case completed:
        return 'Готово';
      case cancelled:
        return 'Отмена';
      case repeat:
        return 'Перенесено';
      default:
        return status;
    }
  }

  static String _fold(String status) => status.trim().toLowerCase();

  static bool isInstallStatus(String status) {
    final n = _fold(status);
    return n == _fold(install) || n == 'install' || n == 'installation';
  }

  static bool isCompletedStatus(String status) {
    if (isInstallStatus(status)) return false;
    final n = _fold(status);
    return n == _fold(completed) ||
        n == 'готов' ||
        n == 'готово' ||
        n == 'готова' ||
        n == 'completed' ||
        n == 'ready';
  }

  static bool isDepositStatus(String status) {
    final n = _fold(status);
    return n == _fold(deposit) ||
        n == 'взят депозит' ||
        n == 'депозит взят' ||
        n == 'deposit' ||
        n == 'deposit taken';
  }

  /// Клиент внёс часть суммы по счёту → статус «Депозит» ставим сами.
  /// «Ожидание запчасти» не трогаем: иначе заявка выпадет из очереди
  /// запчастей (фургон). Закрытые заявки тоже не поднимаем.
  static bool shouldMarkDeposit(String currentStatus) {
    if (isDepositStatus(currentStatus)) return false;
    if (isClosed(currentStatus)) return false;
    if (_fold(currentStatus) == _fold(waitingPart)) return false;
    return true;
  }

  static bool isCancelledStatus(String status) {
    final n = _fold(status);
    return n == _fold(cancelled) ||
        n == 'отмена' ||
        n.contains('отмен') ||
        n == 'cancelled' ||
        n == 'canceled' ||
        n == 'cancel';
  }

  static bool isClosed(String status) =>
      isCompletedStatus(status) || isCancelledStatus(status);

  /// На календаре: полоска после визита (готово / отмена / запчасть / перенос).
  static bool isCompactAgendaStatus(String status) {
    return isCompletedStatus(status) ||
        isCancelledStatus(status) ||
        status == waitingPart ||
        status == rescheduled;
  }

  /// «Депозит» автопереносом не перетираем: деньги клиента важнее метки
  /// переноса, статус снимет сам мастер или закрытие заявки.
  static bool canMarkRescheduled(String status) =>
      !isClosed(status) && !isInstallStatus(status) && !isDepositStatus(status);

  /// After «Ожидание запчасти», the return visit is installation — not «Перенос».
  static bool shouldMarkInstallOnReturnVisit({
    required String currentStatus,
    required bool isNewVisit,
  }) {
    return isNewVisit && currentStatus == waitingPart;
  }

  static bool shouldMarkRescheduledOnNewVisit({
    required String currentStatus,
    required bool alreadyHasVisits,
  }) {
    if (!canMarkRescheduled(currentStatus)) return false;
    // Return after a part → «Установка», not «Перенос».
    if (currentStatus == waitingPart) return false;
    return alreadyHasVisits;
  }

  /// Second visit, or an existing visit moved to another day.
  static bool shouldWriteRescheduled(
    String currentStatus, {
    required bool mark,
  }) {
    if (!mark) return false;
    if (!canMarkRescheduled(currentStatus)) return false;
    if (currentStatus == rescheduled) return false;
    return true;
  }

  static bool isPickerAlias(String status) {
    if (all.contains(status) || status == inProgress) return false;
    return isCompletedStatus(status) ||
        isCancelledStatus(status) ||
        isInstallStatus(status) ||
        isDepositStatus(status);
  }

  static Color fallbackColor(String status) {
    switch (status) {
      case call:
        return Colors.blue;
      case inProgress:
        return AppColors.accent;
      case deposit:
        return const Color(0xFFFFB300);
      case rescheduled:
        return Colors.deepPurple;
      case waitingPart:
        return Colors.orange;
      case waitingPayment:
        return const Color(0xFF546E7A);
      case install:
        return const Color(0xFF3F51B5);
      case callBack:
        return const Color(0xFF00897B);
      case repeatVisit:
        return const Color(0xFF5C6BC0);
      case repeat:
        return const Color(0xFF8E24AA);
      case completed:
        return Colors.green;
      case cancelled:
        return Colors.red;
      default:
        const palette = [
          Colors.teal,
          Colors.purple,
          Colors.indigo,
          Colors.brown,
          Colors.cyan,
          Colors.deepOrange,
        ];
        // Стабильный хеш: String.hashCode случаен при каждом запуске,
        // поэтому цвет «чужого» статуса прыгал между перезапусками.
        var hash = 0;
        for (final unit in status.codeUnits) {
          hash = (hash * 31 + unit) & 0x7fffffff;
        }
        return palette[hash % palette.length];
    }
  }

  static Color getColor(String status) => fallbackColor(status);

  /// Firestore keeps Russian status values; this is only for the UI.
  static String label(String status) => trAny(status);
}

/// Приоритеты
class JobPriorities {
  static const String low = '🟢 Обычный';
  static const String medium = '🟡 Средний';
  static const String high = '🔴 Срочный';

  static const List<String> all = [low, medium, high];

  static Color getColor(String priority) {
    if (priority.contains('🔴')) return AppColors.danger;
    if (priority.contains('🟡')) return AppColors.accent;
    return Colors.green;
  }

  static String label(String priority) => trAny(priority);
}

/// Категории техники
class ApplianceCategories {
  static const List<Map<String, dynamic>> all = [
    {'name': 'Все', 'icon': Icons.apps},
    {'name': 'Холодильник', 'icon': Icons.kitchen},
    {'name': 'Стиральная машина', 'icon': Icons.local_laundry_service},
    {'name': 'Сушилка', 'icon': Icons.heat_pump},
    {'name': 'Плита/Духовка', 'icon': Icons.countertops},
    {'name': 'Посудомойка', 'icon': Icons.local_dining},
    {'name': 'Универсальное', 'icon': Icons.build},
  ];

  static IconData getIcon(String type) {
    final t = type.toLowerCase();
    if (t.contains('мороз') || t.contains('freezer')) {
      return Icons.ac_unit;
    }
    if (t.contains('холод') ||
        t.contains('fridge') ||
        t.contains('refrigerator')) {
      return Icons.kitchen;
    }
    if (t.contains('посуд') || t.contains('dish')) {
      return Icons.local_dining;
    }
    if (t.contains('стирал') || t.contains('washer') || t.contains('washing')) {
      return Icons.local_laundry_service;
    }
    if (t.contains('суш') || t.contains('dryer')) {
      return Icons.heat_pump;
    }
    if (t.contains('вароч') || t.contains('cooktop') || t.contains('hob')) {
      return Icons.countertops;
    }
    if (t.contains('плит') ||
        t.contains('духов') ||
        t.contains('stove') ||
        t.contains('oven')) {
      return Icons.countertops;
    }
    if (t.contains('микроволн') || t.contains('microwave')) {
      return Icons.microwave;
    }
    return Icons.electrical_services;
  }

  static Color logoColor(String type) {
    final t = type.toLowerCase();
    if (t.contains('мороз') || t.contains('freezer')) {
      return const Color(0xFF0277BD);
    }
    if (t.contains('холод') ||
        t.contains('fridge') ||
        t.contains('refrigerator')) {
      return const Color(0xFF1565C0);
    }
    if (t.contains('посуд') || t.contains('dish')) {
      return const Color(0xFF5E35B1);
    }
    if (t.contains('стирал') || t.contains('washer') || t.contains('washing')) {
      return const Color(0xFF00897B);
    }
    if (t.contains('суш') || t.contains('dryer')) {
      return const Color(0xFFEF6C00);
    }
    if (t.contains('вароч') || t.contains('cooktop') || t.contains('hob')) {
      return const Color(0xFF00897B);
    }
    if (t.contains('плит') ||
        t.contains('духов') ||
        t.contains('stove') ||
        t.contains('oven')) {
      return const Color(0xFFD84315);
    }
    if (t.contains('микроволн') || t.contains('microwave')) {
      return const Color(0xFF6A1B9A);
    }
    return const Color(0xFF546E7A);
  }
}

/// Налоговые ставки
class TaxRates {
  static const double hst = 0.13;
  static const double gst = 0.05;
  static const double none = 0.0;

  static String getLabel(double rate) {
    if (rate == hst) return 'HST 13%'.tr;
    if (rate == gst) return 'GST 5%'.tr;
    return 'Без налога'.tr;
  }
}
