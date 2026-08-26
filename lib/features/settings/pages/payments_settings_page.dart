import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../services/settings_service.dart';
import '../../../services/stripe_service.dart';
import '../../../services/stripe_terminal_service.dart';
import '../widgets/settings_ui.dart';

class PaymentsSettingsPage extends StatefulWidget {
  const PaymentsSettingsPage({super.key});

  @override
  State<PaymentsSettingsPage> createState() => _PaymentsSettingsPageState();
}

class _PaymentsSettingsPageState extends State<PaymentsSettingsPage> {
  bool _loading = true;
  String _reader = SettingsService.cardReaderPhone;
  bool _pairing = false;
  String _status = '';
  StripeReaderStatus _readerStatus = const StripeReaderStatus(
    connected: false,
    name: '',
    isHardware: false,
  );

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = await SettingsService.loadConfig();
    final status = await StripeTerminalService.currentReaderStatus();
    if (!mounted) return;
    setState(() {
      _reader = SettingsService.readCardReader(config);
      _readerStatus = status;
      _loading = false;
    });
  }

  Future<void> _refreshReader() async {
    final status = await StripeTerminalService.currentReaderStatus();
    if (!mounted) return;
    setState(() => _readerStatus = status);
  }

  Future<void> _saveReader(String value) async {
    setState(() => _reader = value);
    await SettingsService.updateConfig('cardReader', value);
  }

  Future<void> _openStripeShop() async {
    final uri = Uri.parse('https://dashboard.stripe.com/terminal/shop');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _pairReader() async {
    setState(() {
      _pairing = true;
      _status = 'Готовлю подключение...'.tr;
    });
    try {
      final name = await StripeTerminalService.pairHardwareReader(
        onStatus: (text) {
          if (!mounted) return;
          setState(() => _status = text);
        },
      );
      if (!mounted) return;
      setState(() => _status = '${'Терминал подключён'.tr}: $name');
      await _refreshReader();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${'Терминал подключён'.tr}: $name'),
          backgroundColor: Colors.green,
        ),
      );
    } on StripeServiceException catch (e) {
      if (!mounted) return;
      setState(() => _status = e.message);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), backgroundColor: Colors.red),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '$e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _pairing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Платежи'.tr,
      body: _loading
          ? Center(child: CircularProgressIndicator(color: AppColors.accent))
          : ListView(
              padding: const EdgeInsets.only(top: 20, bottom: 40),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Text(
                    'Все карточные платежи идут только через Stripe. Можно принять карту на телефоне или на терминале Stripe, который вы покупаете в Dashboard Stripe.'.tr,
                    style: const TextStyle(color: Colors.black54),
                  ),
                ),
                SettingsGroup(
                  children: [
                    SettingsRow(
                      title: _readerStatus.name.isEmpty
                          ? context.tr(
                              'Терминал не подключён',
                              'No terminal connected',
                            )
                          : _readerStatus.name,
                      subtitle: _readerStatus.connected
                          ? context.tr('Активен', 'Active')
                          : context.tr('Не активен', 'Not active'),
                      icon: _readerStatus.isHardware
                          ? Icons.point_of_sale
                          : Icons.contactless,
                      iconColor: _readerStatus.connected
                          ? Colors.green
                          : Colors.blueGrey,
                      trailing: Icon(
                        _readerStatus.connected
                            ? Icons.check_circle
                            : Icons.circle_outlined,
                        color: _readerStatus.connected
                            ? Colors.green
                            : Colors.grey,
                      ),
                      onTap: _pairing ? null : _refreshReader,
                    ),
                    RadioListTile<String>(
                      title: Text('Телефон · Stripe Tap to Pay'.tr),
                      subtitle: Text('Клиент прикладывает карту к задней панели'.tr),
                      value: SettingsService.cardReaderPhone,
                      groupValue: _reader,
                      onChanged: (value) {
                        if (value != null) _saveReader(value);
                      },
                    ),
                    RadioListTile<String>(
                      title: Text('Терминал Stripe'.tr),
                      subtitle: Text(
                        'BBPOS WisePad 3. Карта вставляется или прикладывается, деньги — в Stripe.'.tr,
                      ),
                      value: SettingsService.cardReaderTerminal,
                      groupValue: _reader,
                      onChanged: (value) {
                        if (value != null) _saveReader(value);
                      },
                    ),
                  ],
                ),
                if (_reader == SettingsService.cardReaderTerminal)
                  SettingsGroup(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Text(
                          'Не сопрягайте WisePad 3 в настройках Android Bluetooth — из‑за этого приложение его не видит. Забудьте устройство там, если уже сопрягали.\n\nВключите Геолокацию (точную) и Bluetooth. На WisePad 3 подержите питание, пока не замигает, держите рядом и нажмите «Найти терминал». Если появится код — подтвердите на телефоне и на ридере.'.tr,
                          style: const TextStyle(color: Colors.black54, height: 1.35),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _pairing ? null : _pairReader,
                            child: Text(
                              _pairing
                                  ? 'Ищу терминал…'.tr
                                  : 'Найти терминал'.tr,
                            ),
                          ),
                        ),
                      ),
                      if (_status.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          child: Text(
                            _status,
                            style: TextStyle(
                              color: _pairing ? const Color(0xFF14557F) : Colors.black87,
                              fontWeight: FontWeight.w600,
                              height: 1.35,
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: TextButton(
                          onPressed: _openStripeShop,
                          child: Text('Купить терминал в Stripe'.tr),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
    );
  }
}
