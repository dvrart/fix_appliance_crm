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
  const CallRouting({
    this.route = CallRoute.app,
    this.cellNumber = '',
    this.outgoingRoute,
  });

  static const routeKey = 'callRoute';
  static const cellKey = 'masterCellNumber';

  /// Исходящие отдельно от входящих (решение FIX, 02.11.2026: входящие —
  /// приложение, исходящие — «авто»). Нет поля — исходящие как входящие.
  /// Сервер это поле не читает: звонок с SIM он узнаёт по номеру.
  static const outgoingKey = 'callRouteOutgoing';

  /// Сколько ждать звук в приложении, прежде чем считать связь плохой.
  /// Обычно он приходит за 1–2 секунды; 26.10.2026 удачный звонок
  /// поднимался 8 секунд, а неудачные не поднимались вовсе.
  static const audioTimeout = Duration(seconds: 7);

  final CallRoute route;
  final String cellNumber;
  final CallRoute? outgoingRoute;

  static CallRoute? _parse(Object? value) {
    final raw = (value ?? '').toString().trim();
    for (final item in CallRoute.values) {
      if (item.name == raw) return item;
    }
    return null;
  }

  factory CallRouting.fromConfig(Map<String, dynamic> config) {
    return CallRouting(
      route: _parse(config[routeKey]) ?? CallRoute.app,
      cellNumber: normalizePhone((config[cellKey] ?? '').toString()),
      outgoingRoute: _parse(config[outgoingKey]),
    );
  }

  bool get hasCell => cellNumber.isNotEmpty;

  /// Входящие.
  CallRoute get effective => hasCell ? route : CallRoute.app;

  /// Исходящие.
  CallRoute get effectiveOutgoing =>
      hasCell ? (outgoingRoute ?? route) : CallRoute.app;

  bool get outboundViaCell => effectiveOutgoing == CallRoute.cell;

  /// Входящий без звука переводится на SIM сам.
  bool get autoFallback => effective == CallRoute.auto;

  /// Исходящий без звука перезванивается через SIM сам.
  bool get outboundAutoFallback => effectiveOutgoing == CallRoute.auto;

  CallRouting copyWith({
    CallRoute? route,
    String? cellNumber,
    CallRoute? outgoingRoute,
  }) => CallRouting(
    route: route ?? this.route,
    cellNumber: cellNumber ?? this.cellNumber,
    outgoingRoute: outgoingRoute ?? this.outgoingRoute,
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
