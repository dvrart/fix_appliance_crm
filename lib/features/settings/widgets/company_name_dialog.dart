import 'package:flutter/material.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../shared/widgets/email_field.dart';

Future<String?> showCompanyNameDialog({
  required BuildContext context,
  required String initialName,
}) {
  return showSettingsTextDialog(
    context: context,
    title: 'Название компании'.tr,
    label: 'Название в меню'.tr,
    initialValue: initialName,
    capitalization: TextCapitalization.words,
  );
}

Future<String?> showSmsHeaderDialog({
  required BuildContext context,
  required String initialValue,
}) {
  return showSettingsTextDialog(
    context: context,
    title: 'Шапка SMS'.tr,
    label: 'Первая строка каждого SMS'.tr,
    helperText:
        'Только эта строка ставится в начало каждого SMS. Название компании и FIX ApplianceCA туда не добавляются. Пример: fix-appliance.ca. Оставьте пустым, если шапка не нужна.'.tr,
    initialValue: initialValue,
  );
}

Future<String?> showCompanyPhoneDialog({
  required BuildContext context,
  required String initialValue,
}) {
  return showSettingsTextDialog(
    context: context,
    title: 'Телефон компании'.tr,
    label: 'Телефон в счетах и SMS'.tr,
    initialValue: initialValue,
    keyboardType: TextInputType.phone,
  );
}

Future<String?> showCompanyEmailDialog({
  required BuildContext context,
  required String initialValue,
}) {
  return showSettingsTextDialog(
    context: context,
    title: 'Email компании'.tr,
    label: 'Почта в счетах'.tr,
    initialValue: initialValue,
    keyboardType: TextInputType.emailAddress,
  );
}

Future<String?> showCompanyAddressDialog({
  required BuildContext context,
  required String initialValue,
}) {
  return showSettingsTextDialog(
    context: context,
    title: 'Адрес компании'.tr,
    label: 'Адрес в счетах и PDF'.tr,
    initialValue: initialValue,
    capitalization: TextCapitalization.sentences,
    maxLines: 2,
  );
}

Future<String?> showHstNumberDialog({
  required BuildContext context,
  required String initialValue,
}) {
  return showSettingsTextDialog(
    context: context,
    title: 'HST / GST номер'.tr,
    label: 'Налоговый номер в счетах'.tr,
    initialValue: initialValue,
  );
}

Future<String?> showSettingsTextDialog({
  required BuildContext context,
  required String title,
  required String label,
  required String initialValue,
  String? helperText,
  TextCapitalization capitalization = TextCapitalization.none,
  TextInputType? keyboardType,
  int maxLines = 1,
}) {
  return showDialog<String>(
    context: context,
    useRootNavigator: true,
    builder: (context) => SettingsTextDialog(
      title: title,
      label: label,
      helperText: helperText,
      initialValue: initialValue,
      capitalization: capitalization,
      keyboardType: keyboardType,
      maxLines: maxLines,
    ),
  );
}

class CompanyNameDialog extends StatelessWidget {
  final String initialName;

  const CompanyNameDialog({super.key, required this.initialName});

  @override
  Widget build(BuildContext context) {
    return SettingsTextDialog(
      title: 'Название компании'.tr,
      label: 'Название в меню'.tr,
      initialValue: initialName,
      capitalization: TextCapitalization.words,
    );
  }
}

class SettingsTextDialog extends StatefulWidget {
  final String title;
  final String label;
  final String? helperText;
  final String initialValue;
  final TextCapitalization capitalization;
  final TextInputType? keyboardType;
  final int maxLines;

  const SettingsTextDialog({
    super.key,
    required this.title,
    required this.label,
    required this.initialValue,
    this.helperText,
    this.capitalization = TextCapitalization.none,
    this.keyboardType,
    this.maxLines = 1,
  });

  @override
  State<SettingsTextDialog> createState() => _SettingsTextDialogState();
}

class _SettingsTextDialogState extends State<SettingsTextDialog> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _close([String? value]) {
    if (_closing) return;
    _closing = true;
    _focusNode.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pop(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      scrollable: true,
      content: widget.keyboardType == TextInputType.emailAddress
          ? EmailAutocompleteField(
              controller: _controller,
              focusNode: _focusNode,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (value) => _close(value.trim()),
              decoration: InputDecoration(
                labelText: widget.label,
                helperText: widget.helperText,
                helperMaxLines: 4,
                border: const OutlineInputBorder(),
              ),
            )
          : TextField(
        controller: _controller,
        focusNode: _focusNode,
        autofocus: true,
        textCapitalization: widget.capitalization,
        keyboardType: widget.keyboardType,
        maxLines: widget.maxLines,
        textInputAction: widget.maxLines > 1
            ? TextInputAction.newline
            : TextInputAction.done,
        onSubmitted: widget.maxLines > 1
            ? null
            : (value) => _close(value.trim()),
        decoration: InputDecoration(
          labelText: widget.label,
          helperText: widget.helperText,
          helperMaxLines: 4,
          border: const OutlineInputBorder(),
          alignLabelWithHint: widget.maxLines > 1,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _close(),
          child: Text('Отмена'.tr),
        ),
        ElevatedButton(
          onPressed: () => _close(_controller.text.trim()),
          child: Text('Сохранить'.tr),
        ),
      ],
    );
  }
}
