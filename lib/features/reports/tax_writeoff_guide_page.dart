import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import 'reports_screen.dart';

/// Полный экран: что теоретически можно списать в корпорации ремонтного сервиса.
class TaxWriteoffGuidePage extends StatelessWidget {
  const TaxWriteoffGuidePage({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => const TaxWriteoffGuidePage(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sections = _sections(context);
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        title: Text(
          context.tr('Лайфхак: что списать', 'Lifehack: what to write off'),
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [
          _disclaimer(context),
          const SizedBox(height: 12),
          for (final section in sections) ...[
            _sectionCard(context, section),
            const SizedBox(height: 10),
          ],
          _openReportButton(context),
        ],
      ),
    );
  }

  Widget _disclaimer(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4CC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE0C56A)),
      ),
      child: Text(
        context.tr(
          'Это памятка для мастера-корпорации в Онтарио, не налоговая консультация. '
          'Списываете только то, что реально для бизнеса, с чеком. Личное — вычитаете. '
          'HST с чеков идёт в GST34 (строка 108), а не в расход T2. Перед сдачей сверьте с бухгалтером.',
          'This is a shop-owner cheat sheet for an Ontario corporation, not tax advice. '
          'Claim only real business costs with receipts. Back out personal use. '
          'HST on receipts is GST34 line 108, not a T2 expense. Confirm with your accountant.',
        ),
        style: const TextStyle(height: 1.35, fontSize: 13.5),
      ),
    );
  }

  Widget _openReportButton(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ReportsScreen()),
          );
        },
        icon: const Icon(Icons.summarize_outlined),
        label: Text(
          context.tr('Открыть отчёт T2 с цифрами', 'Open T2 report with numbers'),
        ),
      ),
    );
  }

  Widget _sectionCard(BuildContext context, _WriteoffSection section) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: ExpansionTile(
        initiallyExpanded: section.open,
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        leading: Icon(section.icon, color: AppColors.primary),
        title: Text(
          section.title,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
        ),
        subtitle: Text(
          section.gifi,
          style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
        ),
        children: [
          for (final item in section.items)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(Icons.check, size: 16, color: Color(0xFF2E7D32)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(item, style: const TextStyle(height: 1.35, fontSize: 14)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  List<_WriteoffSection> _sections(BuildContext context) {
    String t(String ru, String en) => context.tr(ru, en);
    return [
      _WriteoffSection(
        icon: Icons.local_shipping_outlined,
        title: t('Машина и дорога', 'Vehicle and road'),
        gifi: 'GIFI 9281',
        open: true,
        items: [
          t('Бензин и дизель на выезды к клиентам', 'Fuel for job travel'),
          t('Масло, фильтры, ТО, ремонт, шины, дворники', 'Oil, filters, service, repairs, tires, wipers'),
          t('Страховка авто (коммерческая или доля бизнеса)', 'Vehicle insurance (commercial or business share)'),
          t('Лицензия, регистрация, Safety, эмиссия', 'Licence, registration, safety, emissions'),
          t('Парковка у клиента, 407, платные дороги, мойка если для работы', 'Job parking, 407, tolls, wash if for work'),
          t('Лизинг или проценты по кредиту на рабочую машину (доля бизнеса)', 'Lease or loan interest on the work vehicle (business %)'),
          t('CAA / эвакуатор, если машина рабочая', 'Roadside / tow if it is a work vehicle'),
          t('Журнал пробега обязателен: личные километры не списываете', 'Keep a mileage log: personal km is not deductible'),
        ],
      ),
      _WriteoffSection(
        icon: Icons.settings_outlined,
        title: t('Запчасти и материалы на заявки', 'Parts and job materials'),
        gifi: 'GIFI 8320',
        items: [
          t('Запчасти, которые реально поставили клиенту', 'Parts actually installed for a client'),
          t('Прокладки, хомуты, провод, расходники с заявки', 'Gaskets, clamps, wire, job consumables'),
          t('Не списывайте дважды: если уже в себестоимости счёта — не кладите ещё раз с чека', 'Do not double-count: if already on the invoice cost, do not add the receipt again'),
          t('Склад на конец года (8300/8500) — только если ведёте инвентарь; проще оставить пустым', 'Year-end stock (8300/8500) only if you keep inventory; simpler to leave blank'),
        ],
      ),
      _WriteoffSection(
        icon: Icons.handyman_outlined,
        title: t('Инструмент и оборудование', 'Tools and equipment'),
        gifi: 'GIFI 9270 / CCA',
        items: [
          t('Мелкий инструмент и расходники — обычно расход года', 'Small tools and consumables — usually this year’s expense'),
          t('Дорогой инструмент, стенд, вакуум, весы, анализатор — чаще CCA, не весь сразу', 'Expensive tools, vac, scales, analyser — usually CCA, not all in year one'),
          t('Диагностическое ПО, адаптеры, кабели', 'Diagnostic software, adapters, cables'),
          t('Страховка инструмента', 'Tool insurance'),
          t('Замена украденного или сломанного рабочего инструмента', 'Replacement of stolen or broken work tools'),
        ],
      ),
      _WriteoffSection(
        icon: Icons.health_and_safety_outlined,
        title: t('Страховки бизнеса', 'Business insurance'),
        gifi: 'GIFI 8690',
        items: [
          t('Коммерческая ответственность (CGL)', 'Commercial general liability'),
          t('Ошибки и упущения, если есть', 'Errors and omissions, if you have it'),
          t('Страховка склада / гаража / содержимого', 'Shop / garage / contents insurance'),
          t('WSIB, если платите', 'WSIB if you pay it'),
        ],
      ),
      _WriteoffSection(
        icon: Icons.phone_iphone,
        title: t('Связь и софт', 'Phone, net, software'),
        gifi: 'GIFI 9225',
        items: [
          t('Рабочий телефон и тариф', 'Work phone and plan'),
          t('Twilio, бизнес-номер, SMS, секретарь', 'Twilio, business number, SMS, secretary'),
          t('Интернет дома/в гараже — разумная доля, если по нему CRM и почта', 'Home/shop internet — reasonable share if used for CRM and mail'),
          t('Google Workspace, домен, хостинг сайта', 'Google Workspace, domain, website hosting'),
          t('Карты, навигация, облако, антивирус для рабочего ноутбука', 'Maps, navigation, cloud, antivirus for the work laptop'),
          t('Подписка на схемы, сервисные мануалы, Parts Town и т.п.', 'Service manuals, Parts Town and similar subscriptions'),
        ],
      ),
      _WriteoffSection(
        icon: Icons.account_balance,
        title: t('Банк, Stripe, платежи', 'Bank, Stripe, payments'),
        gifi: 'GIFI 8715',
        items: [
          t('Комиссия Stripe и терминала', 'Stripe and terminal fees'),
          t('Плата за корпоративный счёт, переводы, Interac', 'Corporate account fees, transfers, Interac'),
          t('Эквайринг, аренда терминала', 'Card processing, terminal rental'),
        ],
      ),
      _WriteoffSection(
        icon: Icons.calculate_outlined,
        title: t('Бухгалтер, юрист, налоги', 'Accountant, legal, tax'),
        gifi: 'GIFI 8862',
        items: [
          t('Бухгалтер, книга, T2, GST34', 'Bookkeeper, T2, GST34'),
          t('UFile T2 / TurboTax Business', 'UFile T2 / TurboTax Business'),
          t('Юрист по корпорации, договорам, аренде', 'Lawyer for the corp, contracts, lease'),
          t('Регистрация корпорации, годовые сборы Ontario', 'Corp filing, Ontario annual fees'),
        ],
      ),
      _WriteoffSection(
        icon: Icons.campaign_outlined,
        title: t('Реклама и клиенты', 'Ads and clients'),
        gifi: 'GIFI 8521',
        items: [
          t('Google / Facebook / Instagram реклама', 'Google / Facebook / Instagram ads'),
          t('Google Business, отзывы, профиль', 'Google Business, reviews, profile'),
          t('Сайт, лендинг, визитки, магниты на авто, надпись на машине', 'Website, cards, vehicle magnets / lettering'),
          t('Форма с логотипом (не обычная одежда)', 'Logo uniform (not ordinary clothes)'),
          t('Листовки, вывеска, табличка', 'Flyers, sign, yard sign'),
        ],
      ),
      _WriteoffSection(
        icon: Icons.storefront_outlined,
        title: t('Аренда и помещение', 'Rent and premises'),
        gifi: 'GIFI 8911',
        items: [
          t('Аренда склада, гаража, мастерской', 'Shop / garage / warehouse rent'),
          t('Ячейка хранения запчастей', 'Storage locker for parts'),
          t('Коммуналка помещения: свет, тепло, вода', 'Shop utilities: hydro, heat, water'),
          t('Домашний офис у корпорации — осторожно: нужна отдельная комната и разумная доля', 'Home office in a corp — only a dedicated space and a reasonable share'),
        ],
      ),
      _WriteoffSection(
        icon: Icons.badge_outlined,
        title: t('Люди и зарплата', 'People and wages'),
        gifi: 'GIFI 9060',
        items: [
          t('Зарплата помощнику / второму мастеру', 'Wages for a helper / second tech'),
          t('Работодательская доля CPP / EI', 'Employer CPP / EI'),
          t('Субподряд другого техника (отдельная строка, не путать с зарплатой)', 'Subcontract another tech (separate line, not wages)'),
          t('Дивиденды себе — это не расход компании', 'Dividends to yourself are not a company expense'),
        ],
      ),
      _WriteoffSection(
        icon: Icons.restaurant,
        title: t('Еда и мелкие поездки', 'Meals and small travel'),
        gifi: 'GIFI 8523 · 50%',
        items: [
          t('Обед с клиентом или поставщиком — обычно 50%', 'Meal with a client or supplier — usually 50%'),
          t('Еда в дальней поездке на заявку, если день реально «в поле»', 'Meal on a long job trip if you are genuinely on the road'),
          t('Обычный ежедневный обед «по пути» чаще не проходит', 'Everyday lunch on the way usually does not qualify'),
          t('Отель, если ночёвка из‑за дальнего вызова', 'Hotel if an overnight is required for a distant job'),
        ],
      ),
      _WriteoffSection(
        icon: Icons.cleaning_services_outlined,
        title: t('Расходники, офис, безопасность', 'Supplies, office, safety'),
        gifi: 'GIFI 9200',
        items: [
          t('Перчатки, маски, очки, коврики, химия', 'Gloves, masks, glasses, mats, chemicals'),
          t('Скотч, стяжки, тряпки, пакеты для мусора с ремонта', 'Tape, ties, rags, job garbage bags'),
          t('Бумага, чернила, папки, ручки', 'Paper, ink, folders, pens'),
          t('Аптечка в машине, огнетушитель', 'Van first-aid kit, fire extinguisher'),
        ],
      ),
      _WriteoffSection(
        icon: Icons.school_outlined,
        title: t('Обучение и лицензии', 'Training and licences'),
        gifi: 'GIFI 8862 / dues',
        items: [
          t('Курсы по технике, газ, электрика, сертификаты', 'Appliance, gas, electrical courses and certificates'),
          t('TSSA / газовые лицензии, продление', 'TSSA / gas licence renewals'),
          t('Бизнес-лицензия города, членство в ассоциации', 'Municipal business licence, association dues'),
          t('Книги и платные мануалы', 'Books and paid manuals'),
        ],
      ),
      _WriteoffSection(
        icon: Icons.laptop_mac,
        title: t('Техника для офиса (часто CCA)', 'Office gear (often CCA)'),
        gifi: 'CCA class 8 / 10 / 50',
        items: [
          t('Ноутбук, планшет, принтер, роутер для работы', 'Laptop, tablet, printer, work router'),
          t('Рабочий телефон как устройство (не тариф)', 'Work phone as a device (not the plan)'),
          t('Покупка рабочей машины / фургона — CCA, не весь год целиком', 'Buying the work van — CCA, not the full price in year one'),
        ],
      ),
      _WriteoffSection(
        icon: Icons.receipt_long,
        title: t('HST — отдельно от T2', 'HST — separate from T2'),
        gifi: 'GST34 · line 108',
        items: [
          t('HST, который вы заплатили на рабочих чеках — ITC, строка 108', 'HST you paid on work receipts — ITC, line 108'),
          t('HST, который взяли с клиентов — к уплате, не доход T2', 'HST collected from clients — remitted, not T2 sales'),
          t('В T2 продажи без HST (GIFI 8000)', 'On T2, sales excluding HST (GIFI 8000)'),
        ],
      ),
      _WriteoffSection(
        icon: Icons.block,
        title: t('Обычно нельзя / опасно', 'Usually no / risky'),
        gifi: t('Не списывать как расход', 'Do not claim as an expense'),
        items: [
          t('Штрафы, парковочные и дорожные тикеты', 'Fines, parking and traffic tickets'),
          t('Личная еда, одежда, отпуск, подарки семье', 'Personal food, clothes, vacation, family gifts'),
          t('Личная доля машины, телефона, интернета, дома', 'Personal share of car, phone, internet, home'),
          t('Обычная одежда без логотипа / не спецовка', 'Ordinary clothes that are not a uniform'),
          t('Жизненная страховка хозяина — чаще нельзя', 'Owner life insurance — usually not'),
          t('Дивиденды и «просто снял со счёта»', 'Dividends and cash you simply withdrew'),
          t('Чек без связи с ремонтом или без документа', 'A receipt with no business link or no document'),
        ],
      ),
    ];
  }
}

class _WriteoffSection {
  final IconData icon;
  final String title;
  final String gifi;
  final List<String> items;
  final bool open;

  const _WriteoffSection({
    required this.icon,
    required this.title,
    required this.gifi,
    required this.items,
    this.open = false,
  });
}
