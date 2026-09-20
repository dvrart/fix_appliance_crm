# Промпт-передача: Fix Appliance CRM — остаток работ

Ты продолжаешь разработку личного Flutter CRM и телефонного секретаря для Fix Appliance CA. Владелец — один человек (FIX). Цель: надёжное, офлайн-работающее, безопасное приложение для Android.

## 0. Обязательно прочитать перед началом

- `C:\Projects\fix_appliance_crm\.cursor\rules\agent-context.mdc` — основной проектный контекст. Читать целиком.
- `C:\Projects\fix_appliance_crm\.devin\config.json` — разрешения.
- Этот файл.

## 1. Параметры

- **Репозиторий:** `C:\Projects\fix_appliance_crm`, ветка **FIX-APP**
- **НЕ трогать:** `C:\Projects\fix_appliance_cloud`
- **Устройство:** Samsung `R5CW421KFXH`
- **Пакет:** `com.example.fix_appliance_crm`
- **Firebase:** `fix-appliance-crm`, компания `fix_appliance_ca`
- **Язык UI:** русский, код на английском
- **PowerShell:** `;` вместо `&&`

### Правила, которые нельзя ломать

1. Не коммить, пока не попросят явно.
2. Не размывать безопасность: `firestore.rules`, `storage.rules`, `functions/auth_guard.js`, `AuthService.headers()` на каждом вызове функции, Twilio/Stripe signature checks, `candidateUrls()` для Gen2.
3. Не коммить секреты: `lib/core/api_keys.dart`, `functions/.env`, `android/key.properties`, keystore.
4. Офлайн: **никогда** не `await` Firestore-запись в UI-пути. Использовать `settleWrite(...)` из `lib/services/network_status_service.dart`.
5. Цвета: зелёный `0xFF22C55E`, жёлтый `0xFFFCC520`, красный `0xFFE53935`, синий `0xFF14557F`.
6. FCM: ключ `from` зарезервирован, использовать `peer`.
7. Live-промпт секретаря — только server-side. Не тащить в него greeting из приложения, чекбоксы, `extraRules`, `learnedRules`. Не возвращать coach chat. Не вешать трубку после «Have a good day».

### Сборка после Flutter-изменений

```powershell
flutter build apk --release
adb -s R5CW421KFXH install -r build\app\outputs\flutter-apk\app-release.apk
adb -s R5CW421KFXH shell am start -n com.example.fix_appliance_crm/.MainActivity
```

### Deploy после Functions-изменений

```powershell
firebase deploy --only functions:aiVoiceRelay,functions:aiVoiceTurn,functions:incomingCall,functions:dialAction,functions:incomingSms,functions:recordingComplete,functions:processCallRecording,functions:aiRelayComplete,functions:onJobWritten,functions:sendVisitReminders,functions:sendSms,functions:smsStatusCallback
```

Логи читать через `node tools/read_logs.js [минут] [сервис|all] [app|req]` — `firebase functions:log` отдаёт устаревшее.

---

## 2. Что реально сделано в прошлой сессии (проверено по коду, задеплоено)

### Пункт 13 — SMS только вручную. Сделано частично

Добавлен флаг `manualSmsApproval` в `settings/config`, **по умолчанию включён** (`boolFlag` в обоих местах имеет fallback `true`).

- `functions/visit_sms.js` `sendBookingIfNeeded`: при `manualSmsApproval` **не** зовёт Twilio, а ставит на визите `smsBookingPending = true`, `smsBookingPendingAt`, `smsBookingDayKey`, `smsBookingSlotKey`, `smsConfirmStatus = 'pending'` и шлёт `notifyMaster('SMS ждёт отправки', …, { type: 'sms', jobId, clientId, from })`.
- `functions/visit_sms.js` `sendDayBeforeReminders`: при `manualSmsApproval` выходит сразу.
- `lib/models/job.dart` `JobVisit`: добавлены поля `smsBookingPending`, `smsBookingPendingAt`, `smsBookingSentSms`, `smsBookingSentEmail`, `smsBookingVia` — читаются/пишутся в `fromMap`/`toMap`/`copyWith`.
- `lib/services/settings_service.dart`: `readManualSmsApproval(config)`.
- `lib/features/settings/pages/communication_settings_page.dart`: плитка «Ручное подтверждение SMS» в разделе SMS.
- `details_tab.dart` `_resendVisitBookingSms`: после ручной отправки пишет `smsBookingVia: 'sms'`, `smsBookingSentSms: true`, сбрасывает `smsBookingPending`.

### Пункт 18 — двойная отправка booking-SMS. Сделано частично

`functions/visit_sms.js` `visitSentSms`: раньше засчитывала отправку только для не-email заявок (`!viaEmail && …`), из-за чего ручная отправка из приложения (где `smsBookingVia` пустой) не считалась отправкой и сервер шлёт SMS второй раз. Теперь любой `smsBookingSentAt` без явного `smsBookingVia` считается отправленным SMS. Плюс `alreadyThisSlot` теперь учитывает `smsBookingPending`.

### Пункт 17 — повторный звонок. Сделано только на уровне текста промпта

- `functions/index.js` `DEFAULT_VOICE_INSTRUCTIONS` и `functions/voice_relay.js` `liveSystemPrompt` — добавлена инструкция: если звонящий известен / есть открытая заявка, приветствовать по имени, уточнить технику и адрес, не просить подтвердить уже подтверждённый визит.

### Инфраструктура

- `flutter analyze` по изменённым файлам — только pre-existing info/warning, новых ошибок нет.
- APK собран и установлен на `R5CW421KFXH`.
- Задеплоены: `aiVoiceRelay`, `aiVoiceTurn`, `incomingCall`, `dialAction`, `incomingSms`, `recordingComplete`, `processCallRecording`, `aiRelayComplete`, `onJobWritten`, `sendVisitReminders`, `sendSms`, `smsStatusCallback`. Логи чистые.
- **Не закоммичено.** `git status` показывает изменения в `functions/index.js`, `functions/visit_sms.js`, `functions/voice_relay.js`, `lib/models/job.dart`, `lib/features/jobs/job_details/tabs/details_tab.dart`, `lib/features/settings/pages/communication_settings_page.dart`, `lib/services/settings_service.dart`.
- Мусор в рабочей копии, разобраться: `functions/_push.tmp.js`, `voice_facts.js` в корне (дубль `functions/voice_facts.js`?), изменённые `linux/`, `macos/`, `windows/` generated_plugin файлы.

---

## 3. Что в 13 / 17 / 18 НЕ доделано — начинать с этого

### 3.1. Пункт 13: нет UI для отложенной SMS (блокирующая дыра)

Сервер ставит `smsBookingPending = true` и присылает пуш «SMS ждёт отправки», но **в приложении это никак не видно**, и владельцу некуда нажать:

- `smsBookingPending` не отображается ни в календаре, ни в списке заявок, ни в карточке заявки.
- Единственная кнопка отправки — `_resendVisitBookingSms` в `details_tab.dart`, спрятана внутри bottom-sheet редактирования визита (`if (existing != null)`, около строки 452) и подписана «Отправить повторное уведомление смс».
- `notification_router.dart` на `type: 'sms'` открывает переписку, а не место, где можно отправить подтверждение визита.

Нужно:
- Показывать состояние «SMS ждёт отправки» на карточке заявки (и желательно бейджем в календаре/списке). Можно расширить `lib/shared/widgets/visit_confirm_badge.dart` — там уже есть статусы pending/confirmed/cancelled/reschedule.
- Дать явную кнопку «Отправить SMS» на видном месте карточки заявки, а не только внутри шита редактирования визита; текст кнопки поправить (сейчас звучит как «повторное»).
- Роутинг пуша `type: 'sms'` + `jobId` должен вести туда, где кнопка.
- Опционально: actions «Отправить» / «Отменить» прямо в шторке (`CrmShadeNotifier.kt`) — пересекается с пунктом 9.

### 3.2. Пункт 13: остались автоматические исходящие SMS

Проверено — эти пути шлют SMS без подтверждения владельца:

- `lib/features/jobs/job_details/tabs/finance_tab.dart` около строки 1964 → `DocumentTemplateService.sendPdfLinkQuietly` — чек клиенту автоматически после оплаты (`if (paid <= 0) return;` и сразу отправка). Реальная автоотправка.
- `lib/features/ai/assistant/assistant_tools.dart` около строки 258 → `SmsService.sendSms` без confirm-шита. Внутриприложный ассистент.
- `lib/services/on_the_way_service.dart` около строки 228 — «я в пути». Проверить, есть ли реальное подтверждение владельца перед отправкой, или только флаг `onTheWayPromptEnabled`.

Уже под подтверждением, не ломать: `job_review_offer.dart` (`showConfirmActionSheet`), `details_tab.dart` (отзыв + booking resend), `conversation_screen.dart`, `finance_tab.dart` строки ~1869 и ~2075, серверный `sendReviewIfNeeded` (требует `requestReviewSms === true`).

**Осознанно оставлено автоматическим:** 13 вызовов `sendSms` в `functions/visit_sms.js` (строки ~1280–1810) — это ответы на входящую SMS клиента (диалог переноса/отмены/подтверждения: `pick_job`, `reschedule_ask`, `cancel_save`, `confirm_confirmed`, `confirm_slot_busy`, `confirm_rescheduled`, `confirm_cancelled`, `confirm_kept`). Если их тоже гейтить, клиент, написавший нам, останется без ответа. **Спросить владельца**, хочет ли он подтверждать и эти ответы, прежде чем что-то менять.

### 3.3. Пункт 17: секретарь не получает фактов об открытой заявке

Промпт велит «не переспрашивать уже подтверждённый визит», но модели **неоткуда это знать**:

- `functions/index.js` `completeAiPickup` (около строки 2638) кладёт в `aiReception` только `clientName`, `knownAddress`, `knownClient`. Открытая заявка не загружается.
- `functions/voice_relay.js` `liveSystemPrompt` / `compactKnown` читают `session.clientName`, `session.knownAddress`, `session.calendarBrief`, `session.extracted` — поля об открытой заявке отсутствуют.

Нужно:
- В `completeAiPickup` (и там, где инициализируется Live-сессия) найти открытую заявку клиента и положить в сессию: техника/бренд, адрес заявки, дата/время визита, `smsConfirmStatus`/подтверждён ли, статус заявки.
- Добавить в `liveSystemPrompt` и в текстовый turn-промпт блок «Open job on file: …» и правило: если визит уже подтверждён — не подтверждать заново, а уточнить, звонок по этой заявке или по новой проблеме.
- Новая информация должна **обновлять** существующую заявку, а не создавать дубль. Проверить `finishAiReception`, `createDraftJobFromCall`, `hasConversationToBook`, `findOpenJobForContact`.
- Использовать `usableClientName` / `isPlaceholderClientName` / `applyPersonNameToClient` — не записывать мусорные имена.
- Не сломать поведение для реально новых звонков.

### 3.4. Пункт 18: исходная жалоба не воспроизведена

Жалоба владельца была: после исходящего SMS/e-mail приходит пуш «новая заявка» и просьба подтвердить встречу. Исправлена только двойная отправка booking-SMS. Сам симптом «новая заявка» **не воспроизводился и не подтверждён как исправленный**.

Нужно:
- Воспроизвести: отправить SMS клиенту из карточки клиента и из карточки заявки, посмотреть логи `node tools/read_logs.js 10 all app`.
- Проверить `processSmsWithAi` в `functions/index.js`: создаёт заявку при `!job && (isIntake || (relevant && channel !== 'email'))`. Убедиться, что ответ клиента на наше исходящее сообщение не порождает вторую заявку при наличии открытой — проверить `findOpenJobForContact`.
- Убедиться, что не приходит пуш «Новая заявка» без явного намерения.

---

## 4. Остальные пункты (не начаты)

Рекомендуемый порядок: **1 → 19 → 10 → 17b → 14 → 11 → 9 → 4 → 5 → 15**.

### Пункт 1 — календарь: drag шагом 15 минут

Перетаскивание заявки привязывается к произвольному времени, должно быть кратно 15 минутам.

- Где: `lib/features/calendar/`, карточка заявки и её drag/drop, `functions/schedule.js` для валидации.
- Округлять новое время до ближайших 15 минут, пересчитывать `startAt` с сохранением длительности.
- Учитывать рабочие часы (`SettingsService.isVisitDay`, `workStartMinutes`/`workEndMinutes`) и занятость слота.
- Проверка: заявка «прилипает» к 7:00, 7:15, 7:30.
- Помнить: визит по умолчанию 2 часа, один заказ на окно, коллизии проверяются на сервере (`resolveJobSchedule`).

### Пункт 19 — нельзя двигать выполненные работы

- Где: `lib/features/calendar/` (`Draggable`/`LongPressDraggable`), `lib/models/job.dart` (статусы, `JobVisit.isDone`, `JobStatuses`).
- Убрать drag у завершённых заявок/визитов, оставить визуальное отличие.
- Проверка: завершённая заявка не поднимается при долгом нажатии.

### Пункт 10 — линии связи заказов в календаре (2 недели / месяц / 3 месяца)

- Где: `lib/features/calendar/` — сетка, overlay, карточки; `lib/services/job_service.dart` — как создаются follow-up/warranty.
- Сначала определить правило связи (клиент + техника? ручная связь? история?) — **уточнить у владельца**, что он хочет видеть.
- Рисовать линию/дугу только для интервалов ~2 недели, ~1 месяц, ~3 месяца. Не перегружать экран.

### Пункт 17b — слишком высокая кнопка подтверждения в переписке

- Где: `lib/features/messages/conversation_screen.dart`, `lib/shared/widgets/confirm_action_sheet.dart`.
- Сделать компактнее или перенести в app bar; действие должно остаться доступным.

### Пункт 14 — переписка открывается на последнем сообщении

- Где: `lib/features/messages/conversation_screen.dart` — `ScrollController`.
- Скроллить к последнему при открытии и при новом сообщении, но **не дёргать**, если владелец читает старое.

### Пункт 11 — инвойс: возврат слева вверху, оплата справа вверху

- Где: карточка заявки, финансовая вкладка `lib/features/jobs/job_details/tabs/finance_tab.dart`, `lib/services/document_template_service.dart` для PDF.
- Поменять расположение блоков refund / payment. Проверить на узком экране.

### Пункт 9 — третья плитка шторки

- Где: `android/app/src/main/kotlin/com/example/fix_appliance_crm/CrmShadeNotifier.kt`, `lib/services/notification_router.dart`, `lib/services/local_notification_service.dart`, `notifyMaster` в `functions/index.js`.
- Третья плитка должна показывать имя ИЛИ телефон и различать типы `sms` / `email` / `call` / `job`.
- Помнить: `notifyMaster` — **data-only** FCM (system notification payload съедается Twilio FCM service). Не удалять каналы уведомлений — это стирает выбранный владельцем звук. Анализ звонка идёт в колокольчик внутри приложения, не в шторку.
- Пересекается с 3.1: сюда же можно добавить actions «Отправить SMS» / «Отменить».

### Пункт 4 — зона обслуживания: сразу карта, без вкладок

- Где: экран зоны в `lib/features/settings/`, плитка «Зона» в `settings_hub_screen.dart`.
- Убрать табы, открывать сразу Google Maps. Инструменты: добавить/переместить/удалить точку, замкнуть полигон. Сохранять в `settings/config`.
- Зону используют секретарь (`outsideAreaRule` в `voice_relay.js`, `serviceArea` в профиле) и поиск адреса. Если зона не задана — секретарь **не** должен отказывать по названию города из памяти.

### Пункт 5 — ревизия настроек

- Схема из 6 секций описана в `agent-context.mdc` (Компания / Расписание / Клиенту / Подключения / Приложение / Данные). Каждая настройка ровно в одном месте.
- Не возвращать: отдельную плитку «Часы» (часы внутри `WorkDaysSettingsPage`), «Шаблоны» внутри «Когда слать», «Зону» внутри «Секретаря».
- Убрать неиспользуемые страницы/плитки. `FinanceSettingsPage` удалён — не возрождать.

### Пункт 15 — общая логика и последовательность

- Высокоуровневое: входящий звонок/письмо → клиент → заявка → визит → инвойс → оплата.
- Устранить конфликты (сообщение не создаёт заявку; повторный звонок не переспрашивает).
- Проверить, что статусы заявки отражают этапы и не дублируются.
- **Обсудить с владельцем до реализации.**

---

## 5. Архитектурные подсказки

### Два разных ИИ — не смешивать

1. **Телефонный секретарь** (Twilio + Gemini Live): `functions/voice_relay.js`, `functions/voice_facts.js`, `functions/index.js`. Меняется деплоем, APK не нужен. Говорит только по-английски. Отвечает 24/7, визиты Пн–Пт 7:00–21:00 Toronto, последний старт 19:00, визит 2 часа, в выходные заказ берём и предлагаем будний день.
2. **Внутриприложный ассистент**: `lib/features/ai/assistant/`.

### Ключевые файлы

Сервер: `functions/index.js`, `voice_relay.js`, `voice_facts.js`, `schedule.js`, `visit_sms.js`, `auth_guard.js`, `email.js`.

Клиент: `lib/services/job_service.dart`, `client_service.dart`, `sms_service.dart`, `settings_service.dart`, `network_status_service.dart`, `auth_service.dart`, `notification_router.dart`; `lib/features/calendar/`, `lib/features/messages/`, `lib/features/jobs/job_details/`, `lib/features/settings/`; `lib/shared/widgets/visit_confirm_badge.dart`, `confirm_action_sheet.dart`, `app_bar_save.dart`.

### Ловушки

- `ScaffoldMessenger.of(context)` рисует под модалкой — валидацию внутри `BottomSheet`/`Dialog` показывать виджетом в том же окне.
- Save — только зелёная галка в app bar (`AppBarSaveButton`), без нижней кнопки «Сохранить».
- Миниатюры фото — только с `cacheWidth`/`cacheHeight`, иначе OOM.
- Не ставить `showWhenLocked`/`turnScreenOn` на `MainActivity` в манифесте.
- `MainActivity` должен остаться `FlutterFragmentActivity` (нужно для `local_auth`).
- Gemini текстовая модель — `gemini-flash-lite-latest`, остальные кандидаты дают 404/429.

## 6. Проверка перед отчётом

1. `flutter analyze <изменённые файлы>` — без новых ошибок.
2. `flutter build apk --release` собирается.
3. APK установлен на `R5CW421KFXH`, изменённый сценарий проверен на устройстве.
4. Для Functions: деплой прошёл + `node tools/read_logs.js 10 all app` чистый.
5. Не коммить без явной просьбы. Не утверждать, что задеплоено/проверено, если этого не было.
6. Если сценарий неясен — задать владельцу конкретный вопрос, не угадывать.

## 7. Телефонный секретарь: обрывы через 60–90 секунд (2026-09-07)

Причина найдена и исправлена; запись «причина пока не найдена» в старом контексте устарела.

- `aiVoiceRelay` уже имел `timeoutSeconds: 3600` в реальном Firebase. Обрывал не Gemini и не этот лимит: Node.js применял HTTP-таймер к WebSocket, поднятому через `handleUpgrade` внутри обычного обработчика HTTP Functions Framework. `headersTimeout` 60 секунд и периодическая проверка соединений давали обрыв через 60–90 секунд. Node отправлял HTTP-ошибку внутрь голосового потока: на клиенте `Invalid WebSocket frame: RSV1 must be clear`, закрытие `1006`, при этом Gemini оставался `up`, `ready=true`.
- `functions/voice_relay.js`: `preserveUpgradedSockets` регистрирует обработчик `clientError` один раз на HTTP-сервер. Только успешно upgraded-сокеты освобождаются от `ERR_HTTP_REQUEST_TIMEOUT`. Другие ошибки закрывают соединение; обычные HTTP-запросы по-прежнему получают 400/408/413/431. Существующие обработчики, включая `once`, сохраняются.
- Не отключать глобально `headersTimeout` / `requestTimeout`, не ослаблять `VOICE_RELAY_KEY` и 15-секундную проверку авторизации. `socket.setTimeout(0)` не решает эту проблему. Не увеличивать число `streamResumes` вместо устранения причины обрыва.
- `functions/voice_relay.test.js` проверяет длительный обмен на двух реальных локальных WebSocket с ускоренными HTTP-таймерами, обычные HTTP-ошибки, другие ошибки WebSocket, старые обработчики, неверный ключ и закрытие неавторизованного сокета через 15 секунд. Gemini и реальные клиенты в этих тестах не вызываются. До исправления тест непрерывного потока падал на Node 22.20.0, после проходит.
- Все серверные тесты: `npm --prefix functions test` из корня. На этапе исправления обрывов прошли 35 проверок. Для проверки именно Node 22 из каталога `functions`: `npx --yes --package=node@22.20.0 -- node --test --test-reporter=tap visit_sms.test.js voice_relay.test.js`.
- Развёрнута только `aiVoiceRelay`: `firebase deploy --only functions:aiVoiceRelay --project fix-appliance-crm --non-interactive`, с `FUNCTIONS_DISCOVERY_TIMEOUT=120`. APK не требуется.
- Реальная проверка relay/Gemini: до исправления соединение оборвалось через 65.409 секунды; после обновления тот же непрерывный поток тишины выдержал 200.545 секунды без переподключения. На 200-й секунде тест сам корректно закрыл WebSocket (`1000`, `verification complete`), Gemini всё ещё был `up`, `ready=true`. В логе появилось `voiceRelay: preserved WebSocket after HTTP request timeout`. Проверка шла без `CallSid`, без звонков клиентам и без создания заявок; обычный телефонный разговор этим тестом не имитировался.
- Проверка журналов: `node tools/read_logs.js 15 aivoicerelay` и `node tools/read_logs.js 15 aivoicerelay req`.

## 8. Естественное приветствие телефонного секретаря

- FIX одобрил остальной разговор и попросил изменить только приветствие. Не менять без отдельной просьбы модель Gemini Live, голос Aoede, скорость реакции, сценарий приёма заказа и исправление обрывов из раздела 7.
- В `greetLive` убрана команда `Speak ONLY this greeting ... No other words`. Первая реплика теперь задаётся как короткое английское приветствие своими словами: спокойно, тепло, без дикторской подачи, рекламных фраз, выдуманного личного имени и нарочитых междометий. Смысл исходного приветствия сохраняется, включая передачу разговора от техника. После приглашения говорить секретарь слушает; новые правила ограничены первым приветствием.
- `DEFAULT_VOICE_GREETING` остаётся смысловым ориентиром и текстом резервного TTS, а не обязательной дословной репликой Gemini. При `greetingSpoken` и при восстановлении Live новое приветствие не запускается.
- `persistSession` для `engine === 'gemini-live'` сохраняет реальную расшифровку, не добавляя в начало истории шаблон `session.greeting`, который модель могла вообще не произнести. Для фиксированного приветствия ConversationRelay прежнее сохранение остаётся.
- Серверный набор теперь содержит 41 проходящий тест: дополнительно проверяются свободная формулировка, handoff, однократность, ожидание готовности, восстановление истории и отсутствие выдуманной реплики в стенограмме.
- Голосовая проверка реального relay без `CallSid` и без звонка клиенту: первый звук через 990 мс, приветствие 2,9 секунды, затем тишина до окончания 14-секундной проверки. Распознанные слова в этом прогоне: «Fix Appliance CA. How can I help you today?» Это пример результата, не новый фиксированный шаблон. Естественность интонации окончательно оценивает FIX при звонке.
- Эти изменения требуют только деплоя `aiVoiceRelay`; APK и остальные функции не менять.

## 9. Паузы в ответах секретаря (2026-09-08)

Клиент пожаловался на длинные паузы. Проделана диагностика и точечная настройка; не делать слепых изменений VAD.

- **Что реально измерено.** По двухканальным записям Twilio (`RequestedChannels=2`, канал 1 = клиент, канал 2 = секретарь): короткий звонок `CA52e838...` — паузы перед ответами 1.26–1.48 c (одна 2.84 c на приветствие); длинный `CAcbb2a2...` двигался без перезапусков 305 c, паузы 0.5–3.0 c, внутри реплик вставки ~0.6–0.7 c.
- **Структура паузы перед ответом.** `silenceDurationMs`=160 (код) + собственная генерация Gemini. Напрямую к Gemini (без нашего relay) те же фразы давали 1.0–1.3 c до первого пакета — то есть номер region/relay добавляет лишь ~0.1–0.2 c. **Большая часть паузы — внутри Gemini 3.1 Live, кодом не убирается.**
- `tools/measure_voice_latency.js --synthetic` — контрольный прогон (три фразы из System.Speech, real-time, без CallSid/звонков): до развёртки по relay 1.07–1.37 c; после настройки дикции 1.23–1.40 c по relay и 1.0–1.3 c напрямую. Считает `baseline` и `silenceCapPreview`; флаги `--direct`, `--prefix=`, `--silence=` замеряют прямое подключение к Gemini с другими VAD без деплоя.
- **Применено:** в `liveSystemPrompt` раздел HOW YOU SOUND переписан на связную речь: реакция и ответ одной фразой, без «silent thinking beat», короткие дыхания на знаках препинания, «Shorten the gaps, not the words». Русскоязычный клиент паузами эту инструкцию не воспримет — но англ. живой разговор укрепляется.
- **Не применено (проверено, пользы нет):** `silenceDurationMs` 160→120 (выигрыш ≤40 мс при риске рвать фразу посередине); `prefixPaddingMs` 200→100 (два прогона — разница в шуме, на телефонном звуке рискует резать первый согласный); обрезка тишины в выходном звуке (от 10 до 70 мс — незаметно). Оставлять `VOICE_SILENCE_MS=160`, `END_SENSITIVITY=HIGH`, `STALL_MS=1100`.
- **Диагностика stall/times:** `voiceLive stall` срабатывает только когда Gemini сама молчит >1.1 c после реплики клиента. Если жалоба повторится — смотреть `node tools/read_logs.js 120 voice` и замерять запись двухканально, а не гадать.
