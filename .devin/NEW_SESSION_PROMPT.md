# Fix Appliance CRM — новая Devin-сессия

Продолжи разработку личного Flutter CRM и телефонного секретаря в `C:\Projects\fix_appliance_crm`, ветка `FIX-APP`. Владелец — один человек. Не трогай `C:\Projects\fix_appliance_cloud`.

Перед началом **обязательно** прочитай:

1. `C:\Projects\fix_appliance_crm\.cursor\rules\agent-context.mdc` — основной проектный контекст.
2. `C:\Projects\fix_appliance_crm\.devin\HANDOFF_PROMPT.md` — полный разбор 13 оставшихся пунктов.

## Критические правила

- Не коммить, пока владелец явно не попросит.
- Не размывай безопасность: Firestore, Storage, Functions, Twilio webhooks остаются под auth.
- Не коммить секреты: `lib/core/api_keys.dart`, `functions/.env`, `android/key.properties`, keystore.
- Офлайн-семантику не ломай: не `await` Firestore-записи в UI, используй `settleWrite(...)`.
- PowerShell: `;` вместо `&&`.
- Цвета: зелёный `0xFF22C55E`, жёлтый `0xFFFCC520`, красный `0xFFE53935`, синий `0xFF14557F`.
- FCM: ключ `from` зарезервирован, используй `peer`.
- Два разных ИИ: phone secretary — `functions/`, in-app assistant — `lib/features/ai/assistant/`.

## После Flutter-изменений

```powershell
flutter build apk --release
adb -s R5CW421KFXH install -r build\app\outputs\flutter-apk\app-release.apk
adb -s R5CW421KFXH shell am start -n com.example.fix_appliance_crm/.MainActivity
```

## После изменений Cloud Functions

```powershell
firebase deploy --only functions:aiVoiceRelay,functions:aiVoiceTurn,functions:incomingCall,functions:dialAction,functions:incomingSms,functions:recordingComplete,functions:processCallRecording,functions:aiRelayComplete
```

## 13 оставшихся пунктов

Рекомендуемый порядок:

1. **18** — после отправки сообщения просит подтвердить встречу и шлёт «новая заявка».
2. **17** — повторный звонок клиенту снова спрашивает про подтверждение заказа.
3. **13** — отправка SMS только вручную, с подтверждением владельца.
4. **1** — календарь: перетаскивание карточки шагом 15 минут.
5. **19** — в календаре нельзя двигать выполненные работы.
6. **10** — линия связи заказов в календаре.
7. **17b** — слишком высокая кнопка подтверждения в переписке.
8. **14** — переписка открывается на последнем сообщении.
9. **11** — инвойс: возврат слева вверху, оплата справа вверху.
10. **9** — третья плитка шторки.
11. **4** — зона обслуживания: сразу карта, без вкладок.
12. **5** — ревизия настроек, убрать лишнее.
13. **15** — общая логика и последовательность действий.

## Что делать сейчас

Начни с **пунктов 18, 17 и 13** — они связаны и в основном server-side. Закончи их, затем переходи к календарю. Если сценарий неясен — задай уточняющий вопрос, не делай предположений.
