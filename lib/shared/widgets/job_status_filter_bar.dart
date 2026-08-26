import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../services/settings_service.dart';
import '../../services/status_service.dart';

class JobStatusFilterBar extends StatelessWidget {
  final String selectedId;
  final ValueChanged<String> onSelected;

  const JobStatusFilterBar({
    super.key,
    required this.selectedId,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: StreamBuilder<Map<String, dynamic>>(
        stream: SettingsService.watchConfig(),
        builder: (context, configSnap) {
          final quick = SettingsService.readListQuickFilters(
            configSnap.data ?? const <String, dynamic>{},
          );
          return StreamBuilder<List<JobStatusDef>>(
            stream: StatusService.streamDefs(),
            builder: (context, statusSnap) {
              final filters = SettingsService.buildJobListFilters(
                statusSnap.data ?? const [],
                quick,
              );
              return ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final filter in filters)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: FilterChip(
                        label: Text(trAny(filter.label)),
                        selected: selectedId == filter.id,
                        selectedColor: AppColors.accent,
                        checkmarkColor: Colors.black,
                        labelStyle: TextStyle(
                          color: selectedId == filter.id
                              ? Colors.black
                              : Colors.black87,
                          fontWeight: selectedId == filter.id
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                        onSelected: (_) => onSelected(filter.id),
                      ),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
