import 'package:flutter/material.dart';
import '../../core/constants.dart';
import 'keyboard_safe.dart';
import '../../core/l10n/app_locale.dart';

/// Открывает нижний лист для выбора значения из справочника
/// (тип техники / бренд). Если нужного значения нет — можно
/// добавить его прямо тут же, и оно попадёт в общий список.
Future<String?> showCatalogPicker({
  required BuildContext context,
  required String title,
  required Stream<List<String>> itemsStream,
  required Future<void> Function(String value) onAdd,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    useSafeArea: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) =>
        _CatalogPickerSheet(title: title, itemsStream: itemsStream, onAdd: onAdd),
  );
}

class _CatalogPickerSheet extends StatefulWidget {
  final String title;
  final Stream<List<String>> itemsStream;
  final Future<void> Function(String value) onAdd;

  const _CatalogPickerSheet({
    required this.title,
    required this.itemsStream,
    required this.onAdd,
  });

  @override
  State<_CatalogPickerSheet> createState() => _CatalogPickerSheetState();
}

class _CatalogPickerSheetState extends State<_CatalogPickerSheet> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  bool _isAdding = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _addAndSelect(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty || _isAdding) return;
    setState(() => _isAdding = true);
    try {
      await widget.onAdd(trimmed);
      if (mounted) Navigator.pop(context, trimmed);
    } finally {
      if (mounted) setState(() => _isAdding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardAvoidingSheet(
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primary,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: _searchCtrl,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'Поиск или новое значение...'.tr,
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.grey.shade50,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
              ),
              onChanged: (v) => setState(() => _query = v),
              onSubmitted: _addAndSelect,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: StreamBuilder<List<String>>(
              stream: widget.itemsStream,
              builder: (context, snapshot) {
                final all = snapshot.data ?? [];
                final q = _query.trim().toLowerCase();
                final filtered = q.isEmpty
                    ? all
                    : all.where((s) => s.toLowerCase().contains(q)).toList();
                final exactMatch = all.any((s) => s.toLowerCase() == q);

                if (!snapshot.hasData) {
                  return Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: CircularProgressIndicator(color: AppColors.accent),
                    ),
                  );
                }

                return ListView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(0, 4, 0, 12),
                  children: [
                    ...filtered.map(
                      (item) => ListTile(
                        leading: const Icon(Icons.label_outline, color: Colors.grey),
                        title: Text(trAny(item)),
                        onTap: () => Navigator.pop(context, item),
                      ),
                    ),
                    if (filtered.isEmpty && q.isEmpty)
                      Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Список пуст'.tr,
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    if (q.isNotEmpty && !exactMatch)
                      ListTile(
                        leading: _isAdding
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Icon(Icons.add_circle, color: AppColors.primary),
                        title: Text(
                          '${'Добавить'.tr} «${_searchCtrl.text.trim()}»',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: AppColors.primary,
                          ),
                        ),
                        onTap: _isAdding
                            ? null
                            : () => _addAndSelect(_searchCtrl.text),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
