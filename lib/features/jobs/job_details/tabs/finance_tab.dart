import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/api_keys.dart';
import '../../../../core/app_commands.dart';
import '../../../../core/app_feedback.dart';
import '../../../../core/constants.dart';
import '../../../../core/l10n/app_locale.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../models/document_settings.dart';
import '../../../../models/job.dart';
import '../../../../models/warehouse_item.dart';
import '../../../../services/services.dart';
import '../../../../shared/widgets/client_signature_sheet.dart';
import '../../../../shared/widgets/confirm_action_sheet.dart';
import '../../../../shared/widgets/keyboard_safe.dart';
import '../../../../shared/widgets/unsaved_changes_dialog.dart';
import '../job_details_controller.dart';
import '../widgets/client_tip_sheet.dart';

class FinanceTab extends StatefulWidget {
  final JobDetailsController controller;

  const FinanceTab({super.key, required this.controller});

  @override
  State<FinanceTab> createState() => _FinanceTabState();
}

class _FinanceTabState extends State<FinanceTab> {
  JobDetailsController get ctrl => widget.controller;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    ctrl.addListener(_onControllerChange);
    ctrl.saveFinanceBuilder = _commitBuilder;
    ctrl.discardFinanceBuilder = _discardBuilder;
  }

  @override
  void dispose() {
    ctrl.removeListener(_onControllerChange);
    ctrl.saveFinanceBuilder = null;
    ctrl.discardFinanceBuilder = null;
    super.dispose();
  }

  void _onControllerChange() {
    if (mounted) setState(() {});
  }

  void _discardBuilder() {
    ctrl.setFinanceMode('main');
  }

  Future<void> _onCloseBuilder() async {
    final action = await showUnsavedChangesDialog(context);
    if (!mounted) return;
    if (action == UnsavedChangesAction.cancel) return;
    if (action == UnsavedChangesAction.save) {
      await _commitBuilder();
      return;
    }
    _discardBuilder();
  }

  Future<bool> _commitBuilder() async {
    if (ctrl.builderItems.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Добавьте позиции'.tr)),
        );
      }
      return false;
    }
    Map<String, dynamic>? signature;
    if (ctrl.builderDocType == 'Invoice') {
      if (!mounted) return false;
      final bytes = await ClientSignatureSheet.capture(context);
      if (!mounted) return false;
      if (bytes == null) return false;
      if (bytes.isNotEmpty) {
        try {
          signature = await ClientSignatureSheet.uploadToJob(
            jobId: ctrl.jobId,
            bytes: bytes,
          );
        } catch (_) {
          if (!mounted) return false;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Не удалось сохранить подпись'.tr)),
          );
          return false;
        }
      }
    }
    final number = await SettingsService.takeNextDocumentNumber(ctrl.builderDocType);
    final doc = {
      'type': ctrl.builderDocType,
      'number': number,
      'items': List.from(ctrl.builderItems),
      'taxRate': ctrl.builderTaxRate,
      'payments': <Map<String, dynamic>>[],
      'createdAt': DateTime.now().toIso8601String(),
      if (signature != null) 'signature': signature,
    };
    await ctrl.addDocument(doc);
    if (signature != null) {
      ctrl.addAttachment(signature);
      await JobService.addAttachment(ctrl.jobId, signature);
    }
    ctrl.setViewingDocumentIndex(ctrl.documents.length - 1);
    ctrl.setFinanceMode('view_document');
    return true;
  }

  void _createDocument(String type) {
    ctrl.builderItems.clear();
    ctrl.builderDocType = type;
    ctrl.setFinanceMode('builder');
  }

  bool _estimateConverted(Map<String, dynamic> doc) {
    return doc['convertedToInvoice'] == true;
  }

  Future<void> _convertEstimateToInvoice(int index) async {
    if (_busy) return;
    if (index < 0 || index >= ctrl.documents.length) return;
    final estimate = Map<String, dynamic>.from(ctrl.documents[index]);
    if ((estimate['type'] ?? '') != 'Estimate') return;
    if ((estimate['estimateStatus'] ?? '') != 'approved') return;
    if (_estimateConverted(estimate) || estimate['status'] == 'cancelled') {
      return;
    }
    final items = [
      for (final item in estimate['items'] as List? ?? [])
        if (item is Map) Map<String, dynamic>.from(item),
    ];
    if (items.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Добавьте позиции'.tr)),
      );
      return;
    }

    setState(() => _busy = true);
    try {
      final number = await SettingsService.takeNextDocumentNumber('Invoice');
      final invoice = {
        'type': 'Invoice',
        'number': number,
        'items': items,
        'taxRate': estimate['taxRate'] ?? 0.0,
        'payments': <Map<String, dynamic>>[],
        'createdAt': DateTime.now().toIso8601String(),
        'fromEstimateNumber': estimate['number'],
      };
      await ctrl.addDocument(invoice);
      await ctrl.updateDocument(index, {
        ...estimate,
        'convertedToInvoice': true,
        'convertedInvoiceNumber': number,
      });
      if (!mounted) return;
      ctrl.setViewingDocumentIndex(ctrl.documents.length - 1);
      ctrl.setFinanceMode('view_document');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ctrl.financeMode == 'builder') {
      return _buildDocumentBuilder();
    }
    if (ctrl.financeMode == 'view_document') {
      return _buildDocumentViewer();
    }
    return _buildMainView();
  }

  Widget _buildMainView() {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ctrl.documents.where((doc) => !Job.isDocumentTrashed(doc)).isEmpty
            ? Center(
                child: Text(
                  'Нет счетов.\nНажмите (+) и создайте Invoice или Estimate.'.tr,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF3D3D3D),
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
              )
            : Column(
                children: [
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF14557F).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF14557F)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.description, color: Color(0xFF14557F)),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Счёт и смету отправляете вы из приложения. Текст настраивается в Настройках. Карту на месте — отдельно, «Приложить карту».'.tr,
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: ctrl.documents.length,
                      itemBuilder: (context, index) {
                        if (Job.isDocumentTrashed(ctrl.documents[index])) {
                          return const SizedBox.shrink();
                        }
                        return _buildDocumentCard(index);
                      },
                    ),
                  ),
                ],
              ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showCreateDocumentMenu(),
        backgroundColor: AppColors.accent,
        child: const Icon(Icons.add, color: Colors.black),
      ),
    );
  }

  void _showCreateDocumentMenu() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Создать документ'.tr,
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
              ),
              ListTile(
                leading: Icon(Icons.receipt, color: AppColors.primary),
                title: Text('Invoice (Счёт)'.tr),
                subtitle: Text('Документ для оплаты'.tr),
                onTap: () {
                  Navigator.pop(context);
                  _createDocument('Invoice');
                },
              ),
              ListTile(
                leading: const Icon(Icons.description, color: Colors.orange),
                title: Text('Estimate (Смета)'.tr),
                subtitle: Text('Предварительный расчёт'.tr),
                onTap: () {
                  Navigator.pop(context);
                  _createDocument('Estimate');
                },
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDocumentCard(int index) {
    final doc = ctrl.documents[index];
    final type = doc['type'] ?? 'Invoice';
    final isEstimate = type == 'Estimate';
    final isCancelled = doc['status'] == 'cancelled';

    final subtotal = ctrl.calcSubtotal(doc['items'] ?? []);
    final tax = ctrl.calcTax(subtotal, doc['taxRate'] ?? 0.0);
    final total = ctrl.calcTotal(subtotal, tax);
    final paid = ctrl.calcPaid(doc['payments'] ?? []);
    final due = ctrl.calcDue(total, paid);

    final isPaid = !isEstimate && total > 0 && due == 0;
    final isPartiallyPaid = !isEstimate && paid > 0 && due > 0;
    final estimateStatus = (doc['estimateStatus'] ?? '').toString();
    final estimateApproved = isEstimate && estimateStatus == 'approved';
    final estimateSent = isEstimate && estimateStatus == 'sent';

    Color cardColor;
    Color borderColor;
    IconData icon;
    String statusText;

    if (isCancelled) {
      cardColor = Colors.red.shade50;
      borderColor = Colors.red.shade300;
      icon = Icons.cancel;
      statusText = 'Отменён'.tr;
    } else if (estimateApproved) {
      cardColor = Colors.green.shade50;
      borderColor = Colors.green.shade400;
      icon = Icons.verified;
      statusText = '${'Клиент подтвердил ремонт'.tr} · \$${total.toStringAsFixed(2)}';
    } else if (estimateSent) {
      cardColor = const Color(0xFFFFF8E1);
      borderColor = const Color(0xFFF59E0B);
      icon = Icons.hourglass_top;
      statusText = '${'Ждём согласие клиента'.tr} · \$${total.toStringAsFixed(2)}';
    } else if (isEstimate) {
      cardColor = Colors.white;
      borderColor = Colors.blue.shade200;
      icon = Icons.description;
      statusText = '\$${total.toStringAsFixed(2)}';
    } else if (isPaid) {
      cardColor = Colors.green.shade50;
      borderColor = Colors.green.shade300;
      icon = Icons.check_circle;
      statusText = 'Оплачен'.tr;
    } else if (Job.documentPayMark(doc) == 'deposit') {
      cardColor = Colors.amber.shade50;
      borderColor = Colors.amber.shade300;
      icon = Icons.savings_outlined;
      statusText = paid > 0
          ? '${'Депозит'.tr}: \$${paid.toStringAsFixed(2)}'
          : 'Депозит'.tr;
    } else if (isPartiallyPaid) {
      cardColor = Colors.amber.shade50;
      borderColor = Colors.amber.shade300;
      icon = Icons.timelapse;
      statusText = '${'Остаток'.tr}: \$${due.toStringAsFixed(2)}';
    } else {
      cardColor = Colors.white;
      borderColor = Colors.blue.shade200;
      icon = Icons.circle_outlined;
      statusText = '${'Неоплачен'.tr}: \$${total.toStringAsFixed(2)}';
    }

    return Card(
      color: cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: borderColor),
      ),
      margin: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                ctrl.setViewingDocumentIndex(index);
                ctrl.setFinanceMode('view_document');
              },
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: borderColor.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(icon, color: borderColor),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${doc['type'] ?? 'Invoice'} #${doc['number'] ?? (index + 1)}',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            statusText,
                            style: TextStyle(
                              color: isCancelled
                                  ? Colors.red
                                  : Colors.grey.shade700,
                            ),
                          ),
                          if (!isCancelled &&
                              doc['stripe'] is Map &&
                              (doc['stripe']['url'] ?? '').toString().isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                doc['stripe']['status'] == 'paid'
                                    ? 'Stripe: оплачен'.tr
                                    : 'Stripe: ссылка отправлена'.tr,
                                style: TextStyle(
                                  color: doc['stripe']['status'] == 'paid'
                                      ? Colors.green.shade700
                                      : const Color(0xFF635BFF),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right, color: Colors.grey),
                  ],
                ),
              ),
            ),
          ),
          if (!isCancelled &&
              estimateApproved &&
              !_estimateConverted(doc))
            IconButton(
              tooltip: 'Сделать счёт'.tr,
              icon: const Icon(Icons.receipt_long, color: Color(0xFF2E7D32)),
              onPressed: _busy ? null : () => _convertEstimateToInvoice(index),
            ),
          if (!isCancelled && (isEstimate || due <= 0))
            IconButton(
              tooltip: 'Отправить'.tr,
              icon: const Icon(Icons.send, color: Color(0xFF14557F)),
              onPressed: _busy ? null : () => _sendAppDocument(index),
            ),
          IconButton(
            tooltip: 'В корзину'.tr,
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            onPressed: _busy ? null : () => _confirmDeleteDocument(index),
          ),
        ],
      ),
    );
  }

  Widget _buildDocumentBuilder() {
    final subtotal = ctrl.calcSubtotal(ctrl.builderItems);
    final tax = ctrl.calcTax(subtotal, ctrl.builderTaxRate);
    final total = ctrl.calcTotal(subtotal, tax);

    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: Text(
          ctrl.builderDocType == 'Estimate' ? 'Смета'.tr : 'Счёт'.tr,
        ),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _onCloseBuilder,
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ctrl.builderItems.isEmpty
                ? Center(
                    child: Text(
                      'Добавьте позиции'.tr,
                      style: const TextStyle(
                        color: Color(0xFF3D3D3D),
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: ctrl.builderItems.length,
                    itemBuilder: (context, index) {
                      final item = ctrl.builderItems[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          title: Text(item['name'] ?? 'Позиция'.tr),
                          subtitle: Text(
                            '${item['qty']} × \$${(item['price'] ?? 0).toStringAsFixed(2)}',
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '\$${((item['qty'] ?? 1) * (item['price'] ?? 0)).toStringAsFixed(2)}',
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete, color: Colors.red),
                                onPressed: () {
                                  setState(() {
                                    ctrl.builderItems.removeAt(index);
                                  });
                                  ctrl.notifyBuilderChanged();
                                },
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          // Итоги
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            color: Colors.white,
            child: Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _showAddItemDialog,
                    icon: const Icon(Icons.add),
                    label: Text('Добавить позицию'.tr),
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Сумма'.tr,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: Color(0xFF14557F),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Подитог:'.tr),
                    Text('\$${subtotal.toStringAsFixed(2)}'),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Tax:'),
                    DropdownButton<double>(
                      value: ctrl.builderTaxRate,
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(value: TaxRates.hst, child: Text('HST 13%')),
                        DropdownMenuItem(value: TaxRates.gst, child: Text('GST 5%')),
                        DropdownMenuItem(value: TaxRates.none, child: Text('No tax 0%')),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => ctrl.builderTaxRate = value);
                      },
                    ),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('${'Налог'.tr} (${(ctrl.builderTaxRate * 100).toInt()}%):'),
                    Text('\$${tax.toStringAsFixed(2)}'),
                  ],
                ),
                const Divider(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'ИТОГО:'.tr,
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                    ),
                    Text(
                      '\$${total.toStringAsFixed(2)}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: RoundActionButton(
                      color: ctrl.builderItems.isNotEmpty
                          ? const Color(0xFF22C55E)
                          : Colors.grey.shade400,
                      icon: Icons.check_rounded,
                      tooltip: 'Сохранить'.tr,
                      size: 64,
                      onTap: () {
                        if (ctrl.builderItems.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Добавьте позиции'.tr)),
                          );
                          return;
                        }
                        AppCommands.reactHappy();
                        _commitBuilder();
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddItemDialog() async {
    final nameCtrl = TextEditingController();
    final priceCtrl = TextEditingController();
    final qtyCtrl = TextEditingController(text: '1');
    List<WarehouseItem> warehouse = const [];
    var markup = 0.0;
    try {
      warehouse = await WarehouseService.streamAll().first;
      final config = await SettingsService.loadConfig();
      markup = SettingsService.readPartsMarkupPercent(config);
    } catch (_) {}
    if (!mounted) return;
    WarehouseItem? picked;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialog) {
            final query = nameCtrl.text.trim().toLowerCase();
            final matches = query.length < 2
                ? const <WarehouseItem>[]
                : warehouse.where((item) {
                    return item.name.toLowerCase().contains(query) ||
                        item.partNumber.toLowerCase().contains(query) ||
                        (item.modelNumber ?? '').toLowerCase().contains(query);
                  }).take(6).toList();
            return AlertDialog(
              title: Text('Добавить позицию'.tr),
              scrollable: true,
              content: SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      onChanged: (_) {
                        if (picked != null &&
                            nameCtrl.text.trim() != picked!.name) {
                          picked = null;
                        }
                        setDialog(() {});
                      },
                      decoration: InputDecoration(
                        labelText: 'Название'.tr,
                        hintText: 'Начните вводить — поиск по складу'.tr,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    if (matches.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      ...matches.map((item) {
                        final selected = picked?.id == item.id;
                        return ListTile(
                          dense: true,
                          selected: selected,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.inventory_2_outlined),
                          title: Text(item.name),
                          subtitle: Text(
                            [
                              if (item.partNumber.isNotEmpty) item.partNumber,
                              '${'остаток'.tr} ${item.quantity}',
                            ].join(' · '),
                          ),
                          trailing: Text('\$${item.price.toStringAsFixed(2)}'),
                          onTap: () {
                            picked = item;
                            nameCtrl.text = item.name;
                            final cost = item.costPrice;
                            final price = cost != null && markup > 0
                                ? double.parse(
                                    (cost * (1 + markup / 100)).toStringAsFixed(2),
                                  )
                                : item.price;
                            priceCtrl.text = price.toStringAsFixed(2);
                            setDialog(() {});
                          },
                        );
                      }),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: priceCtrl,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: 'Цена'.tr,
                              prefixText: '\$ ',
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: qtyCtrl,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: 'Кол-во'.tr,
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text('Отмена'.tr),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (nameCtrl.text.trim().isEmpty) return;
                    final selected = picked;
                    setState(() {
                      ctrl.builderItems.add({
                        'name': nameCtrl.text.trim(),
                        'price': double.tryParse(priceCtrl.text) ?? 0,
                        'qty': int.tryParse(qtyCtrl.text) ?? 1,
                        if (selected != null) ...{
                          'type': 'Запчасть'.tr,
                          'warehouseItemId': selected.id,
                          'costPrice': selected.costPrice,
                        },
                      });
                    });
                    ctrl.notifyBuilderChanged();
                    Navigator.pop(dialogContext);
                  },
                  child: Text('Добавить'.tr),
                ),
              ],
            );
          },
        );
      },
    );
    nameCtrl.dispose();
    priceCtrl.dispose();
    qtyCtrl.dispose();
  }

  Widget _buildDocumentViewer() {
    if (ctrl.viewingDocumentIndex == null ||
        ctrl.viewingDocumentIndex! >= ctrl.documents.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ctrl.financeMode == 'view_document') ctrl.setFinanceMode('main');
      });
      return _buildMainView();
    }

    final doc = ctrl.documents[ctrl.viewingDocumentIndex!];
    final items = [
      for (final item in doc['items'] as List? ?? [])
        if (item is Map) Map<String, dynamic>.from(item),
    ];
    final payments = [
      for (final payment in doc['payments'] as List? ?? [])
        if (payment is Map) Map<String, dynamic>.from(payment),
    ];
    final isEstimate = doc['type'] == 'Estimate';
    final isCancelled = doc['status'] == 'cancelled';

    final subtotal = ctrl.calcSubtotal(items);
    final tax = ctrl.calcTax(subtotal, doc['taxRate'] ?? 0.0);
    final total = ctrl.calcTotal(subtotal, tax);
    final paid = ctrl.calcPaid(payments);
    final due = ctrl.calcDue(total, paid);

    return ColoredBox(
      color: Colors.white,
      child: Column(
        children: [
          Material(
            color: AppColors.primary,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => ctrl.setFinanceMode('main'),
                ),
                Expanded(
                  child: Text(
                    '${doc['type']} #${ctrl.viewingDocumentIndex! + 1}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_busy) const LinearProgressIndicator(minHeight: 3),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
            if (isEstimate) ...[
              _EstimateStatusBanner(
                doc: doc,
                busy: _busy,
                onConvertToInvoice: !isCancelled &&
                        (doc['estimateStatus'] ?? '') == 'approved' &&
                        !_estimateConverted(doc)
                    ? () => _convertEstimateToInvoice(
                          ctrl.viewingDocumentIndex!,
                        )
                    : null,
              ),
              const SizedBox(height: 12),
            ],
            // Позиции
            Text(
              'Позиции'.tr,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            ...items.map((item) {
              final name = item['name'] ?? 'Позиция'.tr;
              final qty = item['qty'] ?? 1;
              final price = (item['price'] ?? 0).toDouble();
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  title: Text(name),
                  subtitle: Text('$qty × \$${price.toStringAsFixed(2)}'),
                  trailing: Text(
                    '\$${(qty * price).toStringAsFixed(2)}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              );
            }),

            const SizedBox(height: 16),

            // Итоги
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  _buildTotalRow('Подитог'.tr, subtotal),
                  _buildTotalRow('Налог'.tr, tax),
                  const Divider(),
                  _buildTotalRow('Итого'.tr, total, isBold: true),
                  if (paid > 0) _buildTotalRow('Оплачено'.tr, paid, color: Colors.green),
                  if (due > 0) _buildTotalRow('К оплате'.tr, due, color: Colors.red),
                ],
              ),
            ),

            if (payments.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                'Платежи'.tr,
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 8),
              ...payments.map((p) {
                final amount = (p['amount'] ?? 0).toDouble();
                final method = (p['method'] ?? 'Оплата'.tr).toString();
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: Icon(
                      method.toString().contains('Stripe')
                          ? Icons.credit_card
                          : Icons.payments,
                      color: Colors.green,
                    ),
                    title: Text(Formatters.formatCurrency(amount)),
                    subtitle: Text(trAny(method)),
                  ),
                );
              }),
            ],

            if (_signatureUrl(doc).isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                'Подпись клиента'.tr,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Image.network(
                      _signatureUrl(doc),
                      height: 88,
                      fit: BoxFit.contain,
                      alignment: Alignment.centerLeft,
                      errorBuilder: (context, error, stackTrace) =>
                          Text('Подпись сохранена'.tr),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Расписка на PDF счёта'.tr,
                      style: TextStyle(
                        color: Colors.grey.shade700,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            if (_stripeUrl(doc).isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildStripeStatusCard(doc, due),
            ],

            if (!isCancelled) ...[
              if (isEstimate || due <= 0) ...[
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _sendAppDocument(ctrl.viewingDocumentIndex!),
                    icon: const Icon(Icons.send),
                    label: Text('Отправить'.tr),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF14557F),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
              ],
              if (!isEstimate && due > 0) ...[
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _showPaySheet(
                              documentIndex: ctrl.viewingDocumentIndex!,
                              total: total,
                              due: due,
                            ),
                    icon: const Icon(Icons.payments),
                    label: Text('Выбор оплаты'.tr),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
              ],
            ],
          ],
                ),
              ),
            ),
          ],
        ),
      );
  }

  String _stripeUrl(Map<String, dynamic> doc) {
    final stripe = doc['stripe'];
    if (stripe is! Map) return '';
    final url = (stripe['shortUrl'] ??
            stripe['url'] ??
            stripe['hostedInvoiceUrl'] ??
            '')
        .toString();
    return url;
  }

  String _stripeSmsUrl(Map<String, dynamic> doc) {
    final raw = _stripeRawUrl(doc);
    if (raw.startsWith('http')) return raw;
    final stripe = doc['stripe'];
    if (stripe is Map) {
      final stored = (stripe['smsUrl'] ?? '').toString().trim();
      if (stored.startsWith('http') && !stored.contains('fix-appliance.ca/pay/')) {
        return stored;
      }
    }
    return _stripeUrl(doc);
  }

  String _stripeRawUrl(Map<String, dynamic> doc) {
    final stripe = doc['stripe'];
    if (stripe is! Map) return '';
    return (stripe['rawUrl'] ?? '').toString().trim();
  }

  String _signatureUrl(Map<String, dynamic> doc) {
    final signature = doc['signature'];
    if (signature is! Map) return '';
    return (signature['url'] ?? '').toString().trim();
  }

  Future<void> _confirmDeleteDocument(int index) async {
    if (index < 0 || index >= ctrl.documents.length) return;
    final doc = ctrl.documents[index];
    final isEstimate = (doc['type'] ?? '') == 'Estimate';
    final confirmed = await showConfirmCancelSheet(
      context,
      title: isEstimate ? 'Удалить смету?'.tr : 'Удалить счёт?'.tr,
      message: isEstimate
          ? 'Смета попадёт в корзину.'.tr
          : 'Счёт попадёт в корзину.'.tr,
      confirmLabel: 'Удалить'.tr,
      cancelLabel: 'Отмена'.tr,
    );
    if (!confirmed) return;
    await ctrl.deleteDocument(index);
  }

  Widget _buildStripeStatusCard(Map<String, dynamic> doc, double due) {
    final stripe = Map<String, dynamic>.from(doc['stripe'] as Map);
    final paid = stripe['status'] == 'paid';
    final url = _stripeUrl(doc);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: paid ? Colors.green.shade50 : Colors.blue.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: paid ? Colors.green.shade200 : Colors.blue.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            paid ? 'Оплачено через Stripe'.tr : 'Ссылка Stripe активна'.tr,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          if (stripe['amount'] != null) ...[
            const SizedBox(height: 4),
            Text('${'Сумма'.tr}: ${Formatters.formatCurrency((stripe['amount'] as num).toDouble())}'),
          ],
          if (!paid && url.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton.icon(
                  onPressed: () => _copyUrl(url),
                  icon: const Icon(Icons.copy, size: 18),
                  label: Text('Копировать'.tr),
                ),
                TextButton.icon(
                  onPressed: () => _openUrl(url),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Text('Открыть'.tr),
                ),
                if (due > 0)
                  TextButton.icon(
                    onPressed: _busy ? null : () => _resendCurrentLink(doc),
                    icon: const Icon(Icons.sms, size: 18),
                    label: Text('Ещё раз по SMS'.tr),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _toE164(String phone) {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 10) return '+1$digits';
    if (digits.length == 11 && digits.startsWith('1')) return '+$digits';
    if (phone.trim().startsWith('+')) return '+$digits';
    return '+$digits';
  }

  String get _smsPhone {
    final client = (ctrl.jobData['clientPhone'] ?? '').toString().trim();
    if (client.isNotEmpty) return client;
    return ctrl.contactPhone.trim();
  }

  Future<void> _copyUrl(String url) async {
    if (!mounted) return;
    await AppFeedback.copy(context, url);
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _resendCurrentLink(Map<String, dynamic> doc) async {
    final url = _stripeSmsUrl(doc);
    final phone = _smsPhone;
    if (url.isEmpty || phone.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Нет телефона клиента или ссылки'.tr)),
      );
      return;
    }
    final amount = (doc['stripe'] is Map ? doc['stripe']['amount'] : null);
    final dollars = amount is num ? amount.toStringAsFixed(2) : '';
    final kind = (doc['stripe'] is Map ? doc['stripe']['mode'] : '')?.toString();
    final docs = await SettingsService.loadDocumentSettings();
    final body = DocumentSettings.stripePaySms(
      deposit: kind == 'deposit',
      dollars: dollars,
      url: url,
      company: docs.companyName,
      template: docs.paySms,
    );
    String? fallback;
    if (doc['stripe'] is Map) {
      final code = (doc['stripe']['shortCode'] ?? '').toString().trim();
      if (code.isNotEmpty) {
        final carrier =
            '${kFirebaseFunctionsUrl}/p/${Uri.encodeComponent(code)}';
        if (carrier != url) {
          fallback = DocumentSettings.stripePaySms(
            deposit: kind == 'deposit',
            dollars: dollars,
            url: carrier,
            company: docs.companyName,
            template: docs.paySms,
          );
        }
      }
    }
    final ok = await SmsService.sendSms(
      to: _toE164(phone),
      body: body,
      fallbackBody: fallback,
      clientId: ctrl.clientId,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? 'SMS отправлено'.tr : 'Не удалось отправить SMS'.tr)),
    );
  }

  Future<void> _sendAppDocument(int documentIndex) async {
    if (documentIndex < 0 || documentIndex >= ctrl.documents.length) return;
    final doc = ctrl.documents[documentIndex];
    final items = doc['items'] as List? ?? [];
    final subtotal = ctrl.calcSubtotal(items);
    final tax = ctrl.calcTax(subtotal, doc['taxRate'] ?? 0.0);
    final total = ctrl.calcTotal(subtotal, tax);
    final paid = ctrl.calcPaid(doc['payments'] ?? []);
    final due = ctrl.calcDue(total, paid);
    final type = (doc['type'] ?? 'Invoice').toString();
    final kind = type == 'Estimate' ? 'estimate' : 'invoice';

    await DocumentTemplateService.showSendSheet(
      context: context,
      data: DocumentSendData(
        kind: kind,
        jobId: ctrl.jobId,
        clientId: ctrl.clientId,
        clientName: (ctrl.jobData['clientName'] ?? ctrl.contactName).toString(),
        clientPhone: _smsPhone,
        clientAddress: (ctrl.jobData['clientAddress'] ?? ctrl.workAddress).toString(),
        documentNumber: documentIndex + 1,
        items: items,
        subtotal: subtotal,
        tax: tax,
        taxRate: (doc['taxRate'] as num?)?.toDouble() ?? 0,
        total: total,
        paid: paid,
        due: due,
        payments: List<Map<String, dynamic>>.from(doc['payments'] ?? []),
        subject: ctrl.workAddress.trim().isEmpty
            ? ctrl.contactName
            : ctrl.workAddress,
        serviceDate: DateTime.tryParse((doc['createdAt'] ?? '').toString()),
        clientEmail: ctrl.clientEmail,
        clientCompany: (ctrl.jobData['companyName'] ?? '').toString(),
        persistPdfUrl: (url) async {
          final next = Map<String, dynamic>.from(ctrl.documents[documentIndex]);
          next['pdfUrl'] = url;
          await ctrl.updateDocument(documentIndex, next);
        },
        persistFields: (patch) async {
          final next = Map<String, dynamic>.from(ctrl.documents[documentIndex]);
          next.addAll(patch);
          await ctrl.updateDocument(documentIndex, next);
        },
        pdfShortCode: () {
          final raw = kind == 'estimate'
              ? (doc['confirmShortCode'] ?? '')
              : (doc['pdfShortCode'] ?? '');
          final code = raw.toString().trim();
          return code.isEmpty ? null : code;
        }(),
        signatureUrl: _signatureUrl(doc),
      ),
    );
  }

  Future<void> _sendPaidInvoicePdf(
    int documentIndex, {
    double? paidAmount,
  }) async {
    for (var i = 0; i < 15; i++) {
      if (documentIndex >= 0 && documentIndex < ctrl.documents.length) {
        final paid = ctrl.calcPaid(
          ctrl.documents[documentIndex]['payments'] ?? [],
        );
        if (paid > 0 || (paidAmount != null && paidAmount > 0)) break;
      }
      await Future.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
    }
    if (documentIndex < 0 || documentIndex >= ctrl.documents.length) return;
    final doc = ctrl.documents[documentIndex];
    final items = doc['items'] as List? ?? [];
    final subtotal = ctrl.calcSubtotal(items);
    final tax = ctrl.calcTax(subtotal, doc['taxRate'] ?? 0.0);
    final total = ctrl.calcTotal(subtotal, tax);
    var paid = ctrl.calcPaid(doc['payments'] ?? []);
    if (paidAmount != null && paidAmount > paid) paid = paidAmount;
    final due = ctrl.calcDue(total, paid);
    if (paid <= 0) return;

    final ok = await DocumentTemplateService.sendPdfLinkQuietly(
      data: DocumentSendData(
        kind: 'receipt',
        jobId: ctrl.jobId,
        clientId: ctrl.clientId,
        clientName: (ctrl.jobData['clientName'] ?? ctrl.contactName).toString(),
        clientPhone: _smsPhone,
        clientAddress:
            (ctrl.jobData['clientAddress'] ?? ctrl.workAddress).toString(),
        documentNumber: documentIndex + 1,
        items: items,
        subtotal: subtotal,
        tax: tax,
        taxRate: (doc['taxRate'] as num?)?.toDouble() ?? 0,
        total: total,
        paid: paid,
        due: due,
        payments: List<Map<String, dynamic>>.from(doc['payments'] ?? []),
        subject: ctrl.workAddress.trim().isEmpty
            ? ctrl.contactName
            : ctrl.workAddress,
        serviceDate: DateTime.tryParse((doc['createdAt'] ?? '').toString()),
        clientEmail: ctrl.clientEmail,
        clientCompany: (ctrl.jobData['companyName'] ?? '').toString(),
        persistPdfUrl: (url) async {
          if (documentIndex < 0 || documentIndex >= ctrl.documents.length) {
            return;
          }
          final next = Map<String, dynamic>.from(ctrl.documents[documentIndex]);
          next['pdfUrl'] = url;
          await ctrl.updateDocument(documentIndex, next);
        },
        persistFields: (patch) async {
          if (documentIndex < 0 || documentIndex >= ctrl.documents.length) {
            return;
          }
          final next = Map<String, dynamic>.from(ctrl.documents[documentIndex]);
          next.addAll(patch);
          await ctrl.updateDocument(documentIndex, next);
        },
        pdfShortCode: (doc['pdfShortCode'] ?? '').toString().trim().isEmpty
            ? null
            : (doc['pdfShortCode'] ?? '').toString().trim(),
        signatureUrl: _signatureUrl(doc),
      ),
    );
    if (!mounted || ok) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Не удалось отправить ссылку на PDF'.tr),
        backgroundColor: Colors.red,
      ),
    );
  }

  Future<void> _runTapToPay(int documentIndex, {double? amount, double tip = 0}) async {
    if (_busy) return;
    if (documentIndex < 0 || documentIndex >= ctrl.documents.length) return;
    final doc = ctrl.documents[documentIndex];
    final subtotal = ctrl.calcSubtotal(doc['items'] ?? []);
    final tax = ctrl.calcTax(subtotal, doc['taxRate'] ?? 0.0);
    final total = ctrl.calcTotal(subtotal, tax);
    final paid = ctrl.calcPaid(doc['payments'] ?? []);
    final due = ctrl.calcDue(total, paid);
    final repair = (amount ?? due);
    if (repair <= 0) return;
    final charge = repair + tip;

    setState(() => _busy = true);
    try {
      final ok = await StripeTerminalService.collectWithDialog(
        context: context,
        jobId: ctrl.jobId,
        documentIndex: documentIndex,
        amount: repair,
        tip: tip,
      );
      if (!mounted) return;
      await _showPayResult(
        success: ok,
        documentIndex: documentIndex,
        amount: charge,
      );
    } catch (e) {
      if (!mounted) return;
      await _showPayResult(success: false, message: e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runStripeAction({
    required String kind,
    required int documentIndex,
    double? amount,
    double tip = 0,
  }) async {
    setState(() => _busy = true);
    try {
      final result = await StripeService.createPayment(
        jobId: ctrl.jobId,
        documentIndex: documentIndex,
        kind: kind,
        amount: amount,
        tip: tip,
        sendSms: true,
        to: _smsPhone,
      );
      var smsSent = result.smsSent;
      if (!smsSent && _smsPhone.isNotEmpty) {
        final docs = await SettingsService.loadDocumentSettings();
        smsSent = await SmsService.sendSms(
          to: _smsPhone,
          body: DocumentSettings.stripePaySms(
            deposit: kind == 'deposit',
            dollars: result.amount.toStringAsFixed(2),
            url: result.smsUrl,
            company: docs.companyName,
            template: docs.paySms,
          ),
          fallbackBody: result.rawUrl.trim().isNotEmpty
              ? DocumentSettings.stripePaySms(
                  deposit: kind == 'deposit',
                  dollars: result.amount.toStringAsFixed(2),
                  url: result.rawUrl,
                  company: docs.companyName,
                  template: docs.paySms,
                )
              : null,
          clientId: ctrl.clientId,
        );
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Payment link sent'),
            scrollable: true,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  smsSent
                      ? 'The client received an English SMS with a Pay here line.'
                      : 'SMS did not send. Copy the link and send it yourself.',
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () {
                    AppFeedback.copy(context, result.url);
                    Navigator.pop(context);
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy payment link'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    _openUrl(result.url);
                  },
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open link'),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
      if (mounted) ctrl.setFinanceMode('main');
    } on StripeServiceException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), backgroundColor: Colors.red),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${'Ошибка Stripe'.tr}: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showPaySheet({
    required int documentIndex,
    required double total,
    required double due,
  }) {
    final maxAmount = due > 0 ? due : total;
    final amountCtrl = TextEditingController(text: maxAmount.toStringAsFixed(2));

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return KeyboardAvoidingSheet(
          child: StatefulBuilder(
            builder: (context, setSheet) {
              double parsedAmount() {
                final value = double.tryParse(
                      amountCtrl.text.replaceAll(',', '.'),
                    ) ??
                    0;
                if (value <= 0) return 0;
                return value;
              }

              return SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Выбор оплаты'.tr,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${'К оплате'.tr}: ${Formatters.formatCurrency(maxAmount)}',
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: amountCtrl,
                              keyboardType: const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              onChanged: (_) => setSheet(() {}),
                              decoration: InputDecoration(
                                labelText: 'Сумма'.tr,
                                prefixText: '\$ ',
                                border: const OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: () {
                              amountCtrl.text = (maxAmount * 0.5).toStringAsFixed(2);
                              setSheet(() {});
                            },
                            child: const Text('50%'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        context.tr(
                          'После выбора способа клиент сам оставит чаевые — до оплаты.',
                          'After you pick a method, the customer adds a tip before payment.',
                        ),
                        style: TextStyle(color: Colors.grey.shade700, fontSize: 13, height: 1.3),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: () {
                          final amount = parsedAmount();
                          Navigator.pop(sheetContext);
                          if (amount > 0) {
                            _payAfterClientTip(
                              documentIndex: documentIndex,
                              repair: amount,
                              method: 'card',
                            );
                          }
                        },
                        icon: const Icon(Icons.credit_card),
                        label: Text('Оплатить картой'.tr),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF635BFF),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: () {
                          final amount = parsedAmount();
                          Navigator.pop(sheetContext);
                          if (amount <= 0) return;
                          final isDeposit = amount < maxAmount - 0.009;
                          _payAfterClientTip(
                            documentIndex: documentIndex,
                            repair: amount,
                            method: isDeposit ? 'deposit' : 'checkout',
                          );
                        },
                        icon: const Icon(Icons.link),
                        label: Text('Отправить ссылку на оплату'.tr),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF635BFF),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                      const SizedBox(height: 8),
                      ElevatedButton.icon(
                        onPressed: () {
                          final amount = parsedAmount();
                          Navigator.pop(sheetContext);
                          if (amount > 0) {
                            _payAfterClientTip(
                              documentIndex: documentIndex,
                              repair: amount,
                              method: 'Наличные',
                            );
                          }
                        },
                        icon: const Icon(Icons.payments),
                        label: Text('Наличные'.tr),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: () {
                          final amount = parsedAmount();
                          Navigator.pop(sheetContext);
                          if (amount > 0) {
                            _payAfterClientTip(
                              documentIndex: documentIndex,
                              repair: amount,
                              method: 'e-Transfer',
                            );
                          }
                        },
                        icon: const Icon(Icons.account_balance),
                        label: Text('E-перевод'.tr),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildTotalRow(String label, double amount,
      {bool isBold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
              fontSize: isBold ? 18 : 14,
            ),
          ),
          Text(
            '\$${amount.toStringAsFixed(2)}',
            style: TextStyle(
              fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
              fontSize: isBold ? 18 : 14,
              color: color ?? (isBold ? AppColors.primary : Colors.black),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _payAfterClientTip({
    required int documentIndex,
    required double repair,
    required String method,
  }) async {
    if (!mounted) return;
    final tip = await ClientTipPage.ask(context, due: repair);
    if (!mounted || tip == null) return;
    final total = repair + tip;
    if (method == 'card') {
      await _runTapToPay(documentIndex, amount: repair, tip: tip);
      return;
    }
    if (method == 'checkout' || method == 'deposit') {
      await _runStripeAction(
        kind: method,
        documentIndex: documentIndex,
        amount: repair,
        tip: tip,
      );
      return;
    }
    _addLocalPayment(documentIndex, repair, method, tip: tip);
    await _showPayResult(
      success: true,
      documentIndex: documentIndex,
      amount: total,
    );
  }

  void _addLocalPayment(int docIndex, double amount, String method, {double tip = 0}) {
    final doc = ctrl.documents[docIndex];
    final payments = List<Map<String, dynamic>>.from(doc['payments'] ?? []);
    payments.add({
      'amount': amount,
      'method': method,
      'date': DateTime.now().toIso8601String(),
      if (tip > 0.009) 'tip': tip,
    });
    if (tip > 0.009) {
      payments.add({
        'amount': tip,
        'method': 'Чаевые',
        'date': DateTime.now().toIso8601String(),
      });
    }
    doc['payments'] = payments;
    ctrl.updateDocument(docIndex, doc);
  }

  Future<void> _showPayResult({
    required bool success,
    String? message,
    int? documentIndex,
    double? amount,
  }) async {
    if (!mounted) return;
    final sendFuture = success && documentIndex != null
        ? _sendPaidInvoicePdf(documentIndex, paidAmount: amount)
        : Future<void>.value();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (context) {
        return AlertDialog(
          content: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  success ? Icons.check_circle : Icons.cancel,
                  color: success ? Colors.green : Colors.red,
                  size: 80,
                ),
                const SizedBox(height: 16),
                Text(
                  success
                      ? 'Thank you for your payment'
                      : 'The payment did not go through',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
    await sendFuture;
    if (!mounted || documentIndex == null) return;
    if (documentIndex >= 0 && documentIndex < ctrl.documents.length) {
      ctrl.setViewingDocumentIndex(documentIndex);
      ctrl.setFinanceMode('view_document');
    } else {
      ctrl.setFinanceMode('main');
    }
  }
}

class _EstimateStatusBanner extends StatelessWidget {
  final Map<String, dynamic> doc;
  final bool busy;
  final VoidCallback? onConvertToInvoice;

  const _EstimateStatusBanner({
    required this.doc,
    this.busy = false,
    this.onConvertToInvoice,
  });

  @override
  Widget build(BuildContext context) {
    final status = (doc['estimateStatus'] ?? '').toString();
    final approved = status == 'approved';
    final sent = status == 'sent';
    if (!approved && !sent) return const SizedBox.shrink();
    final color = approved ? Colors.green : const Color(0xFFF59E0B);
    final convertedNumber = doc['convertedInvoiceNumber'];
    final converted = doc['convertedToInvoice'] == true;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: approved ? Colors.green.shade50 : const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                approved ? Icons.verified : Icons.hourglass_top,
                color: color,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  approved
                      ? 'Клиент подтвердил ремонт'.tr
                      : 'Ждём согласие клиента'.tr,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: approved
                        ? Colors.green.shade800
                        : const Color(0xFF92400E),
                  ),
                ),
              ),
            ],
          ),
          if (onConvertToInvoice != null) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: busy ? null : onConvertToInvoice,
              icon: const Icon(Icons.receipt_long),
              label: Text('Сделать счёт'.tr),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2E7D32),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ] else if (approved && converted) ...[
            const SizedBox(height: 8),
            Text(
              convertedNumber == null
                  ? 'Счёт уже создан из этой сметы'.tr
                  : '${'Счёт'.tr} #$convertedNumber',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: Colors.green.shade800,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
