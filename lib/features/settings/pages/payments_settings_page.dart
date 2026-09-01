import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../services/settings_service.dart';
import '../../../services/stripe_service.dart';
import '../../../services/stripe_terminal_service.dart';
import '../widgets/settings_ui.dart';

enum _PaymentsSection { hub, reader, terminal }

class PaymentsSettingsPage extends StatefulWidget {
  const PaymentsSettingsPage({super.key}) : _sectionIndex = 0;

  const PaymentsSettingsPage._at(this._sectionIndex, {super.key});

  final int _sectionIndex;

  _PaymentsSection get _section =>
      _PaymentsSection.values[_sectionIndex.clamp(0, 2)];

  @override
  State<PaymentsSettingsPage> createState() => _PaymentsSettingsPageState();
}

class _PaymentsSettingsPageState extends State<PaymentsSettingsPage> {
  bool _loading = true;
  String _reader = SettingsService.cardReaderPhone;
  String _savedReader = SettingsService.cardReaderPhone;
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

  void _open(_PaymentsSection section) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PaymentsSettingsPage._at(section.index),
      ),
    ).then((_) {
      if (mounted && widget._section == _PaymentsSection.hub) _load();
    });
  }

  Future<void> _load() async {
    final config = await SettingsService.loadConfig();
    final status = await StripeTerminalService.currentReaderStatus();
    if (!mounted) return;
    setState(() {
      _reader = SettingsService.readCardReader(config);
      _savedReader = _reader;
      _readerStatus = status;
      _loading = false;
    });
  }

  Future<void> _refreshReader() async {
    final status = await StripeTerminalService.currentReaderStatus();
    if (!mounted) return;
    setState(() => _readerStatus = status);
  }

  bool get _readerDirty =>
      !_loading &&
      widget._section == _PaymentsSection.reader &&
      _reader != _savedReader;

  void _pickReader(String value) {
    setState(() => _reader = value);
  }

  Future<bool> _saveReader() async {
    await SettingsService.updateConfigMap({'cardReader': _reader});
    if (!mounted) return true;
    setState(() => _savedReader = _reader);
    return true;
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

  String _readerModeLabel() {
    if (_reader == SettingsService.cardReaderTerminal) {
      return context.tr('Терминал', 'Terminal');
    }
    return 'Tap to Pay';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return SettingsPageScaffold(
        title: 'Платежи'.tr,
        body: Center(child: CircularProgressIndicator(color: AppColors.accent)),
      );
    }
    switch (widget._section) {
      case _PaymentsSection.hub:
        return _buildHub();
      case _PaymentsSection.reader:
        return _buildReaderPick();
      case _PaymentsSection.terminal:
        return _buildTerminal();
    }
  }

  Widget _buildHub() {
    return SettingsPageScaffold(
      title: 'Платежи'.tr,
      body: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Все карточные платежи идут только через Stripe.'.tr,
              style: const TextStyle(color: Colors.black54),
            ),
          ),
          SettingsTileSection(
            title: 'Stripe'.tr,
            tiles: [
              SettingsHubTile(
                title: _readerStatus.name.isEmpty
                    ? context.tr('Терминал', 'Terminal')
                    : _readerStatus.name,
                subtitle: _readerStatus.connected
                    ? context.tr('Активен', 'Active')
                    : context.tr('Не активен', 'Not active'),
                icon: _readerStatus.isHardware
                    ? Icons.point_of_sale
                    : Icons.contactless,
                color: _readerStatus.connected ? Colors.green : Colors.blueGrey,
                active: _readerStatus.connected,
                onTap: _refreshReader,
              ),
              SettingsHubTile(
                title: context.tr('Способ', 'Method'),
                subtitle: _readerModeLabel(),
                icon: Icons.payment,
                color: const Color(0xFF635BFF),
                onTap: () => _open(_PaymentsSection.reader),
              ),
              if (_reader == SettingsService.cardReaderTerminal)
                SettingsHubTile(
                  title: context.tr('WisePad', 'WisePad'),
                  subtitle: context.tr('Найти', 'Pair'),
                  icon: Icons.bluetooth_searching,
                  color: Colors.teal,
                  onTap: () => _open(_PaymentsSection.terminal),
                ),
              SettingsHubTile(
                title: context.tr('Магазин', 'Shop'),
                subtitle: 'stripe.com',
                icon: Icons.shopping_cart_outlined,
                color: Colors.indigo,
                onTap: _openStripeShop,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildReaderPick() {
    return SettingsPageScaffold(
      title: context.tr('Способ оплаты', 'Payment method'),
      dirty: _readerDirty,
      onSave: _saveReader,
      body: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 32),
        children: [
          SettingsTileSection(
            title: 'Stripe'.tr,
            tiles: [
              SettingsHubTile(
                title: 'Tap to Pay',
                subtitle: context.tr('Телефон', 'Phone'),
                icon: Icons.contactless,
                color: const Color(0xFF635BFF),
                active: _reader == SettingsService.cardReaderPhone,
                onTap: () => _pickReader(SettingsService.cardReaderPhone),
              ),
              SettingsHubTile(
                title: context.tr('Терминал', 'Terminal'),
                subtitle: 'WisePad 3',
                icon: Icons.point_of_sale,
                color: Colors.teal,
                active: _reader == SettingsService.cardReaderTerminal,
                onTap: () => _pickReader(SettingsService.cardReaderTerminal),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTerminal() {
    return SettingsPageScaffold(
      title: context.tr('WisePad 3', 'WisePad 3'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text(
            'Не сопрягайте WisePad 3 в настройках Android Bluetooth — из‑за этого приложение его не видит. Забудьте устройство там, если уже сопрягали.\n\nВключите Геолокацию (точную) и Bluetooth. На WisePad 3 подержите питание, пока не замигает, держите рядом и нажмите «Найти терминал».'.tr,
            style: const TextStyle(color: Colors.black54, height: 1.35),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _pairing ? null : _pairReader,
              child: Text(
                _pairing ? 'Ищу терминал…'.tr : 'Найти терминал'.tr,
              ),
            ),
          ),
          if (_status.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              _status,
              style: TextStyle(
                color: _pairing ? const Color(0xFF14557F) : Colors.black87,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
