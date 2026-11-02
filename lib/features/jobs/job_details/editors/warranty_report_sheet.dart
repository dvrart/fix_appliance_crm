import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/constants.dart';
import '../../../../core/l10n/app_locale.dart';
import '../../../../services/ai_service.dart';
import '../../../../shared/widgets/confirm_action_sheet.dart';

/// Отчёт для паспорта гарантийной техники. Возвращает текст или null, если
/// мастер закрыл лист. Пустую строку сохранить нельзя — кнопка молчит,
/// пока текста нет.
class WarrantyReportSheet {
  static Future<String?> ask(
    BuildContext context, {
    String existing = '',
    String draftProblem = '',
    List<String> invoiceItems = const [],
  }) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _Sheet(
        existing: existing,
        draftProblem: draftProblem,
        invoiceItems: invoiceItems,
      ),
    );
  }
}

class _Sheet extends StatefulWidget {
  final String existing;
  final String draftProblem;
  final List<String> invoiceItems;

  const _Sheet({
    required this.existing,
    required this.draftProblem,
    required this.invoiceItems,
  });

  @override
  State<_Sheet> createState() => _SheetState();
}

class _SheetState extends State<_Sheet> {
  late final TextEditingController _text = TextEditingController(text: widget.existing);
  final _hasText = ValueNotifier<bool>(false);
  final _ready = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    _hasText.value = _text.text.trim().isNotEmpty;
    _ready.value = widget.existing.trim().isNotEmpty;
    if (widget.existing.trim().isEmpty) unawaited(_draft());
  }

  Future<void> _draft() async {
    final draft = await AiService.draftServiceReport(
      problem: widget.draftProblem,
      invoiceItems: widget.invoiceItems,
    );
    _ready.value = true;
    if (draft.isNotEmpty && _text.text.trim().isEmpty) {
      _text.text = draft;
      _hasText.value = true;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _hasText.dispose();
    _ready.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _ready,
      builder: (context, done, _) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            16 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Отчет для паспорта техники'.tr,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                  color: AppColors.ink,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Его увидит клиент и другой мастер, отсканировав наклейку. Напишите по-русски — переведётся само.'
                    .tr,
                style: TextStyle(color: AppColors.inkMuted, fontSize: 13),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _text,
                autofocus: true,
                minLines: 2,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (value) => _hasText.value = value.trim().isNotEmpty,
                decoration: InputDecoration(
                  hintText: 'Что нашли и что сделали'.tr,
                  suffixIcon: done
                      ? null
                      : const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  RoundActionButton(
                    color: const Color(0xFFE53935),
                    icon: Icons.close_rounded,
                    tooltip: 'Не сейчас'.tr,
                    onTap: () => Navigator.pop(context),
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: _hasText,
                    builder: (_, filled, _) => Opacity(
                      opacity: filled ? 1 : 0.35,
                      child: RoundActionButton(
                        color: const Color(0xFF22C55E),
                        icon: Icons.check_rounded,
                        tooltip: 'Сохранить'.tr,
                        onTap: filled
                            ? () => Navigator.pop(context, _text.text.trim())
                            : () {},
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
