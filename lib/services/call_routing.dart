/// Как звонить: через приложение (интернет, Twilio Voice), через обычную
/// сотовую связь (SIM) или «приложение, а при сбое звука — SIM».
///
/// Решение FIX (27.10.2026). Режим и номер SIM лежат в `settings/config`
/// (`callRoute`, `masterCellNumber`); те же поля читает сервер
/// (`functions/call_route.js`). Без номера SIM любой режим работает как
/// «приложение». В «авто» на SIM переходит только звонок, у которого не
/// поднялся звук, следующий снова идёт через приложение (решение FIX).
enum CallRoute { app, cell, auto }

class CallRouting {
  const CallRouting({this.route = CallRoute.app, this.cellNumber = ''});

  static const routeKey = 'callRoute';
  static const cellKey = 'masterCellNumber';

  /// Сколько ждать звук в приложении, прежде чем считать связь плохой.
  /// Обычно он приходит за 1–2 секунды; 26.10.2026 удачный звонок
  /// поднимался 8 секунд, а неудачные не поднимались вовсе.
  static const audioTimeout = Duration(seconds: 7);

  final CallRoute route;
  final String cellNumber;

  factory CallRouting.fromConfig(Map<String, dynamic> config) {
    final raw = (config[routeKey] ?? '').toString().trim();
    final route = CallRoute.values.firstWhere(
      (value) => value.name == raw,
      orElse: () => CallRoute.app,
    );
    return CallRouting(
      route: route,
      cellNumber: normalizePhone((config[cellKey] ?? '').toString()),
    );
  }

  bool get hasCell => cellNumber.isNotEmpty;

  CallRoute get effective => hasCell ? route : CallRoute.app;

  bool get outboundViaCell => effective == CallRoute.cell;

  bool get autoFallback => effective == CallRoute.auto;

  CallRouting copyWith({CallRoute? route, String? cellNumber}) => CallRouting(
        route: route ?? this.route,
        cellNumber: cellNumber ?? this.cellNumber,
      );

  /// E.164 для Канады/США; пустая строка, если на телефон не похоже.
  static String normalizePhone(String raw) {
    final trimmed = raw.trim();
    final digits = trimmed.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 10) return '+1$digits';
    if (digits.length == 11 && digits.startsWith('1')) return '+$digits';
    if (trimmed.startsWith('+') && digits.length >= 8 && digits.length <= 15) {
      return '+$digits';
    }
    return '';
  }

  /// +15195550123 → +1 (519) 555-0123.
  static String pretty(String e164) {
    final digits = e164.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 11 && digits.startsWith('1')) {
      return '+1 (${digits.substring(1, 4)}) ${digits.substring(4, 7)}-${digits.substring(7)}';
    }
    return e164;
  }
}
