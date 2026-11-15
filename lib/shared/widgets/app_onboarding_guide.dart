import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_commands.dart';
import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../features/diagnostics/diagnostics_screen.dart';
import '../../features/finance/documents_list_screen.dart';
import '../../features/reports/reports_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/warehouse/warehouse_screen.dart';
import '../../services/auth_service.dart';
import '../app_nav.dart';

class _GuideBullet {
  final IconData icon;
  final String titleRu;
  final String titleEn;
  final String textRu;
  final String textEn;

  const _GuideBullet({
    required this.icon,
    required this.titleRu,
    required this.titleEn,
    required this.textRu,
    required this.textEn,
  });
}

class _GuideStepData {
  final IconData icon;
  final Color color;
  final String titleRu;
  final String titleEn;
  final String subtitleRu;
  final String subtitleEn;
  final List<_GuideBullet> bullets;
  final String? actionLabelRu;
  final String? actionLabelEn;
  final void Function(BuildContext context)? onAction;

  const _GuideStepData({
    required this.icon,
    required this.color,
    required this.titleRu,
    required this.titleEn,
    required this.subtitleRu,
    required this.subtitleEn,
    required this.bullets,
    this.actionLabelRu,
    this.actionLabelEn,
    this.onAction,
  });
}

/// Пошаговый интерактивный гайд по всем функциям и кнопкам приложения.
/// Предлагается автоматически при первом входе и доступен в любой момент
/// из бокового меню и раздела «Настройки → О приложении».
class AppOnboardingGuide {
  AppOnboardingGuide._();

  static String _prefsKey() {
    final uid = AuthService.user.value?.uid.trim() ?? '';
    return 'onboarding_guide_seen_${uid.isEmpty ? 'default' : uid}';
  }

  static Future<void> promptIfFirstTime(BuildContext context) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _prefsKey();
      if (prefs.getBool(key) == true) return;
      await prefs.setBool(key, true);
      if (!context.mounted) return;
      final start = await showDialog<bool>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) {
          return AlertDialog(
            backgroundColor: AppColors.card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.tint(AppColors.primary, 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.menu_book_rounded,
                    color: AppColors.primaryOnCard,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    dialogContext.tr(
                      'Добро пожаловать в CRM!',
                      'Welcome to the CRM!',
                    ),
                    style: TextStyle(
                      color: AppColors.ink,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            content: Text(
              dialogContext.tr(
                'Хотите пройти короткий наглядный гайд по приложению?\n\n'
                    'Покажем, за что отвечает каждая кнопка, как создавать клиентов и заявки, '
                    'выписывать счета и сметы, пользоваться голосовым ИИ, складом, расходами, отчётами и настройками.\n\n'
                    'Открыть этот гайд можно в любой момент из левого меню.',
                'Would you like to take a quick visual tour of the app?\n\n'
                    'We will show what every button does, how to create clients and jobs, '
                    'send invoices and estimates, use the voice AI, warehouse, expenses, reports, and settings.\n\n'
                    'You can also open this guide anytime from the left menu.',
              ),
              style: TextStyle(
                color: AppColors.inkMuted,
                fontSize: 14,
                height: 1.4,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(
                  dialogContext.tr('Позже', 'Later'),
                  style: TextStyle(color: AppColors.inkMuted),
                ),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                icon: const Icon(Icons.play_arrow_rounded, size: 20),
                label: Text(
                  dialogContext.tr('Пройти гайд', 'Start guide'),
                ),
              ),
            ],
          );
        },
      );
      if (start == true && context.mounted) {
        await open(context);
      }
    } catch (_) {}
  }

  static Future<void> open(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _AppOnboardingGuideSheet(),
    );
  }
}

class _AppOnboardingGuideSheet extends StatefulWidget {
  const _AppOnboardingGuideSheet();

  @override
  State<_AppOnboardingGuideSheet> createState() =>
      _AppOnboardingGuideSheetState();
}

class _AppOnboardingGuideSheetState extends State<_AppOnboardingGuideSheet> {
  final PageController _pageController = PageController();
  int _index = 0;

  static void _openPage(BuildContext context, Widget page) {
    Navigator.of(context).pop();
    final nav = AppNav.activeTabNavigator ?? rootNavigatorKey.currentState;
    nav?.push(MaterialPageRoute<void>(builder: (_) => page));
  }

  static void _selectMainTab(BuildContext context, int tab) {
    Navigator.of(context).pop();
    AppCommands.selectTab.value = tab;
  }

  late final List<_GuideStepData> _steps = [
    const _GuideStepData(
      icon: Icons.touch_app_rounded,
      color: Color(0xFF1565C0),
      titleRu: '1. Главный экран, кнопки и жесты',
      titleEn: '1. Main screen, buttons & gestures',
      subtitleRu: 'Как устроена навигация одной рукой',
      subtitleEn: 'One-handed navigation overview',
      bullets: [
        _GuideBullet(
          icon: Icons.view_array_outlined,
          titleRu: 'Три вкладки внизу по центру',
          titleEn: 'Three bottom tabs',
          textRu:
              'Календарь (расписание и карта маршрута), Связь (звонки, SMS и почта) и Клиенты (вся база контактов).',
          textEn:
              'Calendar (schedule & route map), Comms (calls, SMS & email), and Clients (your contact database).',
        ),
        _GuideBullet(
          icon: Icons.swipe_right_outlined,
          titleRu: 'Левое меню (ручка слева внизу или свайп вправо)',
          titleEn: 'Left menu (bottom-left handle or swipe right)',
          textRu:
              'Потяните нижнюю панель вправо или нажмите на левый край внизу — откроется меню: Склад, Диагностика, Статистика, Отчёты, Расходы, Счета, Настройки, Корзина, Очередь запчастей и Поиск.',
          textEn:
              'Swipe right on the bottom bar or tap the bottom-left handle to open Warehouse, Diagnostics, Statistics, Reports, Expenses, Invoices, Settings, Trash, Parts Queue, and Search.',
        ),
        _GuideBullet(
          icon: Icons.swipe_left_outlined,
          titleRu: 'Шторка «Все визиты» (ручка справа внизу или свайп влево)',
          titleEn: 'All Visits drawer (bottom-right handle or swipe left)',
          textRu:
              'Потяните нижнюю панель влево или нажмите правый край внизу — откроется живая лента всех прошлых и будущих выездов по дням.',
          textEn:
              'Swipe left on the bottom bar or tap the bottom-right handle to open the live timeline of all past and upcoming visits.',
        ),
        _GuideBullet(
          icon: Icons.smart_toy_outlined,
          titleRu: 'Голосовой ИИ сверху по центру',
          titleEn: 'Voice AI at the top center',
          textRu:
              'Иконка робота в самой верхней полоске экрана включает голосового помощника мастера.',
          textEn:
              'The robot icon in the top bar launches the hands-free voice assistant.',
        ),
      ],
    ),
    _GuideStepData(
      icon: Icons.calendar_month_rounded,
      color: const Color(0xFF00897B),
      titleRu: '2. Календарь, заявки и маршрут',
      titleEn: '2. Calendar, jobs & route map',
      subtitleRu: 'Как записывать выезды и планировать день',
      subtitleEn: 'Scheduling visits and planning your route',
      actionLabelRu: 'Перейти в Календарь',
      actionLabelEn: 'Go to Calendar',
      onAction: (ctx) => _selectMainTab(ctx, 0),
      bullets: const [
        _GuideBullet(
          icon: Icons.add_circle_outline,
          titleRu: 'Создание заявки с календаря',
          titleEn: 'Create a job from the calendar',
          textRu:
              'Нажмите на любую свободную клетку времени в сетке календаря (или кнопку «+») — откроется форма новой заявки с уже выбранным временем.',
          textEn:
              'Tap any free time slot on the calendar grid (or the "+" button) to create a new job at that time.',
        ),
        _GuideBullet(
          icon: Icons.today_outlined,
          titleRu: 'Виды календаря и возврат на «Сегодня»',
          titleEn: 'Calendar views & jump to Today',
          textRu:
              'Переключайте День, 3 дня, 5 дней, Неделю или Месяц. Двойное нажатие по выбранному виду мгновенно возвращает календарь на сегодняшний день.',
          textEn:
              'Switch between Day, 3-day, 5-day, Week, or Month views. Double-tap the active view chip to jump back to Today.',
        ),
        _GuideBullet(
          icon: Icons.map_outlined,
          titleRu: 'Карта маршрута на день',
          titleEn: 'Daily route map',
          textRu:
              'Нажмите иконку карты в шапке календаря — увидите все заявки дня на карте, сможете поменять порядок объезда и нажать «В путь» для навигации в Google Картах.',
          textEn:
              'Tap the map icon in the calendar header to see all daily stops on the map, reorder them, and launch Google Maps navigation.',
        ),
      ],
    ),
    _GuideStepData(
      icon: Icons.people_alt_rounded,
      color: const Color(0xFF3949AB),
      titleRu: '3. Клиенты и двуязычный поиск',
      titleEn: '3. Clients & bilingual search',
      subtitleRu: 'Как добавлять клиентов и мгновенно находить карточки',
      subtitleEn: 'Adding clients and instant search',
      actionLabelRu: 'Открыть вкладку Клиенты',
      actionLabelEn: 'Open Clients tab',
      onAction: (ctx) => _selectMainTab(ctx, 2),
      bullets: const [
        _GuideBullet(
          icon: Icons.person_add_alt_1_outlined,
          titleRu: 'Создание клиента',
          titleEn: 'Create a client',
          textRu:
              'Перейдите на вкладку «Клиенты» (справа внизу) и нажмите кнопку «+». Начните вводить адрес — Google Карты сами предложат точный дом, город и индекс.',
          textEn:
              'Open the Clients tab (bottom right) and tap "+". Start typing the address for live Google Maps autocomplete.',
        ),
        _GuideBullet(
          icon: Icons.star_outline_rounded,
          titleRu: 'Карточка клиента и история',
          titleEn: 'Client card & history',
          textRu:
              'Внутри карточки клиента видны все его адреса, телефоны, техника, прошлые ремонты и общая сумма оплат. Постоянных клиентов можно отметить звёздочкой.',
          textEn:
              'A client card shows all addresses, phone numbers, appliances, repair history, and total revenue. Mark repeat clients with a star.',
        ),
        _GuideBullet(
          icon: Icons.translate_rounded,
          titleRu: 'Поиск на русском и английском сразу',
          titleEn: 'Bilingual Russian + English search',
          textRu:
              'Строка поиска во вкладке «Клиенты» и кнопка «Поиск» внизу левого меню понимают оба языка: запрос «Смит» найдёт «Smith», а также ищет по номеру телефона, улице и модели техники.',
          textEn:
              'Search understands both Cyrillic and Latin script simultaneously, matching names, phone numbers, streets, and appliance models.',
        ),
      ],
    ),
    const _GuideStepData(
      icon: Icons.handyman_rounded,
      color: Color(0xFFE65100),
      titleRu: '4. Карточка заявки: Детали и Шильдик',
      titleEn: '4. Job card: Details & Nameplate AI',
      subtitleRu: 'Всё, что нужно мастеру у клиента дома',
      subtitleEn: 'Everything you need on site',
      bullets: [
        _GuideBullet(
          icon: Icons.folder_open_outlined,
          titleRu: 'Вкладки-папки сверху: Детали · Финансы · Чат',
          titleEn: 'Folder tabs: Details · Finance · Chat',
          textRu:
              'В шапке заявки слева — имя клиента (нажмите, чтобы открыть его карточку), справа — статус заявки. Под шапкой — переключение между Деталями, Финансами и Чатом.',
          textEn:
              'Tap the client name in the header to open their card, or tap the status chip to change status. Switch between Details, Finance, and Chat below.',
        ),
        _GuideBullet(
          icon: Icons.pin_drop_outlined,
          titleRu: 'Карта места работы и маршрут',
          titleEn: 'Job site map & directions',
          textRu:
              'На карте прямо в карточке видно имя, телефон, адрес и кнопку «Проложить маршрут» в Google Картах.',
          textEn:
              'The map card displays the contact name, phone, street address, and a one-tap Google Maps directions button.',
        ),
        _GuideBullet(
          icon: Icons.camera_alt_outlined,
          titleRu: 'Кнопка «Шильдик» и «Фото»',
          titleEn: 'Nameplate scanner & Photos',
          textRu:
              'Нажмите «Шильдик» и сфотографируйте наклейку на технике — ИИ сам пропишет в заявку бренд, модель и серийный номер. Рядом кнопка «Фото» для снимков поломки и QR-паспорт техники.',
          textEn:
              'Tap "Nameplate" and snap the appliance sticker — AI automatically fills in brand, model, and serial number.',
        ),
        _GuideBullet(
          icon: Icons.lightbulb_outline,
          titleRu: 'Блок «Информация», вкладка «Совет» и повторные выезды',
          titleEn: 'Job Info, AI Advice & Recall visits',
          textRu:
              'В «Информации» записываются жалоба клиента и выполненная работа (с автопереводом RU↔EN), есть синяя вкладка «Совет» с подсказками ИИ по ремонту и история повторных выездов.',
          textEn:
              'Record symptoms and repair notes with auto-translation, check the blue "Advice" tab for AI repair tips, and track recall visits.',
        ),
      ],
    ),
    _GuideStepData(
      icon: Icons.receipt_long_rounded,
      color: const Color(0xFF2E7D32),
      titleRu: '5. Сметы, Счета (PDF) и Оплата',
      titleEn: '5. Estimates, Invoices (PDF) & Payments',
      subtitleRu: 'Как посчитать ремонт, взять подпись и отправить счёт',
      subtitleEn: 'Pricing repairs, signatures, and sending PDFs',
      actionLabelRu: 'Открыть список Счетов',
      actionLabelEn: 'Open Invoices list',
      onAction: (ctx) => _openPage(ctx, const DocumentsListScreen()),
      bullets: const [
        _GuideBullet(
          icon: Icons.calculate_outlined,
          titleRu: 'Вкладка «Финансы» внутри заявки',
          titleEn: 'Finance tab inside a job',
          textRu:
              'Добавляйте строки работ и запчастей (можно выбрать деталь со своего склада или вписать новую), укажите закупочную цену запчасти для точного расчёта чистой прибыли.',
          textEn:
              'Add labor and parts (from your warehouse or custom), and enter part cost so your net profit is calculated accurately.',
        ),
        _GuideBullet(
          icon: Icons.percent_rounded,
          titleRu: 'Налог (HST/GST) и скидка',
          titleEn: 'Tax modes (HST/GST) & discounts',
          textRu:
              'Выбирайте режим налога одной кнопкой: на всю сумму, только на запчасти или без налога. Скидку можно задать суммой или процентом.',
          textEn:
              'Choose tax on everything, tax on parts only, or no tax, and apply flat or percentage discounts.',
        ),
        _GuideBullet(
          icon: Icons.draw_outlined,
          titleRu: 'Подпись клиента, Смета и Счёт в PDF',
          titleEn: 'Client signature, Estimate & Invoice PDF',
          textRu:
              'Клиент может расписаться пальцем прямо на экране. Нажмите «Смета» или «Счёт», чтобы просмотреть PDF с вашим логотипом и отправить его по SMS, почте или в мессенджер.',
          textEn:
              'Capture the client signature on screen, preview the branded PDF Estimate or Invoice, and send it via SMS, email, or share sheet.',
        ),
        _GuideBullet(
          icon: Icons.payments_outlined,
          titleRu: 'Учёт оплат и Депозит',
          titleEn: 'Payments & Deposits',
          textRu:
              'Отмечайте оплату наличными, картой или e-Transfer. Если клиент внёс часть суммы, заявка автоматически получит статус «Депозит».',
          textEn:
              'Record Cash, Card, or e-Transfer payments. Partial payments automatically mark the job as Deposit.',
        ),
      ],
    ),
    _GuideStepData(
      icon: Icons.troubleshoot_rounded,
      color: const Color(0xFFD32F2F),
      titleRu: '6. Голосовой ИИ и Диагностика',
      titleEn: '6. Voice AI & Diagnostics Guide',
      subtitleRu: 'Помощник по ремонту, кодам ошибок и поиску запчастей',
      subtitleEn: 'Repair manual database and part finder',
      actionLabelRu: 'Открыть Диагностику',
      actionLabelEn: 'Open Diagnostics',
      onAction: (ctx) => _openPage(ctx, const DiagnosticsScreen()),
      bullets: const [
        _GuideBullet(
          icon: Icons.record_voice_over_outlined,
          titleRu: 'Голосовой ассистент (иконка робота сверху)',
          titleEn: 'Voice Assistant (top robot icon)',
          textRu:
              'Скажите голосом: «Создай заявку», «Найди клиента», «Покажи расписание на завтра» или «Найди насос на стиралку LG с ценами» — ассистент проверит OEM-каталоги и Amazon.ca.',
          textEn:
              'Ask by voice to create a job, find a client, check tomorrow\'s schedule, or search OEM & Amazon.ca part prices.',
        ),
        _GuideBullet(
          icon: Icons.build_circle_outlined,
          titleRu: 'База знаний «Ошибка и диагностика» (в левом меню)',
          titleEn: 'Errors & Diagnostics database (in left menu)',
          textRu:
              '89 подробных карточек по брендам (Whirlpool, LG, Samsung, Bosch, GE, Miele, Frigidaire и др.): коды ошибок, вход в сервисный тест-режим, сопротивление узлов в Омах и распиновки плат.',
          textEn:
              '89 field service cards covering error codes, service test modes, Ohm specs, and board pinouts across major brands.',
        ),
      ],
    ),
    _GuideStepData(
      icon: Icons.inventory_2_rounded,
      color: const Color(0xFFEF6C00),
      titleRu: '7. Склад и Очередь запчастей',
      titleEn: '7. Warehouse & Parts Queue',
      subtitleRu: 'Учёт деталей в наличии и контроль заказов',
      subtitleEn: 'Inventory tracking and parts on order',
      actionLabelRu: 'Открыть Склад',
      actionLabelEn: 'Open Warehouse',
      onAction: (ctx) => _openPage(ctx, const WarehouseScreen()),
      bullets: const [
        _GuideBullet(
          icon: Icons.qr_code_scanner_rounded,
          titleRu: 'Склад запчастей (левое меню → «Склад»)',
          titleEn: 'Parts Warehouse (left menu → Warehouse)',
          textRu:
              'Добавляйте детали вручную или сканируйте номер с коробки камерой. Приложение само подтянет фото детали из интернета и покажет совместимые замены (кросс-номера).',
          textEn:
              'Add parts manually or scan the box label with your camera. The app automatically fetches part photos and cross-reference numbers.',
        ),
        _GuideBullet(
          icon: Icons.local_shipping_outlined,
          titleRu: 'Очередь запчастей (иконка посылки внизу левого меню)',
          titleEn: 'Parts Queue (parcel icon at bottom of left menu)',
          textRu:
              'Все заявки со статусом «Ожидание запчасти» собираются в единый список, чтобы вы видели, какую деталь кому нужно заказать и установить.',
          textEn:
              'All jobs marked "Waiting for Part" appear in one queue so you never lose track of parts to order or install.',
        ),
      ],
    ),
    _GuideStepData(
      icon: Icons.bar_chart_rounded,
      color: const Color(0xFF00695C),
      titleRu: '8. Расходы, Отчёты и Статистика',
      titleEn: '8. Expenses, Reports & Statistics',
      subtitleRu: 'Сканирование чеков камерой и подсчёт чистой прибыли',
      subtitleEn: 'AI receipt scanner and financial reports',
      actionLabelRu: 'Открыть Отчёты',
      actionLabelEn: 'Open Reports',
      onAction: (ctx) => _openPage(ctx, const ReportsScreen()),
      bullets: const [
        _GuideBullet(
          icon: Icons.document_scanner_outlined,
          titleRu: 'Раздел «Расходы» со сканером чеков ИИ',
          titleEn: 'Expenses with AI receipt scanner',
          textRu:
              'В левом меню откройте «Расходы» и сфотографируйте чек (запчасти, бензин, инструмент, еда) — ИИ сам заполнит магазин, дату, категорию, сумму и налог.',
          textEn:
              'Open Expenses in the left menu and snap a photo of any receipt — AI extracts the vendor, date, category, amount, and tax.',
        ),
        _GuideBullet(
          icon: Icons.assessment_outlined,
          titleRu: 'Разделы «Отчёты» и «Статистика»',
          titleEn: 'Reports & Statistics',
          textRu:
              'Смотрите выручку по наличным, картам и переводам, себестоимость запчастей, расходы по категориям, налог HST/GST и чистую прибыль за любой период.',
          textEn:
              'Track revenue by payment method, parts cost, expenses by category, collected tax, and net profit for any date range.',
        ),
      ],
    ),
    _GuideStepData(
      icon: Icons.settings_suggest_rounded,
      color: const Color(0xFF5E35B1),
      titleRu: '9. Настройка приложения под себя',
      titleEn: '9. Customizing Settings',
      subtitleRu: 'С чего начать настройку вашей базы',
      subtitleEn: 'Setting up your workshop profile',
      actionLabelRu: 'Открыть Настройки',
      actionLabelEn: 'Open Settings',
      onAction: (ctx) => _openPage(ctx, const SettingsScreen()),
      bullets: const [
        _GuideBullet(
          icon: Icons.business_outlined,
          titleRu: 'Реквизиты компании и логотип',
          titleEn: 'Company details & logo',
          textRu:
              'В левом меню нажмите на название компании сверху или плитку «Настройки». Укажите название вашей мастерской, телефон, почту, налоговый номер и загрузите логотип для счетов.',
          textEn:
              'Open Settings from the left menu to set your company name, phone, email, tax number, and logo for PDF invoices.',
        ),
        _GuideBullet(
          icon: Icons.map_outlined,
          titleRu: 'Прайс, Рабочие дни и Зона выезда',
          titleEn: 'Pricing, Working days & Service area',
          textRu:
              'Задайте стоимость вызова/диагностики в «Прайс», отметьте свои рабочие дни и часы, а в «Зоне» обведите на карте города, где вы работаете.',
          textEn:
              'Set your service call fee, working hours, and draw your service area polygon on the map.',
        ),
        _GuideBullet(
          icon: Icons.palette_outlined,
          titleRu: 'Вид, язык, шаблоны SMS и резервная копия',
          titleEn: 'Appearance, language, SMS templates & backup',
          textRu:
              'В разделе «Вид» переключайте русский/английский язык, размер шрифта, цвета и ночной режим. В «О приложении» всегда можно снова открыть этот гайд или сменить аккаунт.',
          textEn:
              'Switch between Russian and English, adjust font size, colors, and night mode in Display settings. Re-open this guide anytime in About.',
        ),
      ],
    ),
  ];

  void _goTo(int page) {
    final target = page.clamp(0, _steps.length - 1);
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final step = _steps[_index];
    final isLast = _index == _steps.length - 1;
    return Container(
      height: MediaQuery.sizeOf(context).height * 0.88,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
            decoration: BoxDecoration(
              color: step.color,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        context.tr(
                          'Гайд по приложению · ${_index + 1} из ${_steps.length}',
                          'App Guide · ${_index + 1} of ${_steps.length}',
                        ),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(step.icon, color: Colors.white, size: 28),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            context.tr(step.titleRu, step.titleEn),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            context.tr(step.subtitleRu, step.subtitleEn),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: List.generate(_steps.length, (i) {
                    final active = i == _index;
                    return Expanded(
                      child: GestureDetector(
                        onTap: () => _goTo(i),
                        child: Container(
                          height: 5,
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          decoration: BoxDecoration(
                            color: active
                                ? Colors.white
                                : Colors.white.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              itemCount: _steps.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, pageIndex) {
                final item = _steps[pageIndex];
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                  children: [
                    for (final b in item.bullets)
                      Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.card,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(9),
                              decoration: BoxDecoration(
                                color: AppColors.tint(item.color, 0.14),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                b.icon,
                                color: item.color,
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    context.tr(b.titleRu, b.titleEn),
                                    style: TextStyle(
                                      color: AppColors.ink,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    context.tr(b.textRu, b.textEn),
                                    style: TextStyle(
                                      color: AppColors.inkMuted,
                                      fontSize: 13.5,
                                      height: 1.38,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (item.onAction != null &&
                        item.actionLabelRu != null) ...[
                      const SizedBox(height: 4),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: item.color,
                          side: BorderSide(color: item.color, width: 1.4),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onPressed: () => item.onAction!(context),
                        icon: const Icon(Icons.open_in_new_rounded, size: 18),
                        label: Text(
                          context.tr(
                            item.actionLabelRu!,
                            item.actionLabelEn ?? item.actionLabelRu!,
                          ),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
            decoration: BoxDecoration(
              color: AppColors.card,
              border: Border(top: BorderSide(color: AppColors.border)),
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  if (_index > 0)
                    TextButton.icon(
                      onPressed: () => _goTo(_index - 1),
                      icon: const Icon(Icons.arrow_back_rounded, size: 18),
                      label: Text(context.tr('Назад', 'Back')),
                    )
                  else
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(
                        context.tr('Закрыть', 'Close'),
                        style: TextStyle(color: AppColors.inkMuted),
                      ),
                    ),
                  const Spacer(),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: step.color,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () {
                      if (isLast) {
                        Navigator.of(context).pop();
                      } else {
                        _goTo(_index + 1);
                      }
                    },
                    icon: Icon(
                      isLast ? Icons.check_rounded : Icons.arrow_forward_rounded,
                      size: 18,
                    ),
                    label: Text(
                      isLast
                          ? context.tr('Понятно, начать работу', 'Got it, start')
                          : context.tr('Далее', 'Next'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
