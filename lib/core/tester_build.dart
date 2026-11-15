/// Сборка для внешних тестировщиков (`--dart-define=TESTER_APP=true`
/// или копия в `C:\Projects\fix_appliance_testers`).
/// В основной рабочей CRM владельца всегда `false`.
const bool kTesterAppBuild = bool.fromEnvironment(
  'TESTER_APP',
  defaultValue: false,
);
