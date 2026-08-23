import 'package:flutter/material.dart';

class SettingsPageScaffold extends StatelessWidget {
  final String title;
  final List<Widget>? actions;
  final Widget body;

  const SettingsPageScaffold({
    super.key,
    required this.title,
    this.actions,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF14557F),
        foregroundColor: Colors.white,
        toolbarHeight: 48,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: actions,
      ),
      body: body,
    );
  }
}

class SettingsGroup extends StatelessWidget {
  final List<Widget> children;

  const SettingsGroup({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(children: children),
    );
  }
}

class SettingsRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData icon;
  final Color iconColor;
  final Widget? trailing;
  final bool showDivider;
  final VoidCallback? onTap;

  const SettingsRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.icon,
    required this.iconColor,
    this.trailing,
    this.showDivider = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          onTap: onTap,
          leading: CircleAvatar(
            backgroundColor: iconColor.withValues(alpha: 0.12),
            child: Icon(icon, color: iconColor),
          ),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: subtitle == null ? null : Text(subtitle!),
          trailing: trailing,
        ),
        if (showDivider)
          const Divider(height: 1, indent: 72),
      ],
    );
  }
}

Future<String?> showSettingsTextDialog({
  required BuildContext context,
  required String title,
  required String label,
  String initialValue = '',
  TextCapitalization capitalization = TextCapitalization.sentences,
}) async {
  final controller = TextEditingController(text: initialValue);
  final saved = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        textCapitalization: capitalization,
        decoration: InputDecoration(labelText: label),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('Сохранить'),
        ),
      ],
    ),
  );
  return saved;
}

Future<String?> showSmsHeaderDialog({
  required BuildContext context,
  required String initialValue,
}) {
  return showSettingsTextDialog(
    context: context,
    title: 'Шапка SMS',
    label: 'Текст шапки',
    initialValue: initialValue,
  );
}

Future<String?> showHstNumberDialog({
  required BuildContext context,
  required String initialValue,
}) {
  return showSettingsTextDialog(
    context: context,
    title: 'HST number',
    label: 'Номер',
    initialValue: initialValue,
    capitalization: TextCapitalization.none,
  );
}
