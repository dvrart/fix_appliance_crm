import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../core/motion.dart';
import '../../models/job.dart';
import '../../models/technician.dart';
import '../../services/job_service.dart';
import '../../services/technician_service.dart';

/// Глобальный фильтр календаря и списков заявок у владельца:
/// `all` — все заказы, `owner` — только мои (владельца), либо `uid` мастера.
class TechnicianFilterState {
  TechnicianFilterState._();

  static const String all = 'all';
  static const String owner = 'owner';

  static final ValueNotifier<String> selected = ValueNotifier<String>(all);

  static bool matches(Job job, [String? filter]) {
    if (TechnicianService.isTechnician) {
      return job.isAssignedToUser(TechnicianService.currentUid);
    }
    final active = (filter ?? selected.value).trim();
    if (active.isEmpty || active == all) return true;
    if (active == owner) return !job.isAssignedToTechnician;
    return job.isAssignedToUser(active);
  }
}

/// Полоса чипов «Все · Мои · <Мастер>» у владельца.
/// Пока мастеров в настройках нет (или вошёл сам мастер) — не занимает места.
class TechnicianFilterBar extends StatelessWidget {
  const TechnicianFilterBar({super.key});

  @override
  Widget build(BuildContext context) {
    if (TechnicianService.isTechnician) return const SizedBox.shrink();
    return ValueListenableBuilder<List<TechnicianProfile>>(
      valueListenable: TechnicianService.list,
      builder: (context, techs, _) {
        if (techs.isEmpty) return const SizedBox.shrink();
        return ValueListenableBuilder<String>(
          valueListenable: TechnicianFilterState.selected,
          builder: (context, current, _) {
            final valid = current == TechnicianFilterState.all ||
                current == TechnicianFilterState.owner ||
                techs.any((t) => t.uid == current);
            final active = valid ? current : TechnicianFilterState.all;

            return Container(
              height: 36,
              color: AppColors.card,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                children: [
                  _chip(
                    label: context.tr('Все', 'All'),
                    selected: active == TechnicianFilterState.all,
                    onTap: () => TechnicianFilterState.selected.value =
                        TechnicianFilterState.all,
                  ),
                  const SizedBox(width: 6),
                  _chip(
                    label: context.tr('Мои', 'Mine'),
                    selected: active == TechnicianFilterState.owner,
                    onTap: () => TechnicianFilterState.selected.value =
                        TechnicianFilterState.owner,
                  ),
                  for (final t in techs) ...[
                    const SizedBox(width: 6),
                    _chip(
                      label: t.displayName,
                      dotColor: t.color,
                      selected: active == t.uid,
                      onTap: () =>
                          TechnicianFilterState.selected.value = t.uid,
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _chip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    Color? dotColor,
  }) {
    final bg = selected ? AppColors.primary : AppColors.surface;
    final fg = selected ? Colors.white : AppColors.ink;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (dotColor != null) ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Цветная метка имени/инициалов мастера на карточке календаря и в списке заявок.
class TechnicianBadge extends StatelessWidget {
  final String? assignedTo;
  final bool compact;
  final bool onDark;

  const TechnicianBadge({
    super.key,
    required this.assignedTo,
    this.compact = false,
    this.onDark = false,
  });

  @override
  Widget build(BuildContext context) {
    if (TechnicianService.isTechnician) return const SizedBox.shrink();
    final uid = (assignedTo ?? '').trim();
    if (uid.isEmpty || uid == kOwnerUid) return const SizedBox.shrink();

    return ValueListenableBuilder<List<TechnicianProfile>>(
      valueListenable: TechnicianService.list,
      builder: (context, _, _) {
        final tech = TechnicianService.byId(uid);
        final color = tech?.color ?? const Color(0xFF00897B);
        final text = compact
            ? (tech?.initials ?? 'М')
            : (tech?.displayName ?? context.tr('Мастер', 'Tech'));
        return Container(
          margin: const EdgeInsets.only(left: 4),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 5 : 7,
            vertical: 1.5,
          ),
          decoration: BoxDecoration(
            color: onDark ? color : color.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: onDark ? Colors.white : color,
              fontSize: compact ? 9.5 : 10.5,
              fontWeight: FontWeight.w800,
              height: 1.1,
            ),
          ),
        );
      },
    );
  }
}

/// Поле выбора исполнителя при создании новой заявки (у владельца).
class TechnicianAssigneeSelector extends StatelessWidget {
  final String? selectedUid;
  final ValueChanged<String?> onChanged;

  const TechnicianAssigneeSelector({
    super.key,
    required this.selectedUid,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (TechnicianService.isTechnician) return const SizedBox.shrink();
    return ValueListenableBuilder<List<TechnicianProfile>>(
      valueListenable: TechnicianService.list,
      builder: (context, techs, _) {
        final activeTechs = techs.where((t) => t.active).toList();
        if (activeTechs.isEmpty) return const SizedBox.shrink();
        final current = (selectedUid ?? '').trim();
        final selectedTech = activeTechs.where((t) => t.uid == current).firstOrNull;

        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _pick(context, activeTechs, current),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: selectedTech?.color ?? AppColors.primary,
                    child: Text(
                      selectedTech?.initials ?? context.tr('Я', 'Me'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.tr('Исполнитель заказа', 'Assigned technician'),
                          style: TextStyle(
                            fontSize: 11.5,
                            color: AppColors.inkMuted,
                          ),
                        ),
                        Text(
                          selectedTech?.displayName ??
                              context.tr('Я (Владелец)', 'Me (Owner)'),
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                            color: AppColors.ink,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.swap_horiz_rounded),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _pick(
    BuildContext context,
    List<TechnicianProfile> techs,
    String current,
  ) async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      sheetAnimationStyle: AppMotion.sheet,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(14),
                child: Text(
                  context.tr('Кому назначить заказ?', 'Assign job to'),
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 17,
                    color: AppColors.ink,
                  ),
                ),
              ),
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppColors.primary,
                  child: Text(
                    context.tr('Я', 'Me'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                title: Text(
                  context.tr('Я (Владелец)', 'Me (Owner)'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                trailing: current.isEmpty || current == kOwnerUid
                    ? const Icon(Icons.check_circle, color: Color(0xFF22C55E))
                    : null,
                onTap: () => Navigator.pop(sheetCtx, ''),
              ),
              for (final t in techs)
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: t.color,
                    child: Text(
                      t.initials,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  title: Text(
                    t.displayName,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    '${context.tr('Прибыль мастера', 'Tech share')}: ${t.clampedTechPercent.toStringAsFixed(0)}%',
                  ),
                  trailing: current == t.uid
                      ? const Icon(Icons.check_circle, color: Color(0xFF22C55E))
                      : null,
                  onTap: () => Navigator.pop(sheetCtx, t.uid),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (chosen == null) return;
    onChanged(chosen.isEmpty ? null : chosen);
  }
}

/// Компактная плашка исполнителя внутри карточки заявки (только у владельца).
class TechnicianJobHeaderBar extends StatelessWidget {
  final String jobId;
  final String? assignedTo;
  final ValueChanged<String?> onAssignedChanged;

  const TechnicianJobHeaderBar({
    super.key,
    required this.jobId,
    required this.assignedTo,
    required this.onAssignedChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (TechnicianService.isTechnician) return const SizedBox.shrink();
    return ValueListenableBuilder<List<TechnicianProfile>>(
      valueListenable: TechnicianService.list,
      builder: (context, techs, _) {
        if (techs.isEmpty) return const SizedBox.shrink();
        final current = (assignedTo ?? '').trim();
        final tech = (current.isEmpty || current == kOwnerUid)
            ? null
            : TechnicianService.byId(current);

        return Material(
          color: AppColors.card,
          child: InkWell(
            onTap: () => _pickAssignee(context, techs, current),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: AppColors.border)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: tech?.color ?? AppColors.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      tech != null
                          ? '${context.tr('Мастер', 'Technician')}: ${tech.displayName}'
                          : '${context.tr('Исполнитель', 'Assigned')}: ${context.tr('Я (Владелец)', 'Me (Owner)')}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: tech != null ? tech.color : AppColors.ink,
                      ),
                    ),
                  ),
                  Text(
                    context.tr('Сменить', 'Change'),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primaryOnCard,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: AppColors.primaryOnCard,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _pickAssignee(
    BuildContext context,
    List<TechnicianProfile> techs,
    String current,
  ) async {
    final activeTechs = techs.where((t) => t.active || t.uid == current).toList();
    final chosen = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      sheetAnimationStyle: AppMotion.sheet,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(14),
                child: Text(
                  context.tr('Назначить исполнителя', 'Assign technician'),
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 17,
                    color: AppColors.ink,
                  ),
                ),
              ),
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppColors.primary,
                  child: Text(
                    context.tr('Я', 'Me'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                title: Text(
                  context.tr('Я (Владелец)', 'Me (Owner)'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                trailing: current.isEmpty || current == kOwnerUid
                    ? const Icon(Icons.check_circle, color: Color(0xFF22C55E))
                    : null,
                onTap: () => Navigator.pop(sheetCtx, ''),
              ),
              for (final t in activeTechs)
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: t.color,
                    child: Text(
                      t.initials,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  title: Text(
                    t.displayName,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    '${context.tr('Мастеру', 'Tech')} ${t.clampedTechPercent.toStringAsFixed(0)}% / ${context.tr('Мне', 'Me')} ${t.ownerSharePercent.toStringAsFixed(0)}%',
                  ),
                  trailing: current == t.uid
                      ? const Icon(Icons.check_circle, color: Color(0xFF22C55E))
                      : null,
                  onTap: () => Navigator.pop(sheetCtx, t.uid),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (chosen == null) return;
    final nextVal = chosen.isEmpty ? null : chosen;
    onAssignedChanged(nextVal);
    await JobService.update(jobId, {'assignedTo': nextVal});
  }
}
