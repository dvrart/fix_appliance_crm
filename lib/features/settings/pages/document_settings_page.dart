import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../services/settings_service.dart';
import '../../../shared/widgets/app_bar_save.dart';
import '../../../shared/widgets/dirty_leave_scope.dart';
import '../widgets/settings_ui.dart';
import 'invoice_builder_page.dart';

enum _DocSection { hub, pdf, numbering, estimate, invoiceTerms }

class DocumentSettingsPage extends StatefulWidget {
  const DocumentSettingsPage({super.key}) : _sectionIndex = 0;

  const DocumentSettingsPage._at(this._sectionIndex, {super.key});

  final int _sectionIndex;

  _DocSection get _section => _DocSection.values[_sectionIndex.clamp(0, 4)];

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

  void _open(_DocSection section) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DocumentSettingsPage._at(section.index),
      ),
    ).then((_) {
      if (mounted && widget._section == _DocSection.hub) _load();
    });
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

  Widget _scaffold({required String title, required Widget body}) {
    return DirtyLeaveScope(
      dirty: _dirty,
      onSave: _save,
      child: Scaffold(
        backgroundColor: Colors.grey.shade100,
        appBar: AppBar(
          title: Text(title),
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
        ),
        body: body,
        bottomNavigationBar: BottomConfirmButton(
          dirty: _dirty,
          saving: _saving,
          onPressed: _save,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return _scaffold(
        title: 'Счета и сметы'.tr,
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    switch (widget._section) {
      case _DocSection.hub:
        return _buildHub();
      case _DocSection.pdf:
        return _buildPdf();
      case _DocSection.numbering:
        return _buildNumbering();
      case _DocSection.estimate:
        return _buildEstimate();
      case _DocSection.invoiceTerms:
        return _buildInvoiceTerms();
    }
  }

  Widget _buildHub() {
    return _scaffold(
      title: 'Счета и сметы'.tr,
      body: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'PDF клиенту всегда на английском. HST — в Финансы.'.tr,
              style: const TextStyle(color: Colors.black54),
            ),
          ),
          SettingsTileSection(
            title: 'PDF'.tr,
            tiles: [
              SettingsHubTile(
                title: 'Конструктор'.tr,
                subtitle: 'PDF'.tr,
                icon: Icons.design_services_outlined,
                color: AppColors.primary,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const InvoiceBuilderPage(),
                    ),
                  ).then((_) {
                    if (mounted) _load();
                  });
                },
              ),
              SettingsHubTile(
                title: 'Нумерация'.tr,
                subtitle: _prefix.text.isEmpty ? '—' : _prefix.text,
                icon: Icons.tag,
                color: Colors.teal,
                onTap: () => _open(_DocSection.numbering),
              ),
              SettingsHubTile(
                title: 'Смета'.tr,
                subtitle: '${_validDays.text} ${'дн'.tr}',
                icon: Icons.description_outlined,
                color: Colors.indigo,
                onTap: () => _open(_DocSection.estimate),
              ),
              SettingsHubTile(
                title: 'Условия счёта'.tr,
                subtitle: _invoiceTerms.text.trim().isEmpty
                    ? '—'
                    : '…',
                icon: Icons.notes,
                color: Colors.blueGrey,
                onTap: () => _open(_DocSection.invoiceTerms),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPdf() {
    return _scaffold(
      title: 'Вид PDF'.tr,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _previewCard(),
          SettingsTileSection(
            title: 'PDF'.tr,
            tiles: [
              SettingsHubTile(
                title: 'Логотип'.tr,
                subtitle: _showLogo ? 'Вкл'.tr : 'Выкл'.tr,
                icon: Icons.image_outlined,
                color: Colors.orange,
                active: _showLogo,
                onTap: () => setState(() {
                  _showLogo = !_showLogo;
                  _dirty = true;
                }),
              ),
              SettingsHubTile(
                title: 'QR-код'.tr,
                subtitle: _showQr ? 'Вкл'.tr : 'Выкл'.tr,
                icon: Icons.qr_code,
                color: Colors.teal,
                active: _showQr,
                onTap: () => setState(() {
                  _showQr = !_showQr;
                  _dirty = true;
                }),
              ),
              SettingsHubTile(
                title: 'Платежи'.tr,
                subtitle: _showPayments ? 'Вкл'.tr : 'Выкл'.tr,
                icon: Icons.payments_outlined,
                color: Colors.green,
                active: _showPayments,
                onTap: () => setState(() {
                  _showPayments = !_showPayments;
                  _dirty = true;
                }),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNumbering() {
    return _scaffold(
      title: 'Нумерация'.tr,
      body: ListView(
        padding: const EdgeInsets.all(16),
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
    );
  }

  Widget _buildEstimate() {
    return _scaffold(
      title: 'Смета'.tr,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _field(
            _validDays,
            'Смета действует, дней'.tr,
            Icons.event,
            keyboard: TextInputType.number,
          ),
          _field(_estimateTerms, 'Условия сметы'.tr, Icons.notes, lines: 5),
        ],
      ),
    );
  }

  Widget _buildInvoiceTerms() {
    return _scaffold(
      title: 'Условия счёта'.tr,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _field(_invoiceTerms, 'Условия счёта'.tr, Icons.notes, lines: 6),
        ],
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
              child: Text(
                'Payments  ·  Mastercard',
                style: TextStyle(fontSize: 11, color: Colors.black54),
              ),
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
          filled: true,
          fillColor: Colors.white,
          alignLabelWithHint: lines > 1,
        ),
      ),
    );
  }
}
