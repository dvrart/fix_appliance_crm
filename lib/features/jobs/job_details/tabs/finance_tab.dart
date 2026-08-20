import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/constants.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../models/document_settings.dart';
import '../../../../models/warehouse_item.dart';
import '../../../../services/services.dart';
import '../../../../shared/widgets/keyboard_safe.dart';
import '../../../../shared/widgets/client_signature_sheet.dart';
import '../job_details_controller.dart';
import '../../../../core/l10n/app_locale.dart';

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
  }

  @override
  void dispose() {
    ctrl.removeListener(_onControllerChange);
    super.dispose();
  }

  void _onControllerChange() {
    if (mounted) setState(() {});
  }

  Future<void> _saveBuilder() async {
    if (ctrl.builderItems.isEmpty) return;
    Map<String, dynamic>? signature;
    if (ctrl.builderDocType == 'Invoice') {
      final config = await SettingsService.loadConfig();
      if (SettingsService.boolFlag(config, 'useSignature')) {
        if (!mounted) return;
        final bytes = await ClientSignatureSheet.capture(context);
        if (!mounted) return;
        if (bytes == null) return;
        if (bytes.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Нужна подпись клиента'.tr)),
          );
          return;
        }
        try {
          signature = await ClientSignatureSheet.uploadToJob(
            jobId: ctrl.jobId,
            bytes: bytes,
          );
        } catch (_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Не удалось сохранить подпись'.tr)),
          );
          return;
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
  }

  void _createDocument(String type) {
    ctrl.builderItems.clear();
    ctrl.builderDocType = type;
    ctrl.setFinanceMode('builder');
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
        child: ctrl.documents.isEmpty
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

    Color cardColor;
    Color borderColor;
    IconData icon;
    String statusText;

    if (isCancelled) {
      cardColor = Colors.red.shade50;
      borderColor = Colors.red.shade300;
      icon = Icons.cancel;
      statusText = 'Отменён'.tr;
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
          if (!isCancelled && (isEstimate || due <= 0))
            IconButton(
              tooltip: 'Отправить'.tr,
              icon: const Icon(Icons.send, color: Color(0xFF14557F)),
              onPressed: _busy ? null : () => _sendAppDocument(index),
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
          onPressed: () => ctrl.setFinanceMode('main'),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: ctrl.builderItems.isEmpty ? null : _saveBuilder,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.black,
                disabledBackgroundColor: Colors.grey.shade300,
              ),
              child: Text(
                'Сохранить'.tr,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
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
            padding: const EdgeInsets.all(16),
            color: Colors.white,
            child: Column(
              children: [
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
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _showAddItemDialog,
                    icon: const Icon(Icons.add),
                    label: Text('Добавить позицию'.tr),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _pickPricebookItem,
                    icon: const Icon(Icons.sell_outlined),
                    label: Text('Типовая работа'.tr),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickPricebookItem() async {
    final items = await CatalogService.loadPricebook();
    if (!mounted) return;
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Прайсбук пуст — добавьте работы в Каталоге'.tr)),
      );
      return;
    }
    final selected = await showModalBottomSheet<PricebookItem>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return KeyboardAvoidingSheet(
          fraction: 0.7,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Типовая работа'.tr,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Каталог типичных работ с тремя ценами: Good / Better / Best. Это не запчасть со склада.'.tr,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return ListTile(
                      title: Text(item.name),
                      subtitle: Text(
                        [
                          if (item.applianceType.isNotEmpty) trAny(item.applianceType),
                          'Good \$${item.good.toStringAsFixed(0)}',
                          'Better \$${item.better.toStringAsFixed(0)}',
                          'Best \$${item.best.toStringAsFixed(0)}',
                        ].join(' · '),
                      ),
                      onTap: () => Navigator.pop(context, item),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
    if (selected == null || !mounted) return;
    final tier = await showModalBottomSheet<String>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text('Good  \$${selected.good.toStringAsFixed(2)}'),
                onTap: () => Navigator.pop(context, 'good'),
              ),
              ListTile(
                title: Text('Better  \$${selected.better.toStringAsFixed(2)}'),
                onTap: () => Navigator.pop(context, 'better'),
              ),
              ListTile(
                title: Text('Best  \$${selected.best.toStringAsFixed(2)}'),
                onTap: () => Navigator.pop(context, 'best'),
              ),
            ],
          ),
        );
      },
    );
    if (tier == null) return;
    final price = switch (tier) {
      'better' => selected.better,
      'best' => selected.best,
      _ => selected.good,
    };
    setState(() {
      ctrl.builderItems.add({
        'name': '${selected.name} ($tier)',
        'price': price,
        'qty': 1,
        'type': 'Работа'.tr,
        'pricebookId': selected.id,
        'priceTier': tier,
      });
    });
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
      return Center(child: Text('Документ не найден'.tr));
    }

    final doc = ctrl.documents[ctrl.viewingDocumentIndex!];
    final items = doc['items'] as List? ?? [];
    final payments = doc['payments'] as List? ?? [];
    final isEstimate = doc['type'] == 'Estimate';
    final isCancelled = doc['status'] == 'cancelled';

    final subtotal = ctrl.calcSubtotal(items);
    final tax = ctrl.calcTax(subtotal, doc['taxRate'] ?? 0.0);
    final total = ctrl.calcTotal(subtotal, tax);
    final paid = ctrl.calcPaid(payments);
    final due = ctrl.calcDue(total, paid);

    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: Text('${doc['type']} #${ctrl.viewingDocumentIndex! + 1}'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => ctrl.setFinanceMode('main'),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_busy) const SizedBox(height: 12),
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
    );
  }

  String _stripeUrl(Map<String, dynamic> doc) {
    final stripe = doc['stripe'];
    if (stripe is! Map) return '';
    final url = (stripe['hostedInvoiceUrl'] ?? stripe['url'] ?? '').toString();
    return url;
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

  Future<void> _copyUrl(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Ссылка скопирована'.tr)),
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _resendCurrentLink(Map<String, dynamic> doc) async {
    final url = _stripeUrl(doc);
    final phone = ctrl.contactPhone;
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
    final ok = await SmsService.sendSms(
      to: _toE164(phone),
      body: body,
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
        clientPhone: (ctrl.jobData['clientPhone'] ?? ctrl.contactPhone).toString(),
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
      ),
    );
  }

  Future<void> _sendPaidInvoicePdf(int documentIndex) async {
    for (var i = 0; i < 10; i++) {
      if (documentIndex >= 0 && documentIndex < ctrl.documents.length) {
        final paid = ctrl.calcPaid(
          ctrl.documents[documentIndex]['payments'] ?? [],
        );
        if (paid > 0) break;
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
    final paid = ctrl.calcPaid(doc['payments'] ?? []);
    final due = ctrl.calcDue(total, paid);
    if (paid <= 0) return;

    final ok = await DocumentTemplateService.sendPdfLinkQuietly(
      data: DocumentSendData(
        kind: due <= 0.009 ? 'receipt' : 'invoice',
        jobId: ctrl.jobId,
        clientId: ctrl.clientId,
        clientName: (ctrl.jobData['clientName'] ?? ctrl.contactName).toString(),
        clientPhone:
            (ctrl.jobData['clientPhone'] ?? ctrl.contactPhone).toString(),
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
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Ссылка на PDF отправлена клиенту'.tr
              : 'Не удалось отправить ссылку на PDF'.tr,
        ),
        backgroundColor: ok ? Colors.green : Colors.red,
      ),
    );
  }

  Future<void> _runTapToPay(int documentIndex, {double? amount}) async {
    if (_busy) return;
    if (documentIndex < 0 || documentIndex >= ctrl.documents.length) return;
    final doc = ctrl.documents[documentIndex];
    final subtotal = ctrl.calcSubtotal(doc['items'] ?? []);
    final tax = ctrl.calcTax(subtotal, doc['taxRate'] ?? 0.0);
    final total = ctrl.calcTotal(subtotal, tax);
    final paid = ctrl.calcPaid(doc['payments'] ?? []);
    final due = ctrl.calcDue(total, paid);
    final charge = (amount ?? due);
    if (charge <= 0) return;

    setState(() => _busy = true);
    try {
      final ok = await StripeTerminalService.collectWithDialog(
        context: context,
        jobId: ctrl.jobId,
        documentIndex: documentIndex,
        amount: charge,
      );
      if (!mounted) return;
      await _showPayResult(success: ok, documentIndex: documentIndex);
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
  }) async {
    setState(() => _busy = true);
    try {
      final result = await StripeService.createPayment(
        jobId: ctrl.jobId,
        documentIndex: documentIndex,
        kind: kind,
        amount: amount,
        sendSms: true,
      );
      var smsSent = result.smsSent;
      if (!smsSent && ctrl.contactPhone.isNotEmpty) {
        final docs = await SettingsService.loadDocumentSettings();
        smsSent = await SmsService.sendSms(
          to: ctrl.contactPhone,
          body: DocumentSettings.stripePaySms(
            deposit: kind == 'deposit',
            dollars: result.amount.toStringAsFixed(2),
            url: result.url,
            company: docs.companyName,
            template: docs.paySms,
          ),
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
                    Clipboard.setData(ClipboardData(text: result.url));
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
                return value > maxAmount ? maxAmount : value;
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
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: () {
                          final amount = parsedAmount();
                          Navigator.pop(sheetContext);
                          if (amount > 0) {
                            _runTapToPay(documentIndex, amount: amount);
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
                          _runStripeAction(
                            kind: isDeposit ? 'deposit' : 'checkout',
                            documentIndex: documentIndex,
                            amount: amount,
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
                            _showPaymentDialog(
                              documentIndex,
                              amount: amount,
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
                            _showPaymentDialog(
                              documentIndex,
                              amount: amount,
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

  void _addLocalPayment(int docIndex, double amount, String method) {
    final doc = ctrl.documents[docIndex];
    final payments = List<Map<String, dynamic>>.from(doc['payments'] ?? []);
    payments.add({
      'amount': amount,
      'method': method,
      'date': DateTime.now().toIso8601String(),
    });
    doc['payments'] = payments;
    ctrl.updateDocument(docIndex, doc);
  }

  Future<void> _showPayResult({
    required bool success,
    String? message,
    int? documentIndex,
  }) async {
    if (success && documentIndex != null) {
      _sendPaidInvoicePdf(documentIndex);
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(
            success
                ? 'Спасибо, оплата прошла успешно'.tr
                : 'Оплата не прошла'.tr,
          ),
          content: Text(
            success
                ? 'Thank you. The payment was successful.'
                : (message ?? 'The payment was not successful. Please try again.'),
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
  }

  void _showPaymentDialog(int docIndex, {double? amount, String method = 'Наличные'}) {
    final amountCtrl = TextEditingController(
      text: amount != null && amount > 0 ? amount.toStringAsFixed(2) : '',
    );
    var selectedMethod = method;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text('Принять оплату'.tr),
              scrollable: true,
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: amountCtrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Сумма'.tr,
                      prefixText: '\$ ',
                      border: OutlineInputBorder(),
                      suffixIcon: TextButton(
                        onPressed: () {
                          final doc = ctrl.documents[docIndex];
                          final subtotal = ctrl.calcSubtotal(doc['items'] ?? []);
                          final tax = ctrl.calcTax(subtotal, doc['taxRate'] ?? 0.0);
                          final total = ctrl.calcTotal(subtotal, tax);
                          final paid = ctrl.calcPaid(doc['payments'] ?? []);
                          final due = ctrl.calcDue(total, paid);
                          final half = ((due > 0 ? due : total) * 0.5);
                          amountCtrl.text = half.toStringAsFixed(2);
                          setDialogState(() {});
                        },
                        child: const Text('50%'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    value: selectedMethod,
                    decoration: InputDecoration(
                      labelText: 'Способ оплаты'.tr,
                      border: OutlineInputBorder(),
                    ),
                    items: ['Наличные', 'e-Transfer', 'Чек']
                        .map((m) => DropdownMenuItem(value: m, child: Text(trAny(m))))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setDialogState(() => selectedMethod = v);
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('Отмена'.tr),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final amount = double.tryParse(amountCtrl.text) ?? 0;
                    if (amount <= 0) return;
                    _addLocalPayment(docIndex, amount, selectedMethod);
                    Navigator.pop(context);
                    await _showPayResult(success: true, documentIndex: docIndex);
                  },
                  child: Text('Сохранить'.tr),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
