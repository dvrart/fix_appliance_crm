import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';

const List<String> kCommonEmailDomains = [
  'gmail.com',
  'yahoo.com',
  'hotmail.com',
  'outlook.com',
  'icloud.com',
];

/// Поле email: после «@» предлагает популярные домены сверху, над клавиатурой.
class EmailAutocompleteField extends StatefulWidget {
  final TextEditingController controller;
  final InputDecoration? decoration;
  final String? Function(String?)? validator;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final TextInputAction? textInputAction;
  final FocusNode? focusNode;
  final ValueChanged<String>? onFieldSubmitted;

  const EmailAutocompleteField({
    super.key,
    required this.controller,
    this.decoration,
    this.validator,
    this.autofocus = false,
    this.onChanged,
    this.textInputAction,
    this.focusNode,
    this.onFieldSubmitted,
  });

  @override
  State<EmailAutocompleteField> createState() => _EmailAutocompleteFieldState();
}

class _EmailAutocompleteFieldState extends State<EmailAutocompleteField> {
  List<String> _suggestions = [];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_rebuild);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    final next = _computeSuggestions(widget.controller.text);
    if (next.join('|') == _suggestions.join('|')) return;
    setState(() => _suggestions = next);
  }

  List<String> _computeSuggestions(String text) {
    var value = text.trim();
    if (value.isEmpty) return const [];
    if (!value.contains('@')) return const [];
    final at = value.lastIndexOf('@');
    final local = value.substring(0, at).trim();
    if (local.isEmpty) return const [];
    final typed = value.substring(at + 1).toLowerCase();
    if (typed.contains(' ')) return const [];
    return [
      for (final domain in kCommonEmailDomains)
        if (domain.startsWith(typed) && domain != typed) '$local@$domain',
    ];
  }

  void _apply(String value) {
    widget.controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    widget.onChanged?.call(value);
    setState(() => _suggestions = const []);
  }

  void _insertAt() {
    final text = widget.controller.text;
    if (!text.contains('@')) {
      final next = text.trim().isEmpty ? '@' : '${text.trim()}@';
      widget.controller.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
      widget.onChanged?.call(next);
    }
    _rebuild();
  }

  Widget _chips() {
    if (_suggestions.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final suggestion in _suggestions)
            ActionChip(
              avatar: const Icon(Icons.alternate_email, size: 16),
              label: Text(
                suggestion.substring(suggestion.indexOf('@')),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              onPressed: () => _apply(suggestion),
              backgroundColor: AppColors.primary.withValues(alpha: 0.08),
              side: BorderSide(color: AppColors.primary.withValues(alpha: 0.2)),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.decoration ??
        InputDecoration(
          labelText: 'Электронный адрес'.tr,
          prefixIcon: const Icon(Icons.email_outlined),
          border: const OutlineInputBorder(),
        );
    final decoration = base.copyWith(
      suffixIcon: IconButton(
        tooltip: '@',
        onPressed: _insertAt,
        icon: const Icon(Icons.alternate_email),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _chips(),
        TextFormField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: widget.textInputAction ?? TextInputAction.next,
          decoration: decoration,
          validator: widget.validator,
          onFieldSubmitted: widget.onFieldSubmitted,
          onChanged: (value) {
            widget.onChanged?.call(value);
            _rebuild();
          },
        ),
      ],
    );
  }
}
