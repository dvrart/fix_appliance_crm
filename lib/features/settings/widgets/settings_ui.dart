import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../shared/widgets/selection_action_bar.dart';
import '../../../core/ui_scale.dart';
import '../../../shared/widgets/app_bar_save.dart';
import '../../../shared/widgets/dirty_leave_scope.dart';

class SettingsPageScaffold extends StatelessWidget {
  final String title;
  final Widget body;
  final List<Widget>? actions;
  final bool dirty;
  final Future<bool> Function()? onSave;
  final VoidCallback? onDiscard;

  const SettingsPageScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions,
    this.dirty = false,
    this.onSave,
    this.onDiscard,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppUiSettings.instance,
      builder: (context, _) {
        final page = Scaffold(
          backgroundColor: Colors.grey.shade100,
          appBar: AppBar(
            title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            automaticallyImplyLeading: false,
            actions: actions,
          ),
          body: body,
          bottomNavigationBar: onSave == null
              ? null
              : BottomConfirmButton(
                  dirty: dirty,
                  onPressed: () {
                    onSave!();
                  },
                ),
        );
        if (onSave == null) return page;
        return DirtyLeaveScope(
          dirty: dirty,
          onSave: onSave!,
          onDiscard: onDiscard,
          child: page,
        );
      },
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
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
      child: Column(children: children),
    );
  }
}

class SettingsRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color iconColor;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showDivider;

  const SettingsRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.iconColor,
    this.trailing,
    this.onTap,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          enabled: onTap != null || trailing != null,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor),
          ),
          title: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          subtitle: Text(subtitle, style: const TextStyle(fontSize: 13)),
          trailing: trailing ??
              (onTap == null
                  ? null
                  : const Icon(Icons.chevron_right, color: Colors.grey)),
          onTap: onTap,
        ),
        if (showDivider)
          const Divider(height: 1, indent: 64, color: Colors.black12),
      ],
    );
  }
}

class SettingsHubTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool active;
  final bool selected;

  const SettingsHubTile({
    super.key,
    required this.title,
    required this.icon,
    required this.color,
    required this.onTap,
    this.onLongPress,
    this.subtitle,
    this.active = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = selected ? AppColors.primary : (active ? color : Colors.transparent);
    final borderWidth = selected ? 2.0 : (active ? 1.5 : 0.0);
    return Material(
      color: selected ? AppColors.primary.withValues(alpha: 0.06) : Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 1.5,
      shadowColor: Colors.black12,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: borderColor, width: borderWidth),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, color: color, size: 20),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                      height: 1.15,
                      color: Colors.black87,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 9,
                        color: Colors.grey.shade600,
                        height: 1.1,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
            if (selected)
              const Positioned(
                top: 2,
                right: 2,
                child: SelectCheckbox(selected: true),
              ),
          ],
        ),
      ),
    );
  }
}

class SettingsTileSection extends StatelessWidget {
  final String title;
  final List<Widget> tiles;

  const SettingsTileSection({
    super.key,
    required this.title,
    required this.tiles,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: Colors.black87,
              ),
            ),
          ),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 4,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 0.82,
            children: tiles,
          ),
        ],
      ),
    );
  }
}
