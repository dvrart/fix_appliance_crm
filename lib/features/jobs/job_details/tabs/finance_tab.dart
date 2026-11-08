import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/app_feedback.dart';
import '../../../../core/constants.dart';
import '../../../../core/l10n/app_locale.dart';
import '../../../../core/motion.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/utils/number_input.dart';
import '../../../../models/client.dart';
import '../../../../models/document_settings.dart';
import '../../../../models/job.dart';
import '../../../../models/labour_discount.dart';
import '../../../../models/warehouse_item.dart';
import '../../../../services/services.dart';
import '../../../../shared/widgets/app_bar_save.dart';
import '../../../../shared/widgets/confirm_action_sheet.dart';
import '../../../../shared/widgets/dispose_on_close.dart';
import '../../../../shared/widgets/keyboard_safe.dart';
import '../../../../shared/widgets/unsaved_changes_dialog.dart';
import '../job_details_controller.dart';
import '../widgets/client_tip_sheet.dart';
import '../../job_review_offer.dart';
import '../../../reports/classify_items_page.dart';
import '../../../reports/report_breakdown_page.dart';
import '../../../reports/report_metrics.dart';

class FinanceTab extends StatefulWidget {
  final JobDetailsController controller;

  const FinanceTab({super.key, required this.controller});

  @override
  State<FinanceTab> createState() => _FinanceTabState();
}

class _FinanceTabState extends State<FinanceTab> {
  JobDetailsController get ctrl => widget.controller;
  bool _busy = false;
  bool _checkingStripe = false;
  int? _lastAutoCheckedDocIndex;
  bool _inPayResult = false;
  DateTime? _lastReviewOfferAt;
  double _minimumCharge = 0;

  DateTime? _extractStripePaidDate(Map<String, dynamic> doc, Map<String, dynamic> stripe) {
    if (stripe['paidAt'] != null && stripe['paidAt'].toString().isNotEmpty) {
      final dt = DateTime.tryParse(stripe['paidAt'].toString());
      if (dt != null) return dt.toLocal();
    }
    final payments = doc['payments'];
    if (payments is List) {
      for (final p in payments.reversed) {
        if (p is Map && (p['method'] ?? '').toString().contains('Stripe')) {
          final d = p['date']?.toString();
          if (d != null && d.isNotEmpty) {
            final dt = DateTime.tryParse(d);
            if (dt != null) return dt.toLocal();
          }
        }
      }
    }
    return null;
  }

  DateTime? _extractStripeCreatedDate(Map<String, dynamic> stripe) {
    if (stripe['createdAt'] != null && stripe['createdAt'].toString().isNotEmpty) {
      final dt = DateTime.tryParse(stripe['createdAt'].toString());
      if (dt != null) return dt.toLocal();
    }
    return null;
  }

  DateTime? _extractStripeRefundDate(Map<String, dynamic> doc, Map<String, dynamic> stripe) {
    if (stripe['refundedAt'] != null && stripe['refundedAt'].toString().isNotEmpty) {
      final dt = DateTime.tryParse(stripe['refundedAt'].toString());
      if (dt != null) return dt.toLocal();
    }
    final payments = doc['payments'];
    if (payments is List) {
      for (final p in payments.reversed) {
        if (p is Map) {
          final m = (p['method'] ?? '').toString().toLowerCase();
          if (m.contains('refund') || m.contains('возврат')) {
            final d = p['date']?.toString();
            if (d != null && d.isNotEmpty) {
              final dt = DateTime.tryParse(d);
              if (dt != null) return dt.toLocal();
            }
          }
        }
      }
    }
    return null;
  }

  void _maybeAutoCheckStripe(int index) {
    if (_lastAutoCheckedDocIndex == index) return;
    if (index < 0 || index >= ctrl.documents.length) return;
    final doc = ctrl.documents[index];
    final stripe = doc['stripe'];
    if (stripe is Map && stripe['status'] == 'open') {
      _lastAutoCheckedDocIndex = index;
      _checkStripePayment(index, silent: true);
    }
  }

  Future<void> _checkStripePayment(int docIndex, {bool silent = false}) async {
    if (_checkingStripe || !mounted) return;
    setState(() => _checkingStripe = true);
    try {
      final res = await StripeService.checkPaymentStatus(
        jobId: ctrl.jobId,
        documentIndex: docIndex,
      );
      if (!mounted) return;
      final paid = res['paid'] == true;
      final status = (res['status'] ?? '').toString();
      final paidAmount = (res['paidAmount'] as num?)?.toDouble() ?? 0;
      final paidAt = res['paidAt']?.toString();

      if (paid) {
        String msg = 'Оплата через Stripe получена'.tr;
        if (paidAmount > 0) {
          msg += ': ${Formatters.formatCurrency(paidAmount)}';
        }
        if (paidAt != null && paidAt.isNotEmpty) {
          final dt = DateTime.tryParse(paidAt);
          if (dt != null) {
            msg += ' (${DateFormat('d MMM, HH:mm', AppLocale.instance.dateLocale).format(dt.toLocal())})';
          }
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: Colors.green.shade700,
          ),
        );
      } else if (!silent) {
        if (status == 'expired') {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Срок действия ссылки Stripe истёк'.tr),
              backgroundColor: Colors.orange.shade800,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Оплата пока не поступила (ссылка ожидает оплаты)'.tr),
            ),
          );
        }
      }
    } catch (e) {
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка проверки: $e'.tr),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _checkingStripe = false);
    }
  }

  static double _money(dynamic value, [double fallback = 0]) {
    if (value is num) return value.toDouble();
    return double.tryParse('$value') ?? fallback;
  }

  @override
  void initState() {
    super.initState();
    ctrl.addListener(_onControllerChange);
    ctrl.saveFinanceBuilder = _commitBuilder;
    ctrl.discardFinanceBuilder = _discardBuilder;
    ctrl.onInvoiceFullyPaid = _onInvoiceFullyPaid;
    _loadMinimumCharge();
  }

  Future<void> _loadMinimumCharge() async {
    try {
      if (WarehouseService.latestCosts.isEmpty) {
        unawaited(
          WarehouseService.streamAll().first.then((_) {
            if (mounted) setState(() {});
          }).catchError((_) {}),
        );
      }
      final config = await SettingsService.loadConfig();
      if (!mounted) return;
      setState(() {
        _minimumCharge = SettingsService.readMinimumCharge(config);
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    ctrl.removeListener(_onControllerChange);
    ctrl.saveFinanceBuilder = null;
    ctrl.discardFinanceBuilder = null;
    if (ctrl.onInvoiceFullyPaid == _onInvoiceFullyPaid) {
      ctrl.onInvoiceFullyPaid = null;
    }
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
          const SnackBar(content: Text('Add items')),
        );
      }
      return false;
    }
    final number = await SettingsService.takeNextDocumentNumber(ctrl.builderDocType);
    final recipient = _recipientForBillTo(ctrl.builderBillTo);
    final doc = {
      'type': ctrl.builderDocType,
      'number': number,
      'billTo': recipient.billTo,
      'billToName': recipient.name,
      'billToPhone': recipient.phone,
      'billToEmail': recipient.email,
      'billToAddress': recipient.address,
      // Скидка на работу пересчитывается по текущей работе в счёте. На
      // технике со стикером работа по плану покрывается целиком.
      'items': _coveredIfPlan(
        LabourDiscount.refresh(
          List<Map<String, dynamic>>.from(ctrl.builderItems),
        ),
      ),
      'taxRate': ctrl.builderTaxRate,
      'payments': <Map<String, dynamic>>[],
      'createdAt': DateTime.now().toIso8601String(),
    };
    await ctrl.addDocument(doc);
    ctrl.setViewingDocumentIndex(ctrl.documents.length - 1);
    ctrl.setFinanceMode('view_document');
    return true;
  }

  void _createDocument(String type, {String? billTo}) {
    ctrl.builderItems.clear();
    ctrl.builderDocType = type;
    ctrl.builderBillTo = billTo ?? 'owner';
    ctrl.setFinanceMode('builder');
  }

  bool _estimateConverted(Map<String, dynamic> doc) {
    return doc['convertedToInvoice'] == true;
  }

  /// В карточке заявки подтверждённая/превращённая в счёт смета скрывается
  /// (видна только в боковом меню «Счета → Сметы»).
  bool _isEstimateHiddenInJobTab(Map<String, dynamic> doc) {
    if ((doc['type'] ?? '') != 'Estimate') return false;
    return _estimateConverted(doc) ||
        (doc['estimateStatus'] ?? '') == 'approved';
  }

  Future<void> _convertEstimateToInvoice(int index) async {
    if (_busy) return;
    if (index < 0 || index >= ctrl.documents.length) return;
    final estimate = Map<String, dynamic>.from(ctrl.documents[index]);
    if ((estimate['type'] ?? '') != 'Estimate') return;
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
        const SnackBar(content: Text('Add items')),
      );
      return;
    }

    setState(() => _busy = true);
    try {
      final number = await SettingsService.takeNextDocumentNumber('Invoice');
      final estBillTo = _docBillTo(estimate);
      final recipient = _recipientForBillTo(estBillTo, doc: estimate);
      final invoice = {
        'type': 'Invoice',
        'number': number,
        'billTo': recipient.billTo,
        'billToName': recipient.name,
        'billToPhone': recipient.phone,
        'billToEmail': recipient.email,
        'billToAddress': recipient.address,
        'items': items,
        'taxRate': estimate['taxRate'] ?? 0.0,
        'payments': <Map<String, dynamic>>[],
        'createdAt': DateTime.now().toIso8601String(),
        'fromEstimateNumber': estimate['number'],
      };
      await ctrl.addDocument(invoice);
      await ctrl.updateDocument(index, {
        ...estimate,
        'estimateStatus': 'approved',
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
    final visibleIndices = <int>[
      for (var index = ctrl.documents.length - 1; index >= 0; index--)
        if (!Job.isDocumentTrashed(ctrl.documents[index]) &&
            !_isEstimateHiddenInJobTab(ctrl.documents[index]))
          index,
    ];
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          if (ctrl.pendingSuggestComplete)
            _buildSuggestCompleteBanner(),
          if (ctrl.pendingSuggestCancel)
            _buildSuggestCancelBanner(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: visibleIndices.isEmpty
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
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 76),
                      children: [
                        for (final index in visibleIndices)
                          _buildDocumentCard(index),
                        _buildJobFinanceSummaryCard(),
                      ],
                    ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showCreateDocumentMenu(),
        backgroundColor: AppColors.accent,
        child: const Icon(Icons.add, color: Colors.black),
      ),
    );
  }

  Widget _buildSuggestCompleteBanner() {
    return Material(
      color: Colors.orange.shade800,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Счёт оплачен. Пометить заявку как завершённую?'.tr,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton(
              onPressed: () => ctrl.confirmSuggestComplete(),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              child: Text(
                'Завершить'.tr,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            TextButton(
              onPressed: () => ctrl.dismissSuggestComplete(),
              style: TextButton.styleFrom(foregroundColor: Colors.white70),
              child: Text('Потом'.tr),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuggestCancelBanner() {
    return Material(
      color: Colors.red.shade700,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Полный возврат. Пометить заявку как отменённую?'.tr,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton(
              onPressed: () => ctrl.confirmSuggestCancel(),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              child: Text(
                'Отменить заявку'.tr,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            TextButton(
              onPressed: () => ctrl.dismissSuggestCancel(),
              style: TextButton.styleFrom(foregroundColor: Colors.white70),
              child: Text('Оставить'.tr),
            ),
          ],
        ),
      ),
    );
  }

  void _showCreateDocumentMenu() {
    showModalBottomSheet(
      sheetAnimationStyle: AppMotion.sheet,
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
    final stamp = Formatters.messageStamp(Job.documentCreatedAt(doc));

    final items = [
      for (final item in doc['items'] as List? ?? [])
        if (item is Map) Map<String, dynamic>.from(item),
    ];
    final subtotal = ctrl.calcSubtotal(items);
    final taxRate = _money(doc['taxRate'], 0.0);
    final tax = ctrl.calcTax(subtotal, taxRate);
    final total = ctrl.calcTotal(subtotal, tax);
    final paid = ctrl.calcPaid(doc['payments'] ?? []);
    final due = ctrl.calcDue(total, paid);

    final isPaid = !isEstimate && total > 0 && due == 0;
    final isPartiallyPaid = !isEstimate && paid > 0 && due > 0;
    final estimateStatus = (doc['estimateStatus'] ?? '').toString();
    final estimateApproved = isEstimate && estimateStatus == 'approved';
    final estimateSent = isEstimate && estimateStatus == 'sent';

    Color accentColor;
    Color badgeBg;
    Color badgeFg;
    IconData statusIcon;
    String statusText;

    if (isCancelled) {
      accentColor = Colors.red.shade600;
      badgeBg = Colors.red.shade50;
      badgeFg = Colors.red.shade700;
      statusIcon = Icons.cancel_outlined;
      statusText = 'Отменён'.tr;
    } else if (estimateApproved) {
      accentColor = const Color(0xFF16A34A);
      badgeBg = const Color(0xFFDCFCE7);
      badgeFg = const Color(0xFF15803D);
      statusIcon = Icons.verified_rounded;
      statusText = 'Клиент подтвердил ремонт'.tr;
    } else if (estimateSent) {
      accentColor = const Color(0xFFF59E0B);
      badgeBg = const Color(0xFFFEF3C7);
      badgeFg = const Color(0xFFB45309);
      statusIcon = Icons.hourglass_top_rounded;
      statusText = 'Ждём согласие клиента'.tr;
    } else if (isEstimate) {
      accentColor = Colors.orange.shade700;
      badgeBg = Colors.orange.shade50;
      badgeFg = Colors.orange.shade800;
      statusIcon = Icons.description_outlined;
      statusText = 'Смета'.tr;
    } else if (isPaid) {
      accentColor = const Color(0xFF16A34A);
      badgeBg = const Color(0xFFDCFCE7);
      badgeFg = const Color(0xFF15803D);
      statusIcon = Icons.check_circle_rounded;
      statusText = 'Оплачен'.tr;
    } else if (_isRefundedDoc(doc)) {
      accentColor = Colors.red.shade600;
      badgeBg = Colors.red.shade50;
      badgeFg = Colors.red.shade700;
      statusIcon = Icons.undo_rounded;
      statusText = paid > 0.009
          ? '${'Частичный возврат'.tr}: \$${paid.toStringAsFixed(2)}'
          : 'Возврат'.tr;
    } else if (Job.documentPayMark(doc) == 'deposit') {
      accentColor = const Color(0xFFF59E0B);
      badgeBg = const Color(0xFFFEF3C7);
      badgeFg = const Color(0xFFB45309);
      statusIcon = Icons.savings_outlined;
      statusText = paid > 0
          ? '${'Депозит'.tr}: \$${paid.toStringAsFixed(2)}'
          : 'Депозит'.tr;
    } else if (isPartiallyPaid) {
      accentColor = const Color(0xFFF59E0B);
      badgeBg = const Color(0xFFFEF3C7);
      badgeFg = const Color(0xFFB45309);
      statusIcon = Icons.timelapse_rounded;
      statusText = '${'Остаток'.tr}: \$${due.toStringAsFixed(2)}';
    } else {
      accentColor = AppColors.primary;
      badgeBg = const Color(0xFFFEE2E2);
      badgeFg = const Color(0xFFB91C1C);
      statusIcon = Icons.circle_outlined;
      statusText = 'Неоплачен'.tr;
    }

    final methods = (!isCancelled && !isEstimate)
        ? Job.documentPayMethods(doc)
        : null;
    final docTitle =
        '${isEstimate ? 'ESTIMATE' : 'INVOICE'} #${doc['number'] ?? (index + 1)}';

    // Открытый документ в мини-формате А4: белый лист с шапкой, сразу
    // крупной суммой справа, строками позиций и кратким итогом.
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            ctrl.setViewingDocumentIndex(index);
            ctrl.setFinanceMode('view_document');
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(height: 4, color: accentColor),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    isEstimate
                                        ? Icons.description_outlined
                                        : Icons.receipt_long_rounded,
                                    size: 16,
                                    color: accentColor,
                                  ),
                                  const SizedBox(width: 5),
                                  Flexible(
                                    child: Text(
                                      docTitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w900,
                                        fontSize: 14.5,
                                        letterSpacing: 0.4,
                                        color: AppColors.ink,
                                      ),
                                    ),
                                  ),
                                  if (stamp.isNotEmpty) ...[
                                    const SizedBox(width: 6),
                                    Text(
                                      stamp,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.inkMuted,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: badgeBg,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          statusIcon,
                                          size: 12,
                                          color: badgeFg,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          statusText,
                                          style: TextStyle(
                                            color: badgeFg,
                                            fontWeight: FontWeight.w800,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (methods != null && methods.hasAny)
                                    Text(
                                      [
                                        if (methods.deposit.isNotEmpty)
                                          '${'Депозит'.tr}: ${methods.deposit}',
                                        if (methods.balance.isNotEmpty)
                                          '${'Баланс'.tr}: ${methods.balance}',
                                      ].join(' · '),
                                      style: TextStyle(
                                        color: AppColors.inkMuted,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  _buildBillToBadge(doc),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              Formatters.formatCurrency(total),
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 19,
                                height: 1.05,
                                color: isCancelled
                                    ? Colors.red.shade700
                                    : isPaid
                                        ? const Color(0xFF15803D)
                                        : AppColors.primaryOnCard,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!isCancelled &&
                                    isEstimate &&
                                    !_estimateConverted(doc))
                                  _docHeaderIconButton(
                                    tooltip: 'Подтвердить → Сделать счёт'.tr,
                                    icon: Icons.check_circle_outline_rounded,
                                    color: const Color(0xFF2E7D32),
                                    onPressed: _busy
                                        ? null
                                        : () => _convertEstimateToInvoice(index),
                                  ),
                                if (!isCancelled && (isEstimate || due <= 0))
                                  _docHeaderIconButton(
                                    tooltip: 'Отправить'.tr,
                                    icon: Icons.send_rounded,
                                    color: AppColors.primaryOnCard,
                                    onPressed: _busy
                                        ? null
                                        : () => _sendAppDocument(index),
                                  ),
                                _docHeaderIconButton(
                                  tooltip: 'В корзину'.tr,
                                  icon: Icons.delete_outline_rounded,
                                  color: Colors.red.shade600,
                                  onPressed: _busy
                                      ? null
                                      : () => _confirmDeleteDocument(index),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                    if (items.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Divider(
                          height: 1,
                          thickness: 1,
                          color: AppColors.border,
                        ),
                      ),
                      for (final item in items)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  (item['name'] ?? 'Item').toString(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.ink,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              if (_money(item['qty'], 1) != 1)
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: Text(
                                    '${_formatQty(_money(item['qty'], 1))} × \$${_money(item['price']).toStringAsFixed(2)}',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: AppColors.inkMuted,
                                    ),
                                  ),
                                ),
                              Text(
                                '\$${(_money(item['qty'], 1) * _money(item['price'])).toStringAsFixed(2)}',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.ink,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                    Padding(
                      padding: const EdgeInsets.only(top: 6, bottom: 4),
                      child: Divider(
                        height: 1,
                        thickness: 1,
                        color: AppColors.border,
                      ),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            [
                              'Subtotal \$${subtotal.toStringAsFixed(2)}',
                              if (tax > 0.009)
                                'Tax ${(taxRate * 100).round()}% \$${tax.toStringAsFixed(2)}',
                              if (!isEstimate && paid > 0.009)
                                '${'Оплачено'.tr} \$${paid.toStringAsFixed(2)}',
                              if (!isEstimate && due > 0.009 && paid > 0.009)
                                '${'Остаток'.tr} \$${due.toStringAsFixed(2)}',
                            ].join('  ·  '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: AppColors.inkMuted,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'TOTAL \$${total.toStringAsFixed(2)}',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w900,
                            color: AppColors.ink,
                          ),
                        ),
                      ],
                    ),
                    if (!isCancelled &&
                        doc['stripe'] is Map &&
                        ((doc['stripe']['url'] ?? '').toString().isNotEmpty ||
                            _isStripeRefunded(doc)))
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          _stripeLineSummary(doc),
                          style: TextStyle(
                            color: (doc['stripe']['status'] == 'paid')
                                ? Colors.green.shade700
                                : (doc['stripe']['status'] == 'refunded' ||
                                        doc['stripe']['status'] ==
                                            'partially_refunded')
                                    ? Colors.red.shade700
                                    : (doc['stripe']['status'] == 'expired')
                                        ? Colors.orange.shade800
                                        : const Color(0xFF635BFF),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _docHeaderIconButton({
    required String tooltip,
    required IconData icon,
    required Color color,
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      width: 28,
      height: 26,
      child: IconButton(
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        tooltip: tooltip,
        icon: Icon(icon, size: 17, color: color),
        onPressed: onPressed,
      ),
    );
  }

  String _formatQty(double qty) {
    return qty == qty.roundToDouble()
        ? qty.toStringAsFixed(0)
        : qty.toStringAsFixed(2);
  }

  String _stripeLineSummary(Map<String, dynamic> doc) {
    final stripeMap = Map<String, dynamic>.from(doc['stripe'] as Map);
    final status = (stripeMap['status'] ?? '').toString();
    if (status == 'refunded') {
      final rd = _extractStripeRefundDate(doc, stripeMap);
      final rDate = rd != null
          ? ' • ${DateFormat('d MMM, HH:mm', AppLocale.instance.dateLocale).format(rd)}'
          : '';
      return '${'Stripe: возврат'.tr}$rDate';
    }
    if (status == 'partially_refunded') {
      final rd = _extractStripeRefundDate(doc, stripeMap);
      final rDate = rd != null
          ? ' • ${DateFormat('d MMM, HH:mm', AppLocale.instance.dateLocale).format(rd)}'
          : '';
      return '${'Stripe: частичный возврат'.tr}$rDate';
    }
    if (status == 'paid') {
      final pd = _extractStripePaidDate(doc, stripeMap);
      final pDate = pd != null
          ? ' • ${DateFormat('d MMM, HH:mm', AppLocale.instance.dateLocale).format(pd)}'
          : '';
      return '${'Stripe: оплачен'.tr}$pDate';
    }
    if (status == 'expired') {
      return 'Stripe: ссылка истекла'.tr;
    }
    final cd = _extractStripeCreatedDate(stripeMap);
    final cDate = cd != null
        ? ' • ${DateFormat('d MMM, HH:mm', AppLocale.instance.dateLocale).format(cd)}'
        : '';
    return '${'Stripe: ожидает оплаты'.tr}$cDate';
  }

  /// Техника заявки на плане и с наклейкой: ремонт по ней бесплатный.
  bool get _coveredByPlan {
    final ids = ctrl.jobData['applianceIds'];
    if (ids is! List) return false;
    for (final id in ids) {
      final appliance = CarePlanService.applianceById(id.toString());
      if (appliance != null &&
          appliance.planId.isNotEmpty &&
          appliance.stickerPrintedAt != null) {
        return true;
      }
    }
    return false;
  }

  List<Map<String, dynamic>> _coveredIfPlan(List<Map<String, dynamic>> items) =>
      _coveredByPlan ? LabourDiscount.coverLabour(items) : items;

  String _discountLabel(List<Map<String, dynamic>> items) {
    final discount = LabourDiscount.discountOf(items);
    if (discount == null) return context.tr('Скидка', 'Discount');
    final whole = discount['discountWholeInvoice'] == true;
    final fixed = discount['discountFixed'] == true;
    final value = double.tryParse(
      '${discount['discountValue'] ?? discount['discountPercent'] ?? 0}',
    ) ?? 0;
    final price = double.tryParse('${discount['price'] ?? 0}') ?? 0;
    final amount = fixed
        ? '\$${(-price).toStringAsFixed(2)}'
        : '${value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString()}%';
    return '${whole ? context.tr('Скидка на весь счёт', 'Invoice discount') : context.tr('Скидка на работу', 'Labour discount')}: $amount';
  }

  /// Скидка только на работу (Care Plan или любая другая): строка счёта
  /// с отрицательной ценой, база — позиции с меткой «работа».
  ///
  /// [items] — позиции конструктора или уже сохранённого счёта. null из
  /// диалога — отмена, не «убрать скидку».
  Future<({double value, bool fixedAmount, bool wholeInvoice})?> _askLabourDiscount(List<Map<String, dynamic>> items) async {
    String pctText(double v) =>
        v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
    final base = LabourDiscount.labourBase(items);
    final plan = CarePlanService.memberPlanFor(
      clientId: ctrl.clientId,
      phone: (ctrl.jobData['clientPhone'] ?? '').toString(),
    );
    final double? planPct =
        plan != null && plan.repairBenefitsActive(DateTime.now())
        ? plan.discountPercent
        : null;
    final current = LabourDiscount.discountOf(items);
    var fixedAmount = current?['discountFixed'] == true;
    var wholeInvoice = current?['discountWholeInvoice'] == true;
    final currentValue = double.tryParse(
      '${current?['discountValue'] ?? current?['discountPercent'] ?? planPct ?? 0}',
    ) ?? 0;
    final input = TextEditingController(
      text: fixedAmount ? currentValue.toStringAsFixed(2) : pctText(currentValue),
    );
    final result = await showDialog<({double value, bool fixedAmount, bool wholeInvoice})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (context, setDialog) => DisposeOnClose(
        disposables: [input],
        child: AlertDialog(
          title: Text(context.tr('Скидка', 'Discount')),
          content: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${context.tr('Работа в счёте', 'Labour in this invoice')}: \$${base.toStringAsFixed(2)}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text('${context.tr('Весь счёт', 'Whole invoice')}: \$${LabourDiscount.invoiceBase(items).toStringAsFixed(2)}'),
              if (planPct != null)
                Text(
                  planPct >= 100
                      ? 'Care Plan: ${'ремонт бесплатно'.tr}'
                      : 'Care Plan: −${pctText(planPct)}%',
                  style: const TextStyle(
                    color: Color(0xFF2E7D32),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              const SizedBox(height: 10),
              DropdownButtonFormField<bool>(
                initialValue: wholeInvoice,
                decoration: InputDecoration(labelText: context.tr('Применить к', 'Apply to')),
                items: [
                  DropdownMenuItem(value: false, child: Text(context.tr('Только работа', 'Labour only'))),
                  DropdownMenuItem(value: true, child: Text(context.tr('Весь счёт', 'Whole invoice'))),
                ],
                onChanged: (value) => setDialog(() => wholeInvoice = value ?? false),
              ),
              DropdownButtonFormField<bool>(
                initialValue: fixedAmount,
                decoration: InputDecoration(labelText: context.tr('Вид скидки', 'Discount type')),
                items: [
                  DropdownMenuItem(value: false, child: Text(context.tr('Процент', 'Percent'))),
                  DropdownMenuItem(value: true, child: Text(context.tr('Сумма', 'Amount'))),
                ],
                onChanged: (value) => setDialog(() => fixedAmount = value ?? false),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: input,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: fixedAmount ? '\$' : '%',
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          )),
          actions: [
            if (current != null)
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, (value: 0.0, fixedAmount: fixedAmount, wholeInvoice: wholeInvoice)),
                child: Text(context.tr('Убрать', 'Remove')),
              ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(context.tr('Отмена', 'Cancel')),
            ),
            FilledButton(
              onPressed: () {
                final value = double.tryParse(input.text.replaceAll(',', '.').trim());
                if (value == null || !value.isFinite || value < 0) return;
                Navigator.pop(dialogContext,
                  (value: value, fixedAmount: fixedAmount, wholeInvoice: wholeInvoice));
              },
              child: Text(context.tr('Применить', 'Apply')),
            ),
          ],
        ),
      )),
    );
    if (result == null || !mounted) return null;
    if (result.value > 0 && (result.wholeInvoice ? LabourDiscount.invoiceBase(items) : base) <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr(
              result.wholeInvoice ? 'В счёте нет суммы для скидки' : 'В счёте нет позиций с меткой «работа»',
              result.wholeInvoice ? 'No invoice amount to discount' : 'No labour lines in this invoice',
            ),
          ),
        ),
      );
      return null;
    }
    return result;
  }

  Future<void> _labourDiscountDialog() async {
    final items = List<Map<String, dynamic>>.from(ctrl.builderItems);
    final result = await _askLabourDiscount(items);
    if (result == null || !mounted) return;
    final plan = CarePlanService.memberPlanFor(
      clientId: ctrl.clientId,
      phone: (ctrl.jobData['clientPhone'] ?? '').toString(),
    );
    final planPct = plan != null && plan.repairBenefitsActive(DateTime.now())
        ? plan.discountPercent
        : null;
    setState(() {
      final next = LabourDiscount.apply(
        items,
        result.value,
        fixedAmount: result.fixedAmount,
        wholeInvoice: result.wholeInvoice,
        carePlan: !result.fixedAmount && !result.wholeInvoice && planPct != null && result.value == planPct,
      );
      ctrl.builderItems
        ..clear()
        ..addAll(next);
    });
  }

  /// Та же скидка на уже сохранённом счёте. Оплаты и склад не трогаем:
  /// строка скидки — услуга, запчасти со склада не списывает.
  Future<void> _discountSavedDocument(int docIndex) async {
    if (_busy) return;
    if (docIndex < 0 || docIndex >= ctrl.documents.length) return;
    final doc = Map<String, dynamic>.from(ctrl.documents[docIndex]);
    final items = [
      for (final item in doc['items'] as List? ?? [])
        if (item is Map) Map<String, dynamic>.from(item),
    ];
    final result = await _askLabourDiscount(items);
    if (result == null || !mounted) return;
    final plan = CarePlanService.memberPlanFor(
      clientId: ctrl.clientId,
      phone: (ctrl.jobData['clientPhone'] ?? '').toString(),
    );
    final planPct = plan != null && plan.repairBenefitsActive(DateTime.now())
        ? plan.discountPercent
        : null;
    final next = LabourDiscount.refresh(
      LabourDiscount.apply(
        items,
        result.value,
        fixedAmount: result.fixedAmount,
        wholeInvoice: result.wholeInvoice,
        carePlan: !result.fixedAmount && !result.wholeInvoice && planPct != null && result.value == planPct,
      ),
    );
    setState(() => _busy = true);
    try {
      await ctrl.updateDocument(docIndex, {...doc, 'items': next});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _buildDocumentBuilder() {
    // Строка скидки на работу всегда считается от текущей работы в счёте.
    final shownItems = _coveredIfPlan(
      LabourDiscount.refresh(
        List<Map<String, dynamic>>.from(ctrl.builderItems),
      ),
    );
    final subtotal = ctrl.calcSubtotal(shownItems);
    final tax = ctrl.calcTax(subtotal, ctrl.builderTaxRate);
    final total = ctrl.calcTotal(subtotal, tax);
    final canSave = ctrl.builderItems.isNotEmpty;

    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        toolbarHeight: 40,
        titleSpacing: 4,
        title: Text(
          ctrl.builderDocType == 'Estimate' ? 'Estimate' : 'Invoice',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: const Icon(Icons.close, size: 20),
          onPressed: _onCloseBuilder,
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: _buildBillToSelector(
              currentBillTo: ctrl.builderBillTo,
              onChanged: (next) {
                setState(() => ctrl.builderBillTo = next);
                ctrl.notifyBuilderChanged();
              },
            ),
          ),
          Expanded(
            child: ctrl.builderItems.isEmpty
                ? Center(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () async {
                        final created = await _showAddItemDialog();
                        if (created == null || !mounted) return;
                        setState(() => ctrl.builderItems.add(created));
                        ctrl.notifyBuilderChanged();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        child: Text(
                          context.tr('+ Добавить позицию', '+ Add item'),
                          style: TextStyle(
                            color: AppColors.primaryOnCard,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  )
                : Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            context.tr(
                              'Нажмите на строку для правки',
                              'Tap a line to edit',
                            ),
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.inkMuted,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          itemCount: shownItems.length,
                          itemBuilder: (context, index) {
                            final item = shownItems[index];
                            final qty = _money(item['qty'], 1);
                            final price = _money(item['price']);
                            return Container(
                              margin: const EdgeInsets.only(bottom: 5),
                              decoration: BoxDecoration(
                                color: AppColors.card,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: AppColors.border,
                                ),
                              ),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () => _editBuilderItem(index),
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    10,
                                    6,
                                    4,
                                    6,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              (item['name'] ?? 'Item')
                                                  .toString(),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 13.5,
                                                fontWeight: FontWeight.w700,
                                                color: AppColors.ink,
                                              ),
                                            ),
                                            const SizedBox(height: 1),
                                            _buildItemSubtitle(item),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        '\$${(qty * price).toStringAsFixed(2)}',
                                        style: TextStyle(
                                          fontSize: 13.5,
                                          fontWeight: FontWeight.w800,
                                          color: AppColors.ink,
                                        ),
                                      ),
                                      SizedBox(
                                        width: 30,
                                        height: 28,
                                        child: IconButton(
                                          padding: EdgeInsets.zero,
                                          visualDensity: VisualDensity.compact,
                                          icon: const Icon(
                                            Icons.close_rounded,
                                            size: 18,
                                            color: Colors.red,
                                          ),
                                          onPressed: () {
                                            setState(() {
                                              ctrl.builderItems.removeAt(index);
                                            });
                                            ctrl.notifyBuilderChanged();
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
          ),
          // Компактные итоги и кнопки
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(
              color: AppColors.card,
              border: Border(top: BorderSide(color: AppColors.border)),
            ),
            child: SafeArea(
              top: false,
              minimum: const EdgeInsets.only(bottom: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Subtotal',
                        style: TextStyle(fontSize: 12.5, color: AppColors.ink),
                      ),
                      Text(
                        '\$${subtotal.toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  if (_minimumCharge > 0 &&
                      subtotal > 0 &&
                      subtotal < _minimumCharge)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.info_outline,
                            size: 14,
                            color: Colors.orange,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              '${'Минимальный чек'.tr} '
                              '${SettingsService.formatMoney(_minimumCharge)}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.orange,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        'Tax',
                        style: TextStyle(fontSize: 12.5, color: AppColors.ink),
                      ),
                      const SizedBox(width: 8),
                      DropdownButton<double>(
                        value: ctrl.builderTaxRate,
                        isDense: true,
                        underline: const SizedBox.shrink(),
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primaryOnCard,
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: TaxRates.hst,
                            child: Text('HST 13%'),
                          ),
                          DropdownMenuItem(
                            value: TaxRates.gst,
                            child: Text('GST 5%'),
                          ),
                          DropdownMenuItem(
                            value: TaxRates.none,
                            child: Text('No tax 0%'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() => ctrl.builderTaxRate = value);
                        },
                      ),
                      const Spacer(),
                      Text(
                        '\$${tax.toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Total',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        '\$${total.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                          color: AppColors.primary,
                        ),
                      ),
                    ],
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: canSave ? _labourDiscountDialog : null,
                      icon: const Icon(Icons.percent, size: 18),
                      label: Text(
                        _discountLabel(shownItems),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 38,
                          child: ElevatedButton.icon(
                            onPressed: () async {
                              final created = await _showAddItemDialog();
                              if (created == null || !mounted) return;
                              setState(() => ctrl.builderItems.add(created));
                              ctrl.notifyBuilderChanged();
                            },
                            icon: const Icon(Icons.add_rounded, size: 19),
                            label: Text(
                              context.tr('Позиция', 'Add item'),
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 13.5,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.accent,
                              foregroundColor: AppColors.primary,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SizedBox(
                          height: 38,
                          child: ElevatedButton.icon(
                            onPressed: () {
                              if (!canSave) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Добавьте позиции'.tr),
                                  ),
                                );
                                return;
                              }
                              _commitBuilder();
                            },
                            icon: const Icon(Icons.check_rounded, size: 20),
                            label: Text(
                              context.tr('Готово', 'Done'),
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 13.5,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: canSave
                                  ? kConfirmGreen
                                  : Colors.grey.shade400,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _swapHeader(String text, {Color color = Colors.black54}) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  /// Строка склада в окне «Add item». [swapNote] делает её заменой:
  /// жёлтый ярлык «Взаимозаменяемо» и короткая причина.
  Widget _warehouseRow({
    required WarehouseItem item,
    required bool selected,
    required VoidCallback onTap,
    String? swapNote,
    bool byAi = false,
    bool outOfStock = false,
  }) {
    final isSwap = swapNote != null;
    return ListTile(
      dense: true,
      selected: selected,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        outOfStock
            ? Icons.shopping_cart_outlined
            : isSwap
            ? Icons.swap_horiz
            : Icons.inventory_2_outlined,
        color: outOfStock
            ? const Color(0xFFB3261E)
            : isSwap
            ? const Color(0xFFB07800)
            : null,
      ),
      title: Row(
        children: [
          Flexible(child: Text(item.name, overflow: TextOverflow.ellipsis)),
          if (isSwap) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFFFCC520).withValues(alpha: 0.28),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (byAi)
                    const Padding(
                      padding: EdgeInsets.only(right: 3),
                      child: Icon(
                        Icons.auto_awesome,
                        size: 11,
                        color: Color(0xFF8A6100),
                      ),
                    ),
                  Text(
                    'Взаимозаменяемо'.tr,
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF8A6100),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        [
          if (item.partNumber.isNotEmpty) item.partNumber,
          outOfStock ? 'нет в наличии'.tr : '${'на складе'.tr} ${item.quantity}',
          if (isSwap && swapNote.isNotEmpty) swapNote,
        ].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: outOfStock
            ? const TextStyle(color: Color(0xFFB3261E), fontSize: 12)
            : null,
      ),
      trailing: Text('\$${item.price.toStringAsFixed(2)}'),
      onTap: onTap,
    );
  }

  /// Позиция в уже сохранённый счёт или смету — та же карточка, что при
  /// создании. Склад доводим до нового состава, иначе добавленная со склада
  /// деталь не спишется.
  Future<void> _addDocumentItem(int docIndex) async {
    if (_busy) return;
    if (docIndex < 0 || docIndex >= ctrl.documents.length) return;
    final doc = Map<String, dynamic>.from(ctrl.documents[docIndex]);
    final created = await _showAddItemDialog();
    if (created == null || !mounted) return;
    if (docIndex >= ctrl.documents.length) return;
    final items = [
      for (final item in doc['items'] as List? ?? [])
        if (item is Map) Map<String, dynamic>.from(item),
    ];
    final nextItems = [...items, created];
    final refreshed = _coveredIfPlan(LabourDiscount.refresh(nextItems));

    setState(() => _busy = true);
    try {
      await WarehouseService.applyDocumentStockChange(
        {...doc, 'items': items},
        {...doc, 'items': refreshed},
      );
      await ctrl.updateDocument(docIndex, {...doc, 'items': refreshed});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Возвращает собранную позицию. Черновик дописывает её сам, а открытый
  /// счёт сохраняет в документ — так одна карточка работает в обоих местах.
  Future<Map<String, dynamic>?> _showAddItemDialog() async {
    final nameCtrl = TextEditingController();
    final priceCtrl = TextEditingController();
    final qtyCtrl = TextEditingController(text: '1');
    List<WarehouseItem> warehouse = const [];
    var markup = 0.0;
    var serviceCall = 0.0;
    var hourly = 0.0;
    try {
      warehouse = await WarehouseService.streamAll().first;
      final config = await SettingsService.loadConfig();
      markup = SettingsService.readPartsMarkupPercent(config);
      serviceCall = SettingsService.readServiceCallFee(config);
      hourly = SettingsService.readHourlyRate(config);
    } catch (_) {}
    if (!mounted) return null;
    WarehouseItem? picked;
    // Работа или запчасть — это выбирает мастер, а не угадывают отчёты.
    // По умолчанию работа: выезд и диагностика добавляются чаще всего.
    var isPart = false;
    var kindTouched = false;
    final costCtrl = TextEditingController();

    // Замены: сначала то, что уже записано в карточке детали, потом — что
    // подсказал ИИ. Ключ — нормализованный искомый номер.
    // Цена и количество подставлены нами, человек их ещё не трогал: первый
    // тап по такому полю очищает его, дальше поле ведёт себя как обычно.
    var priceFresh = true;
    var qtyFresh = true;

    Map<String, dynamic>? created;
    var aiForPart = '';
    var aiBusy = false;
    var aiWhy = <String, String>{};
    final aiAsked = <String>{};
    Timer? aiDebounce;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return DisposeOnClose(
          disposables: [nameCtrl, priceCtrl, qtyCtrl, costCtrl],
          child: StatefulBuilder(
            builder: (context, setDialog) {
              final raw = nameCtrl.text.trim();
              final query = raw.toLowerCase();
              final wantedPart = WarehouseItem.normalizePart(raw);
              final matches = query.length < 2
                  ? const <WarehouseItem>[]
                  : warehouse.where((item) {
                      // По номеру ищем так же, как на складе: с «заменяет
                      // номера» и без оглядки на дефисы в артикуле.
                      return item.name.toLowerCase().contains(query) ||
                          WarehouseItem.numberMatches(raw, item.searchNumbers);
                    }).take(6).toList();

              final matchIds = {for (final item in matches) item.id};

              // Номер похож на артикул и в наличии его нет — тогда ищем замену.
              final looksLikePart =
                  wantedPart.length >= 4 && RegExp(r'\d').hasMatch(wantedPart);
              final inStock = warehouse.any(
                (item) =>
                    item.quantity > 0 &&
                    WarehouseItem.normalizePart(item.partNumber) == wantedPart,
              );
              final needSubstitute = looksLikePart && !inStock;

              final saved = needSubstitute
                  ? warehouse
                        .where(
                          (item) =>
                              !matchIds.contains(item.id) && item.replaces(raw),
                        )
                        .take(6)
                        .toList()
                  : const <WarehouseItem>[];

              final fromAi = needSubstitute && aiForPart == wantedPart
                  ? warehouse
                        .where(
                          (item) =>
                              aiWhy.containsKey(item.id) &&
                              !matchIds.contains(item.id) &&
                              !saved.any((other) => other.id == item.id),
                        )
                        .toList()
                  : const <WarehouseItem>[];

              // Что лежит на полке — ставим сегодня. Чего нет — надо заказать,
              // но знать про это тоже нужно, поэтому идёт вторым блоком.
              final swapsInStock = [
                ...saved.where((item) => item.quantity > 0),
                ...fromAi.where((item) => item.quantity > 0),
              ];
              final swapsToOrder = [
                ...saved.where((item) => item.quantity <= 0),
                ...fromAi.where((item) => item.quantity <= 0),
              ];
              String swapNoteFor(WarehouseItem item) {
                final why = aiWhy[item.id];
                if (why != null) {
                  return why.isNotEmpty
                      ? why
                      : context.tr('подсказал ИИ', 'AI suggestion');
                }
                return context.tr('ваша пометка', 'your note');
              }

              // Спрашиваем ИИ только когда человек перестал печатать: иначе
              // запрос уходил бы на каждую букву.
              void maybeAskAi() {
                if (!needSubstitute || saved.isNotEmpty) return;
                if (aiAsked.contains(wantedPart) || aiBusy) return;
                aiDebounce?.cancel();
                aiDebounce = Timer(const Duration(milliseconds: 900), () async {
                  if (WarehouseItem.normalizePart(nameCtrl.text.trim()) !=
                      wantedPart) {
                    return;
                  }
                  aiAsked.add(wantedPart);
                  setDialog(() => aiBusy = true);
                  // Сначала то, что на полке: если список упрётся в лимит,
                  // обрежется хвост из того, чего всё равно нет.
                  final pool = warehouse
                      .where((item) => item.partNumber.trim().isNotEmpty)
                      .toList()
                    ..sort((a, b) => b.quantity.compareTo(a.quantity));
                  final stock = pool
                      .take(70)
                      .map(
                        (item) => {
                          'id': item.id,
                          'partNumber': item.partNumber,
                          'name': item.name,
                          'modelNumber': item.modelNumber ?? '',
                        },
                      )
                      .toList();
                  final result = await AiService.findInterchangeableParts(
                    wantedPart: raw,
                    stock: stock,
                  );
                  if (!dialogContext.mounted) return;
                  setDialog(() {
                    aiBusy = false;
                    aiForPart = wantedPart;
                    aiWhy = result;
                  });
                });
              }

              maybeAskAi();

              void choose(WarehouseItem item, {String? remember}) {
                picked = item;
                nameCtrl.text = item.name;
                final cost = item.costPrice;
                final price = cost != null && markup > 0
                    ? double.parse(
                        (cost * (1 + markup / 100)).toStringAsFixed(2),
                      )
                    : item.price;
                priceCtrl.text = price.toStringAsFixed(2);
                priceFresh = true;
                // Со склада — всегда запчасть, себестоимость уже известна.
                isPart = true;
                kindTouched = true;
                if (cost != null) costCtrl.text = cost.toStringAsFixed(2);
                // Взяли замену — запоминаем её в карточке, чтобы в следующий раз
                // она нашлась сразу и без интернета.
                if (remember != null && !item.replaces(remember)) {
                  final next = [...item.interchange, remember.toUpperCase()];
                  unawaited(
                    WarehouseService.update(item.id, {'interchange': next}),
                  );
                }
                setDialog(() {});
              }

              // Быстрые кнопки из «Настройки → Прайс», чтобы не набирать руками.
              void fill(String name, double price) {
                picked = null;
                nameCtrl.text = name;
                priceCtrl.text = price.toStringAsFixed(2);
                priceFresh = true;
                isPart = false;
                kindTouched = true;
                costCtrl.clear();
                setDialog(() {});
              }

              return AlertDialog(
                title: const Text('Add item'),
                scrollable: true,
                content: SizedBox(
                  width: 360,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (serviceCall > 0 || hourly > 0) ...[
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Wrap(
                            spacing: 8,
                            children: [
                              if (serviceCall > 0)
                                ActionChip(
                                  avatar: const Icon(
                                    Icons.directions_car,
                                    size: 18,
                                    color: Colors.orange,
                                  ),
                                  label: Text(
                                    '${'Вызов'.tr} '
                                    '${SettingsService.formatMoney(serviceCall)}',
                                  ),
                                  onPressed: () =>
                                      fill('Service call', serviceCall),
                                ),
                              if (hourly > 0)
                                ActionChip(
                                  avatar: const Icon(
                                    Icons.schedule,
                                    size: 18,
                                    color: Colors.indigo,
                                  ),
                                  label: Text(
                                    '${'Час'.tr} '
                                    '${SettingsService.formatMoney(hourly)}',
                                  ),
                                  onPressed: () => fill('Labour', hourly),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextField(
                        controller: nameCtrl,
                        onChanged: (_) {
                          if (picked != null &&
                              nameCtrl.text.trim() != picked!.name) {
                            picked = null;
                          }
                          if (!kindTouched && picked == null) {
                            isPart = guessIsPart({'name': nameCtrl.text});
                          }
                          setDialog(() {});
                        },
                        decoration: const InputDecoration(
                          labelText: 'Name',
                          hintText: 'Start typing — search warehouse',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      if (matches.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        ...matches.map(
                          (item) => _warehouseRow(
                            item: item,
                            selected: picked?.id == item.id,
                            onTap: () => choose(item),
                          ),
                        ),
                      ],
                      if (saved.isNotEmpty || fromAi.isNotEmpty || aiBusy) ...[
                        if (aiBusy) ...[
                          const SizedBox(height: 10),
                          _swapHeader(
                            context.tr('Ищу замену…', 'Looking for a substitute…'),
                          ),
                          const Padding(
                            padding: EdgeInsets.only(top: 6),
                            child: LinearProgressIndicator(minHeight: 2),
                          ),
                        ],
                        if (swapsInStock.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          _swapHeader(
                            context.tr(
                              'Нет на складе — можно заменить',
                              'Not in stock — can be replaced by',
                            ),
                          ),
                          ...swapsInStock.map(
                            (item) => _warehouseRow(
                              item: item,
                              selected: picked?.id == item.id,
                              swapNote: swapNoteFor(item),
                              byAi: aiWhy.containsKey(item.id),
                              onTap: () => choose(item, remember: raw),
                            ),
                          ),
                        ],
                        if (swapsToOrder.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          _swapHeader(
                            context.tr(
                              'Подойдёт, но тоже кончилось — заказать',
                              'Would fit, also out of stock — order it',
                            ),
                            color: const Color(0xFFB3261E),
                          ),
                          ...swapsToOrder.map(
                            (item) => _warehouseRow(
                              item: item,
                              selected: picked?.id == item.id,
                              swapNote: swapNoteFor(item),
                              byAi: aiWhy.containsKey(item.id),
                              outOfStock: true,
                              onTap: () => choose(item, remember: raw),
                            ),
                          ),
                        ],
                        if (!aiBusy && saved.isEmpty && fromAi.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              context.tr(
                                'Замены не нашёл.',
                                'No substitute found.',
                              ),
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.black45,
                              ),
                            ),
                          ),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: priceCtrl,
                              keyboardType: TextInputType.number,
                              onTap: () {
                                if (!priceFresh) return;
                                priceFresh = false;
                                clearAutoNumber(priceCtrl);
                              },
                              onChanged: (_) {
                                priceFresh = false;
                                setDialog(() {});
                              },
                              decoration: InputDecoration(
                                labelText: context.tr(
                                  'Цена для клиента',
                                  'Price for client',
                                ),
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
                              onTap: () {
                                if (!qtyFresh) return;
                                qtyFresh = false;
                                clearAutoNumber(qtyCtrl);
                              },
                              onChanged: (_) {
                                qtyFresh = false;
                                setDialog(() {});
                              },
                              decoration: const InputDecoration(
                                labelText: 'Qty',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _itemKindField(
                        isPart: isPart,
                        costCtrl: costCtrl,
                        clientUnitPrice: double.tryParse(priceCtrl.text) ?? 0,
                        qty: (int.tryParse(qtyCtrl.text) ?? 1).toDouble(),
                        fromWarehouse: picked != null,
                        onChanged: (next) {
                          kindTouched = true;
                          setDialog(() => isPart = next);
                        },
                        onCostChanged: () => setDialog(() {}),
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
                      final cost = double.tryParse(
                        costCtrl.text.trim().replaceAll(',', '.'),
                      );
                      created = {
                        'name': nameCtrl.text.trim(),
                        'price': double.tryParse(priceCtrl.text) ?? 0,
                        'qty': int.tryParse(qtyCtrl.text) ?? 1,
                        'type': isPart ? 'Part' : 'Service',
                        if (selected != null) 'warehouseItemId': selected.id,
                        if (isPart && cost != null)
                          'costPrice': cost
                        else if (isPart && selected?.costPrice != null)
                          'costPrice': selected!.costPrice,
                      };
                      Navigator.pop(dialogContext);
                    },
                    child: const Text('Add'),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
    aiDebounce?.cancel();
    return created;
  }

  /// Переключатель «Работа / Запчасть» и себестоимость под ним.
  ///
  /// Без этой метки отчёт делил позиции на глаз — по складу и себестоимости,
  /// и «control board for a washing machine» за $300 уезжал в работу.
  /// Себестоимость спрашиваем только у запчасти: без неё отчёт берёт 40%
  /// цены и честно помечает цифру как прикидку.
  Widget _itemKindField({
    required bool isPart,
    required TextEditingController costCtrl,
    required ValueChanged<bool> onChanged,
    VoidCallback? onCostChanged,
    double clientUnitPrice = 0,
    double qty = 1,
    bool fromWarehouse = false,
  }) {
    final typedCost = double.tryParse(
      costCtrl.text.trim().replaceAll(',', '.'),
    );
    final effectiveUnitCost = !isPart
        ? 0.0
        : (typedCost ?? (clientUnitPrice * 0.4));
    final totalClient = qty * clientUnitPrice;
    final totalMyCost = qty * effectiveUnitCost;
    final margin = totalClient - totalMyCost;
    final isGuess = isPart && typedCost == null && clientUnitPrice > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: false,
                icon: const Icon(Icons.handyman_outlined, size: 18),
                label: Text(context.tr('Работа', 'Service')),
              ),
              ButtonSegment(
                value: true,
                icon: const Icon(Icons.settings_outlined, size: 18),
                label: Text(context.tr('Запчасть', 'Part')),
              ),
            ],
            selected: {isPart},
            onSelectionChanged: fromWarehouse
                ? null
                : (next) => onChanged(next.first),
          ),
        ),
        if (isPart) ...[
          const SizedBox(height: 10),
          TextField(
            controller: costCtrl,
            onChanged: (_) => onCostChanged?.call(),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: context.tr(
                'Закупка за 1 шт. (сколько стоило мне)',
                'My purchase cost per unit',
              ),
              prefixText: '\$ ',
              helperMaxLines: 3,
              helperText: fromWarehouse
                  ? context.tr(
                      'Подставлено со склада — при необходимости можно поправить.',
                      'Filled from the warehouse — you can adjust it if needed.',
                    )
                  : context.tr(
                      'Впишите вашу закупочную цену. Если оставить пустым — отчёт возьмёт 40% цены как прикидку.',
                      'Enter your purchase cost. If left empty, reports use 40% of price as a guess.',
                    ),
              border: const OutlineInputBorder(),
            ),
          ),
          if (clientUnitPrice > 0 || typedCost != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.cardMuted,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${context.tr('Для клиента', 'For client')}: \$${totalClient.toStringAsFixed(2)} · '
                    '${context.tr('Для меня', 'My cost')}: \$${totalMyCost.toStringAsFixed(2)}'
                    '${isGuess ? context.tr(' (прикидка 40%)', ' (40% guess)') : ''}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${context.tr('Чистыми с детали (наценка)', 'Net on part (margin)')}: '
                    '${margin >= 0 ? '+' : '−'}\$${margin.abs().toStringAsFixed(2)}',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: margin >= 0
                          ? const Color(0xFF2E7D32)
                          : const Color(0xFFC62828),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ],
    );
  }

  /// Правка уже добавленной позиции: имя, цена, количество, работа/запчасть.
  ///
  /// Связь со складом (`warehouseItemId`) не трогаем: деталь физически та же.
  /// Цена и количество выделяются на первый тап — обычно их перебивают
  /// целиком. [kindOnly] — счёт уже оплачен: деньги не меняем, но пометить
  /// позицию работой или запчастью можно, на сумму это не влияет.
  Future<Map<String, dynamic>?> _showEditItemDialog(
    Map<String, dynamic> item, {
    bool kindOnly = false,
  }) async {
    final nameCtrl = TextEditingController(
      text: (item['name'] ?? '').toString(),
    );
    final priceCtrl = TextEditingController(
      text: _money(item['price']).toStringAsFixed(2),
    );
    final qtyCtrl = TextEditingController(
      text: '${_money(item['qty'], 1).toInt()}',
    );
    final warehouseId = (item['warehouseItemId'] ?? '').toString();
    final fromWarehouse = warehouseId.isNotEmpty;
    final initialCost = item['costPrice'] != null
        ? _money(item['costPrice'])
        : (fromWarehouse ? WarehouseService.latestCosts[warehouseId] : null);
    final costCtrl = TextEditingController(
      text: initialCost == null ? '' : initialCost.toStringAsFixed(2),
    );
    var isPart = Job.isPartItem(item);
    var priceFresh = true;
    var qtyFresh = true;

    final edited = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) {
        return DisposeOnClose(
          disposables: [nameCtrl, priceCtrl, qtyCtrl, costCtrl],
          child: StatefulBuilder(
            builder: (context, setDialog) => AlertDialog(
              title: Text(
                kindOnly
                    ? context.tr('Работа или запчасть', 'Service or part')
                    : 'Edit item',
              ),
              scrollable: true,
              content: SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (kindOnly) ...[
                      Text(
                        (item['name'] ?? 'Item').toString(),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        context.tr(
                          'Счёт оплачен, поэтому имя, цену и количество менять нельзя. Метка и закупочная цена на сумму для клиента не влияют — они нужны отчётам.',
                          'The invoice is paid, so name, price and qty are locked. Label and purchase cost do not change the client total — reports use them.',
                        ),
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.inkMuted,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ] else ...[
                      TextField(
                        controller: nameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Name',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: priceCtrl,
                              keyboardType: TextInputType.number,
                              onTap: () {
                                if (!priceFresh) return;
                                priceFresh = false;
                                clearAutoNumber(priceCtrl);
                              },
                              onChanged: (_) => setDialog(() {}),
                              decoration: InputDecoration(
                                labelText: context.tr(
                                  'Цена для клиента',
                                  'Price for client',
                                ),
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
                              onTap: () {
                                if (!qtyFresh) return;
                                qtyFresh = false;
                                clearAutoNumber(qtyCtrl);
                              },
                              onChanged: (_) => setDialog(() {}),
                              decoration: const InputDecoration(
                                labelText: 'Qty',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                    ],
                    _itemKindField(
                      isPart: isPart,
                      costCtrl: costCtrl,
                      clientUnitPrice: double.tryParse(priceCtrl.text) ?? 0,
                      qty: (int.tryParse(qtyCtrl.text) ?? 1).toDouble(),
                      fromWarehouse: fromWarehouse,
                      onChanged: (next) => setDialog(() => isPart = next),
                      onCostChanged: () => setDialog(() {}),
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
                    final name = nameCtrl.text.trim();
                    if (name.isEmpty) return;
                    final cost = double.tryParse(
                      costCtrl.text.trim().replaceAll(',', '.'),
                    );
                    final next = {
                      ...item,
                      'type': isPart ? 'Part' : 'Service',
                    };
                    if (!kindOnly) {
                      next['name'] = name;
                      next['price'] = double.tryParse(priceCtrl.text) ?? 0;
                      next['qty'] = int.tryParse(qtyCtrl.text) ?? 1;
                    }
                    if (isPart && cost != null) {
                      next['costPrice'] = cost;
                    } else if (!isPart) {
                      // Работе себестоимость не нужна: иначе она утянет
                      // позицию обратно в запчасти при следующем чтении.
                      next.remove('costPrice');
                    }
                    Navigator.pop(dialogContext, next);
                  },
                  child: Text('Сохранить'.tr),
                ),
              ],
            ),
          ),
        );
      },
    );
    return edited;
  }

  Future<void> _editBuilderItem(int index) async {
    if (index < 0 || index >= ctrl.builderItems.length) return;
    final edited = await _showEditItemDialog(ctrl.builderItems[index]);
    if (edited == null || !mounted) return;
    if (index >= ctrl.builderItems.length) return;
    setState(() => ctrl.builderItems[index] = edited);
    ctrl.notifyBuilderChanged();
  }

  /// Позицию уже сохранённого документа правим на месте. Склад доводим до
  /// нового состава: иначе списанное количество разойдётся со счётом.
  ///
  /// [kindOnly] — счёт оплачен: меняется только метка «работа / запчасть» и
  /// себестоимость. Сумма та же, поэтому склад не трогаем.
  Future<void> _editDocumentItem(
    int docIndex,
    int itemIndex, {
    bool kindOnly = false,
  }) async {
    if (_busy) return;
    if (docIndex < 0 || docIndex >= ctrl.documents.length) return;
    final doc = Map<String, dynamic>.from(ctrl.documents[docIndex]);
    final items = [
      for (final item in doc['items'] as List? ?? [])
        if (item is Map) Map<String, dynamic>.from(item),
    ];
    if (itemIndex < 0 || itemIndex >= items.length) return;
    final edited = await _showEditItemDialog(
      items[itemIndex],
      kindOnly: kindOnly,
    );
    if (edited == null || !mounted) return;
    final nextItems = [...items];
    nextItems[itemIndex] = edited;
    final refreshed = _coveredIfPlan(LabourDiscount.refresh(nextItems));

    setState(() => _busy = true);
    try {
      if (!kindOnly) {
        await WarehouseService.applyDocumentStockChange(
          {...doc, 'items': items},
          {...doc, 'items': refreshed},
        );
      }
      await ctrl.updateDocument(docIndex, {...doc, 'items': refreshed});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

    final docIndex = ctrl.viewingDocumentIndex!;
    final doc = ctrl.documents[docIndex];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _maybeAutoCheckStripe(docIndex);
    });
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
    final stamp = Formatters.messageStamp(Job.documentCreatedAt(doc));

    final subtotal = ctrl.calcSubtotal(items);
    final taxRate = _money(doc['taxRate'], 0.0);
    final tax = ctrl.calcTax(subtotal, taxRate);
    final total = ctrl.calcTotal(subtotal, tax);
    final paid = ctrl.calcPaid(payments);
    final due = ctrl.calcDue(total, paid);

    // Деньги уже прошли — состав счёта трогать нельзя: сумма разойдётся с
    // оплатой и с тем, что лежит у клиента на руках. То же со сметой, из
    // которой уже сделан счёт: правка не доедет до него.
    final itemsEditable =
        !isCancelled && payments.isEmpty && !_estimateConverted(doc);

    final docTitle =
        '${isEstimate ? 'ESTIMATE' : 'INVOICE'} #${doc['number'] ?? (docIndex + 1)}';

    return ColoredBox(
      color: AppColors.surface,
      child: Column(
        children: [
          Material(
            color: AppColors.primary,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
              child: Row(
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(
                      Icons.arrow_back_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                    onPressed: () => ctrl.setFinanceMode('main'),
                  ),
                  Expanded(
                    child: Text(
                      docTitle,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 15.5,
                      ),
                    ),
                  ),
                  Text(
                    Formatters.formatCurrency(total),
                    style: const TextStyle(
                      color: Color(0xFFFCC520),
                      fontWeight: FontWeight.w900,
                      fontSize: 17,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_busy) const LinearProgressIndicator(minHeight: 3),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isEstimate) ...[
                    _EstimateStatusBanner(
                      doc: doc,
                      busy: _busy,
                      onConvertToInvoice: !isCancelled &&
                              !_estimateConverted(doc)
                          ? () => _convertEstimateToInvoice(docIndex)
                          : null,
                    ),
                    const SizedBox(height: 10),
                  ],
                  // Мини-А4 лист открытого документа
                  Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.border),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.06),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          height: 4,
                          color: isEstimate
                              ? Colors.orange.shade700
                              : AppColors.primary,
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          docTitle,
                                          style: TextStyle(
                                            fontWeight: FontWeight.w900,
                                            fontSize: 15,
                                            letterSpacing: 0.4,
                                            color: AppColors.ink,
                                          ),
                                        ),
                                        if (stamp.isNotEmpty)
                                          Text(
                                            stamp,
                                            style: TextStyle(
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w600,
                                              color: AppColors.inkMuted,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  Text(
                                    Formatters.formatCurrency(total),
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 20,
                                      color: AppColors.primaryOnCard,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              _buildBillToSelector(
                                currentBillTo: _docBillTo(doc),
                                onChanged: _busy || isCancelled
                                    ? null
                                    : (next) => _changeSavedDocBillTo(
                                          docIndex,
                                          next,
                                        ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                itemsEditable
                                    ? context.tr(
                                        'Нажмите на строку для правки',
                                        'Tap a line to edit',
                                      )
                                    : isCancelled
                                        ? _itemsLockedReason(
                                            context,
                                            cancelled: true,
                                            paid: false,
                                          )
                                        : context.tr(
                                            'Нажмите на строку, чтобы отметить работу / запчасть',
                                            'Tap a line to mark service or part',
                                          ),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppColors.inkMuted,
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 6),
                                child: Divider(
                                  height: 1,
                                  thickness: 1,
                                  color: AppColors.border,
                                ),
                              ),
                              for (final entry in items.asMap().entries)
                                InkWell(
                                  borderRadius: BorderRadius.circular(6),
                                  onTap: _busy || isCancelled
                                      ? null
                                      : () => _editDocumentItem(
                                            docIndex,
                                            entry.key,
                                            kindOnly: !itemsEditable,
                                          ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 5,
                                      horizontal: 2,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                (entry.value['name'] ?? 'Item')
                                                    .toString(),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 13.5,
                                                  fontWeight: FontWeight.w700,
                                                  color: AppColors.ink,
                                                ),
                                              ),
                                              const SizedBox(height: 1),
                                              _buildItemSubtitle(entry.value),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          '\$${(_money(entry.value['qty'], 1) * _money(entry.value['price'])).toStringAsFixed(2)}',
                                          style: TextStyle(
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.w800,
                                            color: AppColors.ink,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 6),
                                child: Divider(
                                  height: 1,
                                  thickness: 1,
                                  color: AppColors.border,
                                ),
                              ),
                              if (itemsEditable)
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Wrap(
                                    spacing: 4,
                                    children: [
                                      TextButton.icon(
                                        onPressed: _busy
                                            ? null
                                            : () => _addDocumentItem(docIndex),
                                        icon: const Icon(
                                          Icons.add_rounded,
                                          size: 18,
                                        ),
                                        label: Text(
                                          context.tr('Позиция', 'Add item'),
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      TextButton.icon(
                                        onPressed: _busy
                                            ? null
                                            : () => _discountSavedDocument(
                                                  docIndex,
                                                ),
                                        icon: const Icon(
                                          Icons.percent,
                                          size: 18,
                                        ),
                                        label: Text(
                                          _discountLabel(items),
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              _buildTotalRow('Subtotal', subtotal),
                              _buildTotalRow(
                                'Tax (${(taxRate * 100).round()}%)',
                                tax,
                              ),
                              const Divider(height: 10),
                              _buildTotalRow('Total', total, isBold: true),
                              if (paid > 0)
                                _buildTotalRow(
                                  'Paid',
                                  paid,
                                  color: Colors.green.shade700,
                                ),
                              if (due > 0)
                                _buildTotalRow(
                                  'Amount due',
                                  due,
                                  color: Colors.red.shade700,
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  if (payments.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Payments',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    const SizedBox(height: 6),
                    ...payments.map((p) {
                      final amount = (p['amount'] ?? 0).toDouble();
                      final method = (p['method'] ?? 'Payment').toString();
                      final isRefund = amount < -0.009 ||
                          method.toLowerCase().contains('refund') ||
                          method.toLowerCase().contains('возврат');
                      return Card(
                        margin: const EdgeInsets.only(bottom: 6),
                        child: ListTile(
                          dense: true,
                          leading: Icon(
                            isRefund
                                ? Icons.undo
                                : method.toString().contains('Stripe')
                                    ? Icons.credit_card
                                    : Icons.payments,
                            color: isRefund ? Colors.red : Colors.green,
                            size: 20,
                          ),
                          title: Text(
                            Formatters.formatCurrency(amount.abs()),
                            style: TextStyle(
                              color: isRefund ? Colors.red.shade700 : null,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          subtitle: Builder(
                            builder: (context) {
                              final dateRaw = p['date']?.toString();
                              String dateStr = '';
                              if (dateRaw != null && dateRaw.isNotEmpty) {
                                final dt = DateTime.tryParse(dateRaw);
                                if (dt != null) {
                                  dateStr = DateFormat(
                                    'd MMM yyyy, HH:mm',
                                    AppLocale.instance.dateLocale,
                                  ).format(dt.toLocal());
                                }
                              }
                              final methodLabel = isRefund &&
                                      !method.toLowerCase().contains('refund')
                                  ? 'Refund: ${_paymentMethodEn(method)}'
                                  : _paymentMethodEn(method);
                              final subtitleText = dateStr.isNotEmpty
                                  ? '$methodLabel • $dateStr'
                                  : methodLabel;
                              return Text(
                                subtitleText,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isRefund ? Colors.red.shade600 : null,
                                ),
                              );
                            },
                          ),
                        ),
                      );
                    }),
                  ],

                  if (_signatureUrl(doc).isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Client signature',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Image.network(
                            _signatureUrl(doc),
                            height: 72,
                            fit: BoxFit.contain,
                            alignment: Alignment.centerLeft,
                            cacheHeight: 216,
                            errorBuilder: (context, error, stackTrace) =>
                                const Text('Signature saved'),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Printed on the invoice PDF',
                            style: TextStyle(
                              color: Colors.grey.shade700,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  if (_stripeUrl(doc).isNotEmpty || _isStripeRefunded(doc)) ...[
                    const SizedBox(height: 12),
                    _buildStripeStatusCard(doc, due),
                  ],

                  if (!isCancelled) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        if (!isEstimate && due > 0)
                          Expanded(
                            child: SizedBox(
                              height: 42,
                              child: ElevatedButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () => _showPaySheet(
                                          documentIndex: docIndex,
                                          total: total,
                                          due: due,
                                        ),
                                icon: const Icon(Icons.payments, size: 19),
                                label: Text(
                                  'Выбор оплаты'.tr,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.accent,
                                  foregroundColor: Colors.black,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (!isEstimate && due > 0 && (isEstimate || due <= 0))
                          const SizedBox(width: 8),
                        if (isEstimate || due <= 0)
                          Expanded(
                            child: SizedBox(
                              height: 42,
                              child: ElevatedButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () => _sendAppDocument(docIndex),
                                icon: const Icon(Icons.send, size: 18),
                                label: Text(
                                  'Отправить'.tr,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF14557F),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (!isEstimate && paid > 0.009) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        height: 38,
                        child: OutlinedButton.icon(
                          onPressed: _busy
                              ? null
                              : () => _confirmRefund(
                                    documentIndex: docIndex,
                                    maxAmount: paid,
                                  ),
                          icon: const Icon(Icons.undo, size: 18),
                          label: Text('Вернуть средства'.tr),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red.shade700,
                            side: BorderSide(color: Colors.red.shade300),
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

  Job _currentJob() {
    return Job.fromMap(
      {
        ...ctrl.jobData,
        'documents': ctrl.documents,
      },
      ctrl.jobId,
    );
  }

  Widget _buildJobFinanceSummaryCard() {
    final job = _currentJob();
    final summary = ReportMetrics.jobOf(
      job,
      warehouseCosts: WarehouseService.latestCosts,
    );
    if (summary.invoices.isEmpty) return const SizedBox.shrink();
    String m(double v) => ReportBreakdownPage.money(v);

    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF14557F),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: () => _openJobBreakdownPage(summary),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.savings_outlined,
                      color: Color(0xFFFCC520),
                      size: 17,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        context.tr(
                          'Итого по этой заявке',
                          'Total on this job',
                        ),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                    Text(
                      '${context.tr('Чистыми', 'Net')}: ${m(summary.netProfit)}',
                      style: const TextStyle(
                        color: Color(0xFFFCC520),
                        fontSize: 14.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.chevron_right,
                      color: Colors.white70,
                      size: 18,
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    '${context.tr('Счёт', 'Total')}: ${m(summary.invoiced)} (${context.tr('без HST', 'ex HST')} ${m(summary.salesExHst)})',
                    if (summary.parts.isNotEmpty)
                      '${context.tr('Запчасти', 'Parts')}: ${context.tr('мне', 'cost')} ${m(summary.partsCost)} / ${context.tr('клиенту', 'client')} ${m(summary.partsSales)}',
                  ].join('  ·  '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openJobBreakdownPage(ReportJob summary) {
    String m(double v) => ReportBreakdownPage.money(v);
    ReportBreakdownPage.open(
      context,
      title: summary.job.clientName.trim().isEmpty
          ? context.tr('Экономика заявки', 'Job economics')
          : summary.job.clientName,
      periodLabel: summary.job.applianceType,
      headline: m(summary.netProfit),
      headlineLabel: context.tr(
        'чистыми заработано по заявке',
        'net earned on this job',
      ),
      headlineHint:
          '${context.tr('Грязными без HST', 'Gross excl. HST')}: ${m(summary.salesExHst)} (${context.tr('с HST', 'incl. HST')} ${m(summary.invoiced)}) · ${context.tr('Запчасти мне', 'Parts my cost')}: ${m(summary.partsCost)} · ${context.tr('Запчасти клиенту', 'Parts client')}: ${m(summary.partsSales)}',
      color: const Color(0xFF14557F),
      icon: Icons.savings_outlined,
      formula: [
        (
          context.tr('Грязными (счета с HST)', 'Gross (invoices incl. HST)'),
          m(summary.invoiced),
        ),
        ('− HST', m(-summary.tax)),
        (
          '= ${context.tr('Грязными без HST (выручка)', 'Gross excl. HST (revenue)')}',
          m(summary.salesExHst),
        ),
        (
          context.tr('Работа и выезд', 'Labour and call-out'),
          m(summary.labourSales),
        ),
        (
          context.tr('Запчасти — стоит для клиента', 'Parts — client price'),
          m(summary.partsSales),
        ),
        (
          '− ${context.tr('Запчасти — стоило для меня', 'Parts — my cost')}',
          m(-summary.partsCost),
        ),
        (
          context.tr('Наценка на запчастях', 'Parts margin'),
          m(summary.partsMargin),
        ),
        (
          '= ${context.tr('Чистыми по заявке', 'Net on this job')}',
          m(summary.netProfit),
        ),
      ],
      sections: [
        BreakdownSection(
          title:
              '${context.tr('Инвойсы заявки', 'Job invoices')} (${summary.invoices.length})',
          rows: [
            for (final inv in summary.invoices)
              BreakdownRow(
                title:
                    'Invoice #${inv.number.isEmpty ? '${inv.docIndex + 1}' : inv.number}',
                amount: inv.netProfit,
                amountLabel: context.tr('чистыми', 'net'),
                chips: [
                  '${context.tr('Грязными без HST', 'Gross excl. HST')} ${m(inv.subtotal)}',
                  '${context.tr('С HST', 'Incl. HST')} ${m(inv.total)}',
                  '${context.tr('Запчасти мне', 'Parts my cost')} ${m(inv.partsCost)}',
                  '${context.tr('Запчасти клиенту', 'Parts client')} ${m(inv.partsSales)}',
                ],
                onTap: () {
                  Navigator.pop(context);
                  ctrl.setViewingDocumentIndex(inv.docIndex);
                  ctrl.setFinanceMode('view_document');
                },
              ),
          ],
        ),
        BreakdownSection(
          title:
              '${context.tr('Каждая деталь в заявке', 'Every part on the job')} (${summary.parts.length})',
          empty: context.tr('Запчастей нет.', 'No parts.'),
          total: summary.parts.isEmpty ? null : summary.partsCost,
          totalLabel: context.tr(
            'Стоило для меня (закупка)',
            'Total cost to me',
          ),
          rows: [
            for (final item in summary.parts)
              BreakdownRow(
                title: item.name,
                subtitle: item.invoiceNumber.isEmpty
                    ? ''
                    : 'Invoice #${item.invoiceNumber}',
                amount: item.cost,
                amountLabel: context.tr('для меня', 'my cost'),
                chips: [
                  '${context.tr('Для меня', 'My cost')}: ${m(item.cost)}',
                  '${context.tr('Для клиента', 'For client')}: ${m(item.sold)}',
                  '${context.tr('Чистыми с детали', 'Net on part')}: +${m(item.margin)}',
                ],
                onTap: () {
                  Navigator.pop(context);
                  ctrl.setViewingDocumentIndex(item.docIndex);
                  ctrl.setFinanceMode('view_document');
                },
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildItemSubtitle(Map item) {
    final parsed = ReportMetrics.itemOf(
      item,
      warehouseCosts: WarehouseService.latestCosts,
    );
    final qty = _formatQty(parsed.qty);
    return Row(
      children: [
        Text(
          '$qty × \$${parsed.price.toStringAsFixed(2)}',
          style: const TextStyle(fontSize: 11.5, color: Colors.black54),
        ),
        const SizedBox(width: 6),
        _itemKindChip(
          isPart: parsed.isPart,
          classified: parsed.classified,
        ),
      ],
    );
  }

  /// Плашка у позиции счёта. Серая с вопросом — метки нет, отчёт гадает.
  Widget _itemKindChip({required bool isPart, required bool classified}) {
    final color = !classified
        ? const Color(0xFF9E9E9E)
        : isPart
            ? const Color(0xFF3949AB)
            : const Color(0xFF00897B);
    final text = isPart
        ? context.tr('Запчасть', 'Part')
        : context.tr('Работа', 'Service');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        classified ? text : '$text?',
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  String _itemsLockedReason(
    BuildContext context, {
    required bool cancelled,
    required bool paid,
  }) {
    if (cancelled) {
      return context.tr('Документ отменён — позиции не меняются',
          'Cancelled — line items are locked');
    }
    if (paid) {
      return context.tr('Оплата прошла — позиции не меняются',
          'Paid — line items are locked');
    }
    return context.tr('Из сметы уже сделан счёт — позиции не меняются',
        'Converted to an invoice — line items are locked');
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

  String _paymentMethodEn(String method) {
    final m = method.trim();
    final lower = m.toLowerCase();
    if (lower == 'наличные' || lower == 'cash') return 'Cash';
    if (lower.contains('чаевые') || lower == 'tip') return 'Tip';
    if (lower.contains('возврат (наличные)') || lower.contains('refund (cash)')) {
      return 'Refund (cash)';
    }
    if (lower.contains('возврат') && !lower.contains('stripe')) return 'Refund';
    if (lower.contains('stripe (refund)')) return 'Stripe (refund)';
    if (lower.contains('stripe (deposit)')) return 'Stripe (deposit)';
    if (lower.contains('stripe (card present)')) return 'Stripe (card present)';
    if (lower.contains('stripe')) return m.contains('Stripe') ? m : 'Stripe';
    if (lower == 'оплата' || lower == 'payment') return 'Payment';
    return m;
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

  bool _isStripeRefunded(Map doc) {
    final stripe = doc['stripe'];
    if (stripe is! Map) return false;
    final status = (stripe['status'] ?? '').toString();
    return status == 'refunded' || status == 'partially_refunded';
  }

  bool _isRefundedDoc(Map doc) {
    if (_isStripeRefunded(doc)) return true;
    final payments = doc['payments'];
    if (payments is! List) return false;
    return payments.any((p) {
      if (p is! Map) return false;
      final amount = _money(p['amount']);
      final method = (p['method'] ?? '').toString().toLowerCase();
      return amount < -0.009 ||
          method.contains('refund') ||
          method.contains('возврат');
    });
  }

  Future<void> _confirmRefund({
    required int documentIndex,
    required double maxAmount,
  }) async {
    if (documentIndex < 0 || documentIndex >= ctrl.documents.length) return;
    if (maxAmount <= 0.009) return;

    final amountCtrl = TextEditingController(
      text: maxAmount.toStringAsFixed(2),
    );
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (context) {
        return DisposeOnClose(
          disposables: [amountCtrl],
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppColors.border,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Вернуть средства?'.tr,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primaryOnCard,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Stripe вернёт деньги на карту. Наличные отметьте сами из кассы. Полный возврат переведёт работу в «Отмена».'
                          .tr,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.inkMuted,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: amountCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: 'Сумма возврата'.tr,
                        border: const OutlineInputBorder(),
                        suffixText: 'CAD',
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '${'Максимум'.tr}: ${Formatters.formatCurrency(maxAmount)}',
                        style: TextStyle(
                          color: AppColors.inkMuted,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: Text('Отмена'.tr),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () => Navigator.pop(context, true),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red.shade600,
                              foregroundColor: Colors.white,
                            ),
                            child: Text('Вернуть'.tr),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    final raw = amountCtrl.text.trim().replaceAll(',', '.');
    if (confirmed != true) return;

    final amount = double.tryParse(raw) ?? 0;
    if (amount <= 0.009) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Укажите сумму возврата'.tr)),
      );
      return;
    }
    if (amount > maxAmount + 0.009) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Сумма больше оплаченного'.tr)),
      );
      return;
    }

    setState(() => _busy = true);
    try {
      final result = await StripeService.refundPayment(
        jobId: ctrl.jobId,
        documentIndex: documentIndex,
        amount: amount,
      );
      if (!mounted) return;
      if (result.jobCancelled ||
          JobStatuses.isCancelledStatus(result.jobStatus)) {
        ctrl.currentStatus = JobStatuses.cancelled;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.jobCancelled
                ? 'Возврат выполнен. Работа отменена.'.tr
                : '${'Возврат'.tr}: ${Formatters.formatCurrency(result.refunded)}',
          ),
        ),
      );
      ctrl.openFinanceMainList();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _buildStripeStatusCard(Map<String, dynamic> doc, double due) {
    final stripe = Map<String, dynamic>.from(doc['stripe'] as Map);
    final status = (stripe['status'] ?? '').toString();
    final paid = status == 'paid';
    final refunded = status == 'refunded' || status == 'partially_refunded';
    final expired = status == 'expired';
    final url = _stripeUrl(doc);
    final paidDate = _extractStripePaidDate(doc, stripe);
    final createdDate = _extractStripeCreatedDate(stripe);
    final refundDate = _extractStripeRefundDate(doc, stripe);

    final Color bg;
    final Color border;
    final IconData statusIcon;
    final Color iconColor;
    if (refunded) {
      bg = Colors.red.shade50;
      border = Colors.red.shade200;
      statusIcon = Icons.undo;
      iconColor = Colors.red.shade700;
    } else if (paid) {
      bg = Colors.green.shade50;
      border = Colors.green.shade200;
      statusIcon = Icons.check_circle;
      iconColor = Colors.green.shade700;
    } else if (expired) {
      bg = Colors.orange.shade50;
      border = Colors.orange.shade200;
      statusIcon = Icons.timer_off_outlined;
      iconColor = Colors.orange.shade800;
    } else {
      bg = Colors.blue.shade50;
      border = Colors.blue.shade200;
      statusIcon = Icons.hourglass_top;
      iconColor = const Color(0xFF14557F);
    }

    final title = status == 'refunded'
        ? 'Возврат через Stripe'.tr
        : status == 'partially_refunded'
            ? 'Частичный возврат Stripe'.tr
            : paid
                ? 'Оплачено через Stripe'.tr
                : expired
                    ? 'Срок ссылки истёк'.tr
                    : 'Ссылка Stripe ожидает оплаты'.tr;

    final docIndex = ctrl.viewingDocumentIndex ?? 0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(statusIcon, color: iconColor, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: iconColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (stripe['amount'] != null) ...[
            Text('${'Сумма'.tr}: ${Formatters.formatCurrency((stripe['amount'] as num).toDouble())}'),
            const SizedBox(height: 4),
          ],
          if (paid && paidDate != null) ...[
            Row(
              children: [
                Icon(Icons.access_time, size: 14, color: Colors.green.shade800),
                const SizedBox(width: 4),
                Text(
                  '${'Оплата прошла'.tr}: ${DateFormat('d MMMM yyyy, HH:mm', AppLocale.instance.dateLocale).format(paidDate)}',
                  style: TextStyle(
                    color: Colors.green.shade900,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
          ],
          if (!paid && createdDate != null) ...[
            Row(
              children: [
                Icon(Icons.access_time, size: 14, color: Colors.grey.shade700),
                const SizedBox(width: 4),
                Text(
                  '${'Ссылка отправлена'.tr}: ${DateFormat('d MMMM yyyy, HH:mm', AppLocale.instance.dateLocale).format(createdDate)}',
                  style: TextStyle(color: Colors.grey.shade800, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 4),
          ],
          if (refunded && refundDate != null) ...[
            Row(
              children: [
                Icon(Icons.access_time, size: 14, color: Colors.red.shade700),
                const SizedBox(width: 4),
                Text(
                  '${'Дата возврата'.tr}: ${DateFormat('d MMMM yyyy, HH:mm', AppLocale.instance.dateLocale).format(refundDate)}',
                  style: TextStyle(color: Colors.red.shade900, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 4),
          ],
          if (stripe['lastRefundAmount'] != null) ...[
            Text(
              '${'Возвращено'.tr}: ${Formatters.formatCurrency((stripe['lastRefundAmount'] as num).toDouble())}',
              style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
          ],
          if (!paid && !refunded) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton.icon(
                  onPressed: (_busy || _checkingStripe)
                      ? null
                      : () => _checkStripePayment(docIndex),
                  icon: _checkingStripe
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.sync, size: 18),
                  label: Text('Проверить оплату'.tr),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF14557F),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
                if (url.isNotEmpty) ...[
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

  static String _docBillTo(Map<String, dynamic> doc) {
    final raw = (doc['billTo'] ?? '').toString().trim().toLowerCase();
    return raw == 'tenant' ? 'tenant' : 'owner';
  }

  ({
    String billTo,
    String name,
    String phone,
    String email,
    String address,
    String company,
  }) _recipientForBillTo(String billTo, {Map<String, dynamic>? doc}) {
    final isTenant = billTo.trim().toLowerCase() == 'tenant';
    final ownerName = Client.stripClientWord(
      (ctrl.jobData['clientName'] ?? '').toString(),
    ).trim();
    final ownerPhone = (ctrl.jobData['clientPhone'] ?? '').toString().trim();
    final ownerEmail = ctrl.clientEmail.trim();
    final ownerAddress = (ctrl.jobData['clientAddress'] ?? '').toString().trim();
    final ownerCompany = (ctrl.jobData['companyName'] ?? '').toString().trim();

    if (!isTenant) {
      final savedName = doc != null && _docBillTo(doc) == 'owner'
          ? (doc['billToName'] ?? '').toString().trim()
          : '';
      return (
        billTo: 'owner',
        name: ownerName.isNotEmpty
            ? ownerName
            : (savedName.isNotEmpty ? savedName : ctrl.contactName),
        phone: ownerPhone.isNotEmpty ? ownerPhone : ctrl.contactPhone.trim(),
        email: ownerEmail,
        address: ownerAddress.isNotEmpty ? ownerAddress : ctrl.workAddress.trim(),
        company: ownerCompany,
      );
    }

    var tenantName = ctrl.effectiveJobSiteName.trim();
    var tenantPhone = ctrl.effectiveJobSitePhone.trim();
    var tenantEmail = ctrl.jobSiteEmail.trim();
    final tenantAddress = ctrl.jobSiteAddress.trim().isNotEmpty
        ? ctrl.jobSiteAddress.trim()
        : ctrl.workAddress.trim();

    for (final c in ctrl.chatContacts) {
      if (!c.isOwner) {
        if (tenantName.isEmpty &&
            c.name.trim().isNotEmpty &&
            !Client.isPlaceholderName(c.name)) {
          tenantName = c.name.trim();
        }
        if (tenantPhone.isEmpty && c.hasPhone) {
          tenantPhone = c.phone.trim();
        }
        if (tenantEmail.isEmpty && c.hasEmail) {
          tenantEmail = c.email.trim();
        }
      }
    }
    if (doc != null && _docBillTo(doc) == 'tenant') {
      if (tenantName.isEmpty) {
        tenantName = (doc['billToName'] ?? '').toString().trim();
      }
      if (tenantPhone.isEmpty) {
        tenantPhone = (doc['billToPhone'] ?? '').toString().trim();
      }
      if (tenantEmail.isEmpty) {
        tenantEmail = (doc['billToEmail'] ?? '').toString().trim();
      }
    }
    if (tenantName.isEmpty) {
      tenantName = 'Арендатор'.tr;
    }
    if (tenantPhone.isEmpty) {
      tenantPhone = ctrl.contactPhone.trim();
    }

    return (
      billTo: 'tenant',
      name: tenantName,
      phone: tenantPhone,
      email: tenantEmail,
      address: tenantAddress,
      company: '',
    );
  }

  Future<void> _changeSavedDocBillTo(int docIndex, String nextBillTo) async {
    if (_busy || docIndex < 0 || docIndex >= ctrl.documents.length) return;
    final current = Map<String, dynamic>.from(ctrl.documents[docIndex]);
    if (_docBillTo(current) == nextBillTo) return;
    final recipient = _recipientForBillTo(nextBillTo, doc: current);
    current['billTo'] = recipient.billTo;
    current['billToName'] = recipient.name;
    current['billToPhone'] = recipient.phone;
    current['billToEmail'] = recipient.email;
    current['billToAddress'] = recipient.address;
    current.remove('pdfUrl');
    current.remove('pdfShortUrl');
    setState(() => _busy = true);
    try {
      await ctrl.updateDocument(docIndex, current);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<JobChatContact?> _pickSmsContact({String? preferredRole}) async {
    if (ctrl.chatContacts.length <= 1) {
      await ctrl.ensureChatContactsLoaded();
      if (!mounted) return null;
    }
    final contacts = [
      for (final c in ctrl.chatContacts)
        if (c.hasPhone) c,
    ];
    if (contacts.isEmpty) return null;
    if (preferredRole != null) {
      final wantOwner = preferredRole == 'owner';
      for (final c in contacts) {
        if (c.isOwner == wantOwner) return c;
      }
    }
    if (contacts.length == 1) return contacts.first;
    return showModalBottomSheet<JobChatContact>(
      context: context,
      useRootNavigator: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Кому отправить SMS?'.tr,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
              ),
              for (final contact in contacts)
                ListTile(
                  leading: Icon(
                    contact.isOwner ? Icons.person : Icons.location_on,
                    color: AppColors.primary,
                  ),
                  title: Text(contact.displayName),
                  subtitle: Text(contact.subtitleLine),
                  onTap: () => Navigator.pop(sheetContext, contact),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBillToBadge(Map<String, dynamic> doc) {
    final isTenant = _docBillTo(doc) == 'tenant';
    final recipient = _recipientForBillTo(
      isTenant ? 'tenant' : 'owner',
      doc: doc,
    );
    final roleLabel = isTenant
        ? context.tr('Арендатор', 'Tenant')
        : context.tr('Владелец', 'Owner');
    final showName =
        recipient.name.isNotEmpty &&
        recipient.name.toLowerCase() != roleLabel.toLowerCase() &&
        !Client.isPlaceholderName(recipient.name);
    final text = showName ? '$roleLabel: ${recipient.name}' : roleLabel;
    final fg = isTenant ? Colors.deepOrange.shade800 : AppColors.primaryOnCard;
    final bg = isTenant
        ? Colors.orange.withValues(alpha: 0.14)
        : AppColors.primary.withValues(alpha: 0.10);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isTenant ? Icons.home_work_outlined : Icons.person_outline,
            size: 12,
            color: fg,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: fg,
                fontWeight: FontWeight.w700,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _copyUrl(String url) async {
    if (!mounted) return;
    await AppFeedback.copy(context, url);
  }

  Widget _buildBillToSelector({
    required String currentBillTo,
    required ValueChanged<String>? onChanged,
  }) {
    final owner = _recipientForBillTo('owner');
    final tenant = _recipientForBillTo('tenant');

    Widget buildOption({
      required String value,
      required IconData icon,
      required String title,
      required String subtitle,
    }) {
      final selected = currentBillTo == value;
      final isTenant = value == 'tenant';
      final activeColor = isTenant
          ? Colors.deepOrange.shade700
          : AppColors.primary;
      return Expanded(
        child: Material(
          color: selected
              ? activeColor.withValues(alpha: 0.14)
              : AppColors.cardMuted,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onChanged == null || selected ? null : () => onChanged(value),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected ? activeColor : AppColors.border,
                  width: selected ? 1.5 : 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 18,
                    color: selected ? activeColor : AppColors.inkMuted,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: selected ? activeColor : AppColors.ink,
                          ),
                        ),
                        if (subtitle.isNotEmpty)
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColors.inkMuted,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (selected)
                    Icon(
                      Icons.check_circle,
                      size: 16,
                      color: activeColor,
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final ownerSub = [
      if (owner.name.isNotEmpty && !Client.isPlaceholderName(owner.name))
        owner.name,
      if (owner.phone.isNotEmpty) owner.phone,
    ].join(' · ');
    final tenantLabel = context.tr('Арендатор', 'Tenant');
    final tenantSub = [
      if (tenant.name.isNotEmpty &&
          tenant.name.toLowerCase() != tenantLabel.toLowerCase() &&
          !Client.isPlaceholderName(tenant.name))
        tenant.name,
      if (tenant.phone.isNotEmpty && tenant.phone != owner.phone) tenant.phone,
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 4),
          child: Text(
            context.tr('На кого выставить счёт:', 'Bill to:'),
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: AppColors.inkMuted,
            ),
          ),
        ),
        Row(
          children: [
            buildOption(
              value: 'owner',
              icon: Icons.person_outline,
              title: context.tr('Владелец', 'Owner'),
              subtitle: ownerSub,
            ),
            const SizedBox(width: 8),
            buildOption(
              value: 'tenant',
              icon: Icons.home_work_outlined,
              title: tenantLabel,
              subtitle: tenantSub,
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _resendCurrentLink(Map<String, dynamic> doc) async {
    final url = _stripeSmsUrl(doc);
    final billTo = _docBillTo(doc);
    final recipient = _recipientForBillTo(billTo, doc: doc);
    final chosen = await _pickSmsContact(preferredRole: billTo);
    if (!mounted) return;
    final phone = (chosen?.phone ?? recipient.phone).trim();
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
            'https://us-central1-fix-appliance-crm.cloudfunctions.net/p/${Uri.encodeComponent(code)}';
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
      SnackBar(content: Text(ok ? 'SMS отправлено'.tr : SmsService.failureText())),
    );
  }

  Future<void> _sendAppDocument(int documentIndex) async {
    if (documentIndex < 0 || documentIndex >= ctrl.documents.length) return;
    final doc = ctrl.documents[documentIndex];
    final billTo = _docBillTo(doc);
    final recipient = _recipientForBillTo(billTo, doc: doc);
    final chosen = await _pickSmsContact(preferredRole: billTo);
    if (!mounted) return;
    final items = doc['items'] as List? ?? [];
    final subtotal = ctrl.calcSubtotal(items);
    final tax = ctrl.calcTax(subtotal, doc['taxRate'] ?? 0.0);
    final total = ctrl.calcTotal(subtotal, tax);
    final paid = ctrl.calcPaid(doc['payments'] ?? []);
    final due = ctrl.calcDue(total, paid);
    final type = (doc['type'] ?? 'Invoice').toString();
    final kind = type == 'Estimate' ? 'estimate' : 'invoice';
    final rawDocNum = doc['number'];
    final docNum = rawDocNum is num
        ? rawDocNum.toInt()
        : (int.tryParse(
                (rawDocNum ?? '').toString().replaceAll(RegExp(r'\D'), ''),
              ) ??
              (documentIndex + 1));

    await DocumentTemplateService.showSendSheet(
      context: context,
      data: DocumentSendData(
        kind: kind,
        jobId: ctrl.jobId,
        clientId: ctrl.clientId,
        clientName: recipient.name.isNotEmpty
            ? recipient.name
            : (chosen?.displayName ?? ctrl.contactName),
        clientPhone: recipient.phone.isNotEmpty
            ? recipient.phone
            : (chosen?.phone ?? _smsPhone).trim(),
        clientAddress: recipient.address,
        documentNumber: docNum,
        documentIndex: documentIndex,
        items: items,
        subtotal: subtotal,
        tax: tax,
        taxRate: _money(doc['taxRate']),
        total: total,
        paid: paid,
        due: due,
        payments: List<Map<String, dynamic>>.from(doc['payments'] ?? []),
        subject: ctrl.workAddress.trim().isEmpty
            ? recipient.name
            : ctrl.workAddress,
        serviceDate: DateTime.tryParse((doc['createdAt'] ?? '').toString()),
        clientEmail: recipient.email.isNotEmpty
            ? recipient.email
            : ((chosen != null && chosen.hasEmail)
                  ? chosen.email
                  : ctrl.clientEmail),
        clientCompany: recipient.company,
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
    _inPayResult = true;
    try {
      final error = await StripeTerminalService.collectWithDialog(
        context: context,
        jobId: ctrl.jobId,
        documentIndex: documentIndex,
        amount: repair,
        tip: tip,
      );
      if (!mounted) return;
      await _showPayResult(
        success: error == null,
        message: error,
        documentIndex: documentIndex,
        amount: charge,
      );
    } catch (e) {
      if (!mounted) return;
      await _showPayResult(success: false, message: e.toString());
    } finally {
      _inPayResult = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runStripeAction({
    required String kind,
    required int documentIndex,
    double? amount,
    double tip = 0,
  }) async {
    final doc =
        documentIndex >= 0 && documentIndex < ctrl.documents.length
            ? ctrl.documents[documentIndex]
            : const <String, dynamic>{};
    final billTo = _docBillTo(doc);
    final recipient = _recipientForBillTo(billTo, doc: doc);
    final chosen = await _pickSmsContact(preferredRole: billTo);
    if (!mounted) return;
    final targetPhone = recipient.phone.isNotEmpty
        ? recipient.phone
        : (chosen?.phone ?? _smsPhone).trim();
    setState(() => _busy = true);
    try {
      final result = await StripeService.createPayment(
        jobId: ctrl.jobId,
        documentIndex: documentIndex,
        kind: kind,
        amount: amount,
        tip: tip,
        sendSms: true,
        to: targetPhone,
      );
      var smsSent = result.smsSent;
      if (!smsSent && targetPhone.isNotEmpty) {
        final docs = await SettingsService.loadDocumentSettings();
        smsSent = await SmsService.sendSms(
          to: targetPhone,
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
      sheetAnimationStyle: AppMotion.sheet,
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
                              method: 'Cash',
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
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: isBold ? FontWeight.w800 : FontWeight.w500,
              fontSize: isBold ? 15.5 : 13,
            ),
          ),
          Text(
            '\$${amount.toStringAsFixed(2)}',
            style: TextStyle(
              fontWeight: isBold ? FontWeight.w900 : FontWeight.w600,
              fontSize: isBold ? 16 : 13,
              color: color ?? (isBold ? AppColors.primaryOnCard : AppColors.ink),
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
    await _addLocalPayment(documentIndex, repair, method, tip: tip);
    await _showPayResult(
      success: true,
      documentIndex: documentIndex,
      amount: total,
    );
  }

  Future<void> _addLocalPayment(int docIndex, double amount, String method, {double tip = 0}) async {
    // Копия, а не сам документ: контроллер сравнивает «было / стало», чтобы
    // поймать первый частичный платёж и поставить статус «Депозит».
    final doc = Map<String, dynamic>.from(ctrl.documents[docIndex]);
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
        'method': 'Tip',
        'date': DateTime.now().toIso8601String(),
      });
    }
    doc['payments'] = payments;
    await ctrl.updateDocument(docIndex, doc);
  }

  Future<void> _showPayResult({
    required bool success,
    String? message,
    int? documentIndex,
    double? amount,
  }) async {
    if (!mounted) return;
    _inPayResult = true;
    try {
      // Чек после оплаты сам не уходит: ссылку на PDF отправляет владелец
      // кнопкой отправки документа. Прежний тихий автопуск жил под флагом
      // «Ручное подтверждение SMS» и при включённом флаге (а он был включён
      // всегда) не срабатывал ни разу — флага больше нет, нет и автопуска.
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
                if (!success && (message ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SelectableText(
                    message!.trim(),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
                  ),
                ],
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
      if (!mounted || !success) return;
      final paidFully = documentIndex != null &&
          documentIndex >= 0 &&
          documentIndex < ctrl.documents.length &&
          Job.isInvoice(ctrl.documents[documentIndex]) &&
          !Job.isDocumentTrashed(ctrl.documents[documentIndex]) &&
          Job.documentPayMark(ctrl.documents[documentIndex]) == 'paid';
      final depositTaken = !paidFully &&
          documentIndex != null &&
          documentIndex >= 0 &&
          documentIndex < ctrl.documents.length &&
          Job.documentDepositTaken(ctrl.documents[documentIndex]);
      if (paidFully) {
        await _offerReviewAfterPaid();
        await ctrl.completeAfterInvoicePaid();
      } else {
        if (depositTaken) await ctrl.markDepositTaken();
        ctrl.openFinanceMainList();
      }
    } finally {
      _inPayResult = false;
    }
  }

  void _onInvoiceFullyPaid() {
    if (_inPayResult) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_offerReviewAfterPaid());
    });
  }

  Future<void> _offerReviewAfterPaid() async {
    final now = DateTime.now();
    if (_lastReviewOfferAt != null &&
        now.difference(_lastReviewOfferAt!) < const Duration(seconds: 8)) {
      return;
    }
    _lastReviewOfferAt = now;
    if (!mounted) return;
    final chosen = await _pickSmsContact();
    if (!mounted) return;
    await JobReviewOffer.askAndSend(
      context,
      phone: chosen?.phone ?? ctrl.contactPhone,
      name: chosen?.displayName ?? ctrl.contactName,
      address: ctrl.workAddress,
      clientId: ctrl.clientId,
      jobId: ctrl.jobId,
    );
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
        color: AppColors.tint(color, 0.14),
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
                    color: AppColors.isDark
                        ? (approved
                            ? const Color(0xFF81C784)
                            : const Color(0xFFFFCA28))
                        : (approved
                            ? Colors.green.shade800
                            : const Color(0xFF92400E)),
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
