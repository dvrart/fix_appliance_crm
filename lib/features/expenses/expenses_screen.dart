import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../models/expense.dart';
import '../../services/expense_service.dart';
import '../../shared/widgets/app_bar_save.dart';
import '../../shared/widgets/dirty_leave_scope.dart';

class ExpensesScreen extends StatefulWidget {
  final bool startWithCamera;

  const ExpensesScreen({super.key, this.startWithCamera = false});

  @override
  State<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends State<ExpensesScreen> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.startWithCamera) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scan(ImageSource.camera);
      });
    }
  }

  Future<void> _chooseSource() async {
    if (_busy) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheet) {
        Widget row({
          required IconData icon,
          required String title,
          required String value,
        }) {
          return ListTile(
            leading: Icon(icon, color: const Color(0xFF14557F)),
            title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            onTap: () => Navigator.pop(sheet, value),
          );
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                row(
                  icon: Icons.photo_camera,
                  title: context.tr('Сфотографировать', 'Take a photo'),
                  value: 'camera',
                ),
                row(
                  icon: Icons.photo_library_outlined,
                  title: context.tr('Добавить фото', 'Add a photo'),
                  value: 'gallery',
                ),
                row(
                  icon: Icons.picture_as_pdf_outlined,
                  title: context.tr('Добавить PDF', 'Add a PDF'),
                  value: 'pdf',
                ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || choice == null) return;
    if (choice == 'pdf') {
      await _addPdf();
      return;
    }
    await _scan(choice == 'gallery' ? ImageSource.gallery : ImageSource.camera);
  }

  Future<void> _scan(ImageSource source) async {
    if (_busy) return;
    final file = await ExpenseService.pickPhoto(source);
    if (file == null || !mounted) return;
    await _saveFile(() => ExpenseService.addFromPhoto(file));
  }

  Future<void> _addPdf() async {
    if (_busy) return;
    final file = await ExpenseService.pickPdf();
    if (file == null || !mounted) return;
    await _saveFile(
      () => ExpenseService.addFromBytes(
        bytes: file.bytes,
        mime: file.mime,
        fileName: file.name,
      ),
    );
  }

  Future<void> _saveFile(Future<Expense> Function() save) async {
    setState(() => _busy = true);
    try {
      final expense = await save();
      if (!mounted) return;
      final info = expense.categoryInfo;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            expense.needsReview
                ? context.tr(
                    'Чек сохранён — проверьте сумму и категорию',
                    'Receipt saved — check amount and category',
                  )
                : '${info.label(AppLocale.instance.isEn)} · \$${expense.amountExHst.toStringAsFixed(2)} · GIFI ${info.gifi}',
          ),
        ),
      );
      if (expense.needsReview) {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ExpenseEditPage(expense: expense)),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addManual() async {
    final now = DateTime.now();
    final expense = Expense(
      id: '',
      vendor: '',
      date: now,
      amountExHst: 0,
      hst: 0,
      total: 0,
      category: ExpenseCategories.other.id,
      gifi: ExpenseCategories.other.gifi,
      createdAt: now,
    );
    final id = await ExpenseService.create(expense);
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ExpenseEditPage(expense: expense.copyWith(id: id)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: Text(context.tr('Расходы', 'Expenses')),
        backgroundColor: const Color(0xFF14557F),
        foregroundColor: Colors.white,
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            height: 52,
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _busy ? null : _chooseSource,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF14557F),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFF14557F).withValues(alpha: 0.7),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: _busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.add_a_photo_outlined),
              label: Text(
                _busy
                    ? context.tr('Читаю чек…', 'Reading receipt…')
                    : context.tr('Добавить чек', 'Add a receipt'),
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
            ),
          ),
        ),
      ),
      body: StreamBuilder<List<Expense>>(
        stream: ExpenseService.streamAll(),
        builder: (context, snapshot) {
          final items = snapshot.data ?? const <Expense>[];
          if (snapshot.connectionState == ConnectionState.waiting &&
              items.isEmpty) {
            return const Center(
              child: CircularProgressIndicator(color: Color(0xFFFCC520)),
            );
          }
          if (items.isEmpty) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 32, 20, 24),
              children: [
                Text(
                  context.tr(
                    'Сфотографируйте чек, добавьте фото или PDF — ИИ сам поставит категорию: бензин, страховка, инструмент, телефон… Цифры попадут в отчёт T2.',
                    'Photograph a receipt, add a photo, or a PDF — AI files it as fuel, insurance, tools, phone… The amounts go into the T2 report.',
                  ),
                  style: const TextStyle(height: 1.4, fontSize: 16),
                ),
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: _addManual,
                  icon: const Icon(Icons.add),
                  label: Text(context.tr('Вписать вручную', 'Enter manually')),
                ),
              ],
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
            itemCount: items.length + 1,
            itemBuilder: (context, index) {
              if (index == items.length) {
                return TextButton.icon(
                  onPressed: _addManual,
                  icon: const Icon(Icons.add),
                  label: Text(context.tr('Вписать вручную', 'Enter manually')),
                );
              }
              final item = items[index];
              final info = item.categoryInfo;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ExpenseEditPage(expense: item),
                        ),
                      );
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CircleAvatar(
                            backgroundColor:
                                const Color(0xFF14557F).withValues(alpha: 0.12),
                            child: Icon(info.icon, color: const Color(0xFF14557F)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.vendor.isEmpty
                                      ? info.label(AppLocale.instance.isEn)
                                      : item.vendor,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${info.label(AppLocale.instance.isEn)} · GIFI ${info.gifi}'
                                  '${item.needsReview ? ' · ${context.tr('проверить', 'check')}' : ''}'
                                  '${item.capitalAsset ? ' · CCA' : ''}\n'
                                  '${DateFormat('d MMM yyyy', AppLocale.instance.dateLocale).format(item.date)}',
                                  style: TextStyle(
                                    color: Colors.grey.shade700,
                                    height: 1.35,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '\$${item.amountExHst.toStringAsFixed(2)}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 16,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          _ExpenseThumb(expense: item),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _ExpenseThumb extends StatelessWidget {
  final Expense expense;
  final double size;

  const _ExpenseThumb({required this.expense, this.size = 72});

  Future<void> _open(BuildContext context) async {
    final url = expense.photoUrl.trim();
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final box = BoxDecoration(
      color: Colors.grey.shade200,
      borderRadius: BorderRadius.circular(10),
    );
    Widget child;
    if (!expense.hasFile) {
      child = Icon(Icons.receipt_long, color: Colors.grey.shade500, size: 28);
    } else if (expense.isPdf) {
      child = const Icon(Icons.picture_as_pdf, color: Color(0xFFC62828), size: 32);
    } else {
      child = ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.network(
          expense.photoUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Icon(
            Icons.broken_image_outlined,
            color: Colors.grey.shade500,
          ),
        ),
      );
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: expense.hasFile ? () => _open(context) : null,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: size,
          height: size,
          decoration: box,
          clipBehavior: Clip.antiAlias,
          alignment: Alignment.center,
          child: child,
        ),
      ),
    );
  }
}

class ExpenseEditPage extends StatefulWidget {
  final Expense expense;

  const ExpenseEditPage({super.key, required this.expense});

  @override
  State<ExpenseEditPage> createState() => _ExpenseEditPageState();
}

class _ExpenseEditPageState extends State<ExpenseEditPage> {
  late Expense _draft;
  late final TextEditingController _vendor;
  late final TextEditingController _net;
  late final TextEditingController _hst;
  late final TextEditingController _total;
  late final TextEditingController _note;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _draft = widget.expense;
    _vendor = TextEditingController(text: _draft.vendor);
    _net = TextEditingController(text: _fmt(_draft.amountExHst));
    _hst = TextEditingController(text: _fmt(_draft.hst));
    _total = TextEditingController(text: _fmt(_draft.total));
    _note = TextEditingController(text: _draft.note);
  }

  @override
  void dispose() {
    _vendor.dispose();
    _net.dispose();
    _hst.dispose();
    _total.dispose();
    _note.dispose();
    super.dispose();
  }

  String _fmt(double value) =>
      value == 0 ? '' : value.toStringAsFixed(2);

  double _num(TextEditingController c) =>
      double.tryParse(c.text.replaceAll(',', '.').trim()) ?? 0;

  Expense get _current => _draft.copyWith(
        vendor: _vendor.text.trim(),
        amountExHst: _num(_net),
        hst: _num(_hst),
        total: _num(_total) > 0 ? _num(_total) : _num(_net) + _num(_hst),
        note: _note.text.trim(),
        needsReview: false,
      );

  bool get _dirty {
    final now = _current;
    final old = widget.expense;
    return now.vendor != old.vendor ||
        now.amountExHst != old.amountExHst ||
        now.hst != old.hst ||
        now.total != old.total ||
        now.note != old.note ||
        now.category != old.category ||
        now.capitalAsset != old.capitalAsset ||
        now.date != old.date;
  }

  Future<bool> _persist() async {
    if (_saving) return false;
    setState(() => _saving = true);
    try {
      await ExpenseService.update(_draft.id, _current);
      return mounted;
    } catch (_) {
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    if (!_dirty) return;
    if (await _persist() && mounted) Navigator.pop(context);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _draft.date,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 3)),
    );
    if (picked == null) return;
    setState(() => _draft = _draft.copyWith(date: picked));
  }

  @override
  Widget build(BuildContext context) {
    final info = _draft.categoryInfo;
    return DirtyLeaveScope(
      dirty: _dirty,
      onSave: _persist,
      child: Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: Text(context.tr('Чек', 'Receipt')),
        backgroundColor: const Color(0xFF14557F),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: context.tr('Удалить', 'Delete'),
            onPressed: () async {
              await ExpenseService.delete(_draft.id);
              if (context.mounted) Navigator.pop(context);
            },
            icon: const Icon(Icons.delete, color: Colors.redAccent),
          ),
          AppBarSaveButton(
            dirty: _dirty,
            saving: _saving,
            onPressed: _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _vendor,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: context.tr('Магазин', 'Vendor'),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _ExpenseThumb(expense: _draft, size: 88),
            ],
          ),
          const SizedBox(height: 10),
          ListTile(
            tileColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            title: Text(DateFormat('d MMMM yyyy', AppLocale.instance.dateLocale).format(_draft.date)),
            trailing: const Icon(Icons.calendar_month),
            onTap: _pickDate,
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            value: _draft.category,
            decoration: InputDecoration(
              labelText: context.tr('Категория', 'Category'),
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            items: [
              for (final item in ExpenseCategories.all)
                DropdownMenuItem(
                  value: item.id,
                  child: Text('${item.label(AppLocale.instance.isEn)} · ${item.gifi}'),
                ),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() => _draft = _draft.copyWith(category: value));
            },
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _net,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: context.tr('Без HST', 'Excl. HST'),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _hst,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'HST',
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _total,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: context.tr('Итого', 'Total'),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            context.tr(
              'В T2 идёт сумма без HST, код GIFI ${info.gifi}. HST — в GST34 как ITC.',
              'T2 uses the amount excluding HST, GIFI ${info.gifi}. HST goes on GST34 as an ITC.',
            ),
            style: const TextStyle(color: Colors.black54, height: 1.35),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              context.tr(
                'Это оборудование (CCA), не расход года',
                'This is equipment (CCA), not this year’s expense',
              ),
            ),
            value: _draft.capitalAsset,
            onChanged: (value) {
              setState(() => _draft = _draft.copyWith(capitalAsset: value));
            },
          ),
          TextField(
            controller: _note,
            onChanged: (_) => setState(() {}),
            maxLines: 2,
            decoration: InputDecoration(
              labelText: context.tr('Заметка', 'Note'),
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    ),
    );
  }
}
