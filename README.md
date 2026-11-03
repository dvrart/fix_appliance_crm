# FIX Appliance CRM

CRM мастерской по ремонту бытовой техники FIX Appliance CA (Торонто): заявки, визиты,
клиенты, счета и оплаты, склад запчастей, звонки и SMS, Care Plan, отчёты.
Приложение — Flutter под Android, сервер — Firebase (Firestore, Storage, Cloud Functions).
Входящие звонки, на которые мастер не ответил, принимает голосовой секретарь
(Twilio + Gemini Live, запасной — OpenAI Realtime).

## Где что лежит

- `lib/` — приложение: `features/` экраны, `services/` работа с данными, `models/` модели.
- `functions/` — Cloud Functions: звонки и секретарь, SMS, почта, Stripe, резервная копия.
- `test/` и `functions/*.test.js` — тесты приложения и сервера.
- `third_party/` — пропатченные копии `twilio_voice` и `flutter_pcm_sound`.
- `tools/` — разовые скрипты для разбора живых звонков и журналов.
- `.cursor/rules/agent-context.mdc` — подробные заметки для агентов: что сделано и чего не возвращать.

## Ключи

В репозитории ключей нет. Скопируйте `lib/core/api_keys.example.dart` в
`lib/core/api_keys.dart` и заполните. Ключи сервера — в `functions/.env`,
подпись релиза — `android/key.properties`. Эти файлы не коммитятся.

## Сборка и установка

    flutter build apk --release --split-per-abi
    adb install -r build\app\outputs\flutter-apk\app-arm64-v8a-release.apk

Пакет — `ca.fixappliance.crm`. То же самое делает `deploy_apk.bat`.

## Сервер

    npm --prefix functions test
    firebase deploy --only functions:<имя функции>

## Проверки

На каждый push GitHub Actions (`.github/workflows/checks.yml`) запускает
`flutter analyze --no-fatal-infos` (предупреждений должно быть ноль), `flutter test`,
сборку релизного APK, `npm test` в `functions` и проверку правил доступа.
