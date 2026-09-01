import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../models/document_settings.dart';
import '../../../services/settings_service.dart';
import '../../../shared/widgets/app_bar_save.dart';
import '../../../shared/widgets/dirty_leave_scope.dart';
import '../widgets/company_logo.dart';
import '../widgets/settings_ui.dart';

enum _DragKind { logo, qr }

/// Конструктор PDF-счёта: размеры + перетаскивание логотипа и QR пальцем.
class InvoiceBuilderPage extends StatefulWidget {
  const InvoiceBuilderPage({super.key});

  @override
  State<InvoiceBuilderPage> createState() => _InvoiceBuilderPageState();
}

class _InvoiceBuilderPageState extends State<InvoiceBuilderPage> {
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;
  _DragKind? _dragging;

  String _companyName = 'Fix Appliance';
  String _logoUrl = '';
  bool _showLogo = true;
  bool _showQr = true;
  bool _showPayments = true;
  int _accent = 0xFF14557F;
  double _logoSize = 56;
  double _qrSize = 52;
  String _logoAlign = DocumentSettings.invoiceLogoAlignLeft;
  String _qrAlign = DocumentSettings.invoiceQrFooterLeft;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _markDirty() {
    if (_loading || _dirty) return;
    setState(() => _dirty = true);
  }

  Future<void> _load() async {
    final settings = await SettingsService.loadDocumentSettings();
    if (!mounted) return;
    setState(() {
      _companyName = settings.companyName;
      _logoUrl = settings.logoUrl;
      _showLogo = settings.invoiceShowLogo;
      _showQr = settings.invoiceShowQr;
      _showPayments = settings.invoiceShowPayments;
      _accent = settings.invoiceAccent;
      _logoSize = settings.invoiceLogoSize;
      _qrSize = settings.invoiceQrSize;
      _logoAlign = settings.invoiceLogoAlign;
      _qrAlign = settings.invoiceQrAlign;
      _loading = false;
      _dirty = false;
    });
  }

  Future<bool> _save() async {
    setState(() => _saving = true);
    try {
      final current = await SettingsService.loadDocumentSettings();
      await SettingsService.saveDocumentSettings(
        current.copyWith(
          invoiceShowLogo: _showLogo,
          invoiceShowQr: _showQr,
          invoiceShowPayments: _showPayments,
          invoiceAccent: _accent,
          invoiceLogoSize: _logoSize,
          invoiceQrSize: _qrSize,
          invoiceLogoAlign: _logoAlign,
          invoiceQrAlign: _qrAlign,
        ),
      );
      if (!mounted) return false;
      setState(() {
        _saving = false;
        _dirty = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Конструктор счёта сохранён'.tr),
          backgroundColor: Colors.green,
        ),
      );
      return true;
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      return false;
    }
  }

  void _acceptDrop(_DragKind kind, String align) {
    HapticFeedback.selectionClick();
    setState(() {
      if (kind == _DragKind.logo) {
        _logoAlign = align;
        _showLogo = true;
      } else {
        _qrAlign = align;
        _showQr = true;
      }
      _dragging = null;
      _markDirty();
    });
  }

  @override
  Widget build(BuildContext context) {
    return DirtyLeaveScope(
      dirty: _dirty,
      onSave: _save,
      child: Scaffold(
        backgroundColor: Colors.grey.shade100,
        appBar: AppBar(
          title: Text('Конструктор счёта'.tr),
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          automaticallyImplyLeading: false,
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.only(top: 12, bottom: 32),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      'Зажмите логотип или QR и перетащите в зону на макете.'.tr,
                      style: const TextStyle(color: Colors.black54),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: _preview(),
                  ),
                  const SizedBox(height: 12),
                  SettingsTileSection(
                    title: 'Элементы'.tr,
                    tiles: [
                      SettingsHubTile(
                        title: 'Логотип'.tr,
                        subtitle: _showLogo ? 'Вкл'.tr : 'Выкл'.tr,
                        icon: Icons.image_outlined,
                        color: Colors.orange,
                        active: _showLogo,
                        onTap: () => setState(() {
                          _showLogo = !_showLogo;
                          _markDirty();
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
                          _markDirty();
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
                          _markDirty();
                        }),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text(
                      'Размер логотипа'.tr,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        const Text('32', style: TextStyle(fontSize: 12)),
                        Expanded(
                          child: Slider(
                            value: _logoSize.clamp(32, 96),
                            min: 32,
                            max: 96,
                            divisions: 16,
                            label: '${_logoSize.round()}',
                            onChanged: _showLogo
                                ? (v) => setState(() {
                                      _logoSize = v;
                                      _markDirty();
                                    })
                                : null,
                          ),
                        ),
                        const Text('96', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text(
                      'Размер QR-кода'.tr,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        const Text('32', style: TextStyle(fontSize: 12)),
                        Expanded(
                          child: Slider(
                            value: _qrSize.clamp(32, 96),
                            min: 32,
                            max: 96,
                            divisions: 16,
                            label: '${_qrSize.round()}',
                            onChanged: _showQr
                                ? (v) => setState(() {
                                      _qrSize = v;
                                      _markDirty();
                                    })
                                : null,
                          ),
                        ),
                        const Text('96', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
        bottomNavigationBar: BottomConfirmButton(
          dirty: _dirty,
          saving: _saving,
          onPressed: _save,
        ),
      ),
    );
  }

  Widget _draggable(_DragKind kind, Widget child) {
    return LongPressDraggable<_DragKind>(
      data: kind,
      hapticFeedbackOnStart: true,
      onDragStarted: () => setState(() => _dragging = kind),
      onDragEnd: (_) {
        if (mounted) setState(() => _dragging = null);
      },
      onDraggableCanceled: (_, _) {
        if (mounted) setState(() => _dragging = null);
      },
      feedback: Material(
        color: Colors.transparent,
        elevation: 6,
        child: Opacity(opacity: 0.9, child: child),
      ),
      childWhenDragging: Opacity(opacity: 0.25, child: child),
      child: child,
    );
  }

  Widget _dropZone({
    required _DragKind accepts,
    required String align,
    required Widget child,
    String? label,
    double minHeight = 48,
  }) {
    final active = _dragging == accepts;
    return DragTarget<_DragKind>(
      onWillAcceptWithDetails: (details) => details.data == accepts,
      onAcceptWithDetails: (details) => _acceptDrop(details.data, align),
      builder: (context, candidate, rejected) {
        final hovering = candidate.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          constraints: BoxConstraints(minHeight: minHeight),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: hovering
                ? AppColors.accent.withValues(alpha: 0.35)
                : active
                    ? AppColors.primary.withValues(alpha: 0.08)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: active
                ? Border.all(
                    color: hovering ? AppColors.accent : AppColors.primary,
                    width: hovering ? 2 : 1,
                    strokeAlign: BorderSide.strokeAlignInside,
                  )
                : null,
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              child,
              if (active && label != null)
                Positioned(
                  bottom: 0,
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 9,
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _logoWidget() {
    return CompanyLogo(url: _logoUrl, size: _logoSize.clamp(32, 96));
  }

  Widget _qrWidget() {
    return Icon(Icons.qr_code, size: _qrSize.clamp(32, 96));
  }

  Widget _preview() {
    final accent = Color(_accent);
    final logoShown = _showLogo ? _draggable(_DragKind.logo, _logoWidget()) : null;
    final qrShown = _showQr ? _draggable(_DragKind.qr, _qrWidget()) : null;

    final qrInHeader =
        _showQr && _qrAlign == DocumentSettings.invoiceQrHeaderRight;
    final qrInFooter = _showQr &&
        (_qrAlign == DocumentSettings.invoiceQrFooterLeft ||
            _qrAlign == DocumentSettings.invoiceQrFooterRight);
    final qrUnderTotals =
        _showQr && _qrAlign == DocumentSettings.invoiceQrUnderTotals;

    Widget companyBlock() {
      return Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _companyName,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const Text('info@example.com', style: TextStyle(fontSize: 9)),
          ],
        ),
      );
    }

    Widget numberBlock() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const Text(
            'Invoice #000042',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          Text(
            'Aug 28, 2026',
            style: TextStyle(fontSize: 10, color: Colors.grey.shade700),
          ),
        ],
      );
    }

    Widget logoSlot(String align, {Widget? placed}) {
      return _dropZone(
        accepts: _DragKind.logo,
        align: align,
        label: 'Лого'.tr,
        child: placed ??
            SizedBox(
              width: _logoSize.clamp(32, 96),
              height: _logoSize.clamp(32, 96),
              child: _dragging == _DragKind.logo
                  ? Icon(Icons.add, color: Colors.grey.shade400)
                  : null,
            ),
      );
    }

    Widget qrSlot(String align, {Widget? placed}) {
      return _dropZone(
        accepts: _DragKind.qr,
        align: align,
        label: 'QR',
        child: placed ??
            SizedBox(
              width: _qrSize.clamp(32, 96),
              height: _qrSize.clamp(32, 96),
              child: _dragging == _DragKind.qr
                  ? Icon(Icons.add, color: Colors.grey.shade400)
                  : null,
            ),
      );
    }

    Widget headerRow() {
      final showAllLogoSlots = _dragging == _DragKind.logo;
      final centerLogo = _logoAlign == DocumentSettings.invoiceLogoAlignCenter;
      final rightLogo = _logoAlign == DocumentSettings.invoiceLogoAlignRight;

      if (showAllLogoSlots) {
        return Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: logoSlot(
                    DocumentSettings.invoiceLogoAlignLeft,
                    placed: !centerLogo && !rightLogo ? logoShown : null,
                  ),
                ),
                Expanded(
                  child: logoSlot(
                    DocumentSettings.invoiceLogoAlignCenter,
                    placed: centerLogo ? logoShown : null,
                  ),
                ),
                Expanded(
                  child: logoSlot(
                    DocumentSettings.invoiceLogoAlignRight,
                    placed: rightLogo ? logoShown : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                companyBlock(),
                if (_dragging == _DragKind.qr || qrInHeader)
                  qrSlot(
                    DocumentSettings.invoiceQrHeaderRight,
                    placed: qrInHeader ? qrShown : null,
                  ),
                const SizedBox(width: 8),
                numberBlock(),
              ],
            ),
          ],
        );
      }

      if (centerLogo && logoShown != null) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(child: logoSlot(DocumentSettings.invoiceLogoAlignCenter, placed: logoShown)),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                companyBlock(),
                if (_dragging == _DragKind.qr || qrInHeader)
                  qrSlot(
                    DocumentSettings.invoiceQrHeaderRight,
                    placed: qrInHeader ? qrShown : null,
                  ),
                const SizedBox(width: 8),
                numberBlock(),
              ],
            ),
          ],
        );
      }

      if (rightLogo) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            companyBlock(),
            if (logoShown != null)
              logoSlot(DocumentSettings.invoiceLogoAlignRight, placed: logoShown),
            if (_dragging == _DragKind.qr || qrInHeader)
              qrSlot(
                DocumentSettings.invoiceQrHeaderRight,
                placed: qrInHeader ? qrShown : null,
              ),
            const SizedBox(width: 8),
            numberBlock(),
          ],
        );
      }

      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (logoShown != null)
            logoSlot(DocumentSettings.invoiceLogoAlignLeft, placed: logoShown),
          if (logoShown == null && _dragging == _DragKind.logo)
            logoSlot(DocumentSettings.invoiceLogoAlignLeft),
          companyBlock(),
          if (_dragging == _DragKind.qr || qrInHeader)
            qrSlot(
              DocumentSettings.invoiceQrHeaderRight,
              placed: qrInHeader ? qrShown : null,
            ),
          const SizedBox(width: 8),
          numberBlock(),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(height: 4, color: accent),
          const SizedBox(height: 12),
          headerRow(),
          const SizedBox(height: 12),
          const Text(
            'Invoice for John Smith',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          const Text(
            '123 Example St',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const Divider(),
          const Text('Refrigerator Repair     \$150.00'),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: const [
                  Text('Subtotal  \$150.00', style: TextStyle(fontSize: 11)),
                  Text(
                    'Total Paid  \$169.50',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ],
          ),
          if (qrUnderTotals || _dragging == _DragKind.qr) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: qrSlot(
                DocumentSettings.invoiceQrUnderTotals,
                placed: qrUnderTotals ? qrShown : null,
              ),
            ),
          ],
          if (_showPayments)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Payments  ·  Mastercard',
                style: TextStyle(fontSize: 11, color: Colors.black54),
              ),
            ),
          if (qrInFooter || _dragging == _DragKind.qr) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: qrSlot(
                    DocumentSettings.invoiceQrFooterLeft,
                    placed: _qrAlign == DocumentSettings.invoiceQrFooterLeft
                        ? qrShown
                        : null,
                  ),
                ),
                const Expanded(
                  child: Text(
                    'fix-appliance.ca',
                    style: TextStyle(fontSize: 9, color: Colors.black54),
                    textAlign: TextAlign.center,
                  ),
                ),
                Expanded(
                  child: qrSlot(
                    DocumentSettings.invoiceQrFooterRight,
                    placed: _qrAlign == DocumentSettings.invoiceQrFooterRight
                        ? qrShown
                        : null,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
