import 'package:flutter/material.dart';
import '../../../core/constants.dart';
import '../../../services/settings_service.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../shared/widgets/app_bar_save.dart';
import '../../../shared/widgets/dirty_leave_scope.dart';

class DocumentSettingsPage extends StatefulWidget {
  const DocumentSettingsPage({super.key});

  @override
  State<DocumentSettingsPage> createState() => _DocumentSettingsPageState();
}

class _DocumentSettingsPageState extends State<DocumentSettingsPage> {
  final _invoiceTerms = TextEditingController();
  final _estimateTerms = TextEditingController();
  final _validDays = TextEditingController();
  final _prefix = TextEditingController();
  final _nextInvoice = TextEditingController();
  final _nextEstimate = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;
  bool _showLogo = true;
  bool _showQr = true;
  bool _showPayments = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _prefix.removeListener(_onNumberPreview);
    _nextInvoice.removeListener(_onNumberPreview);
    _invoiceTerms.dispose();
    _estimateTerms.dispose();
    _validDays.dispose();
    _prefix.dispose();
    _nextInvoice.dispose();
    _nextEstimate.dispose();
    super.dispose();
  }

  void _onEdit() {
    if (_loading || _dirty) return;
    setState(() => _dirty = true);
  }

  Future<void> _load() async {
    final settings = await SettingsService.loadDocumentSettings();
    if (!mounted) return;
    _invoiceTerms.text = settings.invoiceTerms;
    _estimateTerms.text = settings.estimateTerms;
    _validDays.text = '${settings.estimateValidDays}';
    _prefix.text = settings.documentPrefix;
    _nextInvoice.text = '${settings.nextInvoiceNumber}';
    _nextEstimate.text = '${settings.nextEstimateNumber}';
    _showLogo = settings.invoiceShowLogo;
    _showQr = settings.invoiceShowQr;
    _showPayments = settings.invoiceShowPayments;
    _prefix.addListener(_onNumberPreview);
    _nextInvoice.addListener(_onNumberPreview);
    for (final controller in [
      _invoiceTerms,
      _estimateTerms,
      _validDays,
      _prefix,
      _nextInvoice,
      _nextEstimate,
    ]) {
      controller.addListener(_onEdit);
    }
    setState(() {
      _loading = false;
      _dirty = false;
    });
  }

  void _onNumberPreview() {
    if (mounted) setState(() {});
  }

  Future<bool> _save() async {
    setState(() => _saving = true);
    final days = int.tryParse(_validDays.text.trim()) ?? 30;
    final nextInv = int.tryParse(_nextInvoice.text.trim()) ?? 1;
    final nextEst = int.tryParse(_nextEstimate.text.trim()) ?? 1;
    final current = await SettingsService.loadDocumentSettings();
    await SettingsService.saveDocumentSettings(
      current.copyWith(
        invoiceTerms: _invoiceTerms.text.trim(),
        estimateTerms: _estimateTerms.text.trim(),
        estimateValidDays: days <= 0 ? 30 : days,
        invoiceShowLogo: _showLogo,
        invoiceShowQr: _showQr,
        invoiceShowPayments: _showPayments,
        documentPrefix: _prefix.text.trim(),
        nextInvoiceNumber: nextInv <= 0 ? 1 : nextInv,
        nextEstimateNumber: nextEst <= 0 ? 1 : nextEst,
      ),
    );
    if (!mounted) return false;
    setState(() {
      _saving = false;
      _dirty = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Шаблоны счетов и смет сохранены'.tr),
        backgroundColor: Colors.green,
      ),
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return DirtyLeaveScope(
      dirty: _dirty,
      onSave: _save,
      child: Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text('Счета и сметы'.tr),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        actions: [
          AppBarSaveButton(
            dirty: _dirty,
            saving: _saving,
            onPressed: () { _save(); },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Реквизиты компании и HST — в Настройки → Компания и Финансы. PDF клиенту всегда на английском.'.tr,
                  style: const TextStyle(color: Colors.black54),
                ),
                const SizedBox(height: 16),
                _previewCard(),
                SwitchListTile(
                  title: Text('Логотип на инвойсе'.tr),
                  value: _showLogo,
                  onChanged: (value) => setState(() {
                    _showLogo = value;
                    _dirty = true;
                  }),
                ),
                SwitchListTile(
                  title: Text('QR-код внизу'.tr),
                  value: _showQr,
                  onChanged: (value) => setState(() {
                    _showQr = value;
                    _dirty = true;
                  }),
                ),
                SwitchListTile(
                  title: Text('История платежей на PDF'.tr),
                  value: _showPayments,
                  onChanged: (value) => setState(() {
                    _showPayments = value;
                    _dirty = true;
                  }),
                ),
                const SizedBox(height: 16),
                _card(
                  title: 'Нумерация'.tr,
                  children: [
                    _field(_prefix, 'Префикс номера'.tr, Icons.tag),
                    _field(
                      _nextInvoice,
                      'Следующий счёт'.tr,
                      Icons.receipt_long,
                      keyboard: TextInputType.number,
                    ),
                    _field(
                      _nextEstimate,
                      'Следующая смета'.tr,
                      Icons.description_outlined,
                      keyboard: TextInputType.number,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _card(
                  title: 'Смета'.tr,
                  children: [
                    _field(
                      _validDays,
                      'Смета действует, дней'.tr,
                      Icons.event,
                      keyboard: TextInputType.number,
                    ),
                    _field(_estimateTerms, 'Условия сметы'.tr, Icons.notes, lines: 3),
                  ],
                ),
                const SizedBox(height: 16),
                _card(
                  title: 'Текст в PDF'.tr,
                  children: [
                    _field(_invoiceTerms, 'Условия счёта'.tr, Icons.notes, lines: 3),
                  ],
                ),
                const SizedBox(height: 24),
              ],
            ),
    ),
    );
  }

  Widget _previewCard() {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(height: 4, color: const Color(0xFF14557F)),
          const SizedBox(height: 12),
          Row(
            children: [
              if (_showLogo)
                Container(
                  width: 36,
                  height: 36,
                  margin: const EdgeInsets.only(right: 8),
                  color: const Color(0xFFFCC520),
                  child: const Icon(Icons.home_repair_service, size: 20),
                ),
              const Expanded(
                child: Text(
                  'FIX-Appliance CA',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              Text(
                'Invoice #${_previewNumber()}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            '123 Example St — Customer name',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
          const SizedBox(height: 8),
          const Text('Customer  ·  Invoice details  ·  Payment',
              style: TextStyle(fontSize: 11, color: Colors.black54)),
          const Divider(),
          const Text('Refrigerator Repair     \$150.00'),
          const Align(
            alignment: Alignment.centerRight,
            child: Text(
              'Total Paid  \$169.50',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ),
          if (_showPayments)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Payments  ·  Mastercard',
                  style: TextStyle(fontSize: 11, color: Colors.black54)),
            ),
          if (_showQr)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Icon(Icons.qr_code, size: 28),
            ),
        ],
      ),
    );
  }

  String _previewNumber() {
    final prefix = _prefix.text.trim();
    final n = int.tryParse(_nextInvoice.text.trim()) ?? 1;
    final digits = n.toString().padLeft(4, '0');
    return prefix.isEmpty ? digits : '$prefix$digits';
  }

  Widget _card({required String title, required List<Widget> children}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
              color: Color(0xFF14557F),
            ),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label,
    IconData icon, {
    int lines = 1,
    TextInputType? keyboard,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        maxLines: lines,
        keyboardType: keyboard,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon),
          border: const OutlineInputBorder(),
          alignLabelWithHint: lines > 1,
        ),
      ),
    );
  }
}
