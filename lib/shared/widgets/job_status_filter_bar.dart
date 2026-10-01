import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../services/settings_service.dart';
import '../../services/status_service.dart';

class JobStatusFilterBar extends StatefulWidget {
  final String selectedId;
  final ValueChanged<String> onSelected;

  const JobStatusFilterBar({
    super.key,
    required this.selectedId,
    required this.onSelected,
  });

  @override
  State<JobStatusFilterBar> createState() => _JobStatusFilterBarState();
}

class _JobStatusFilterBarState extends State<JobStatusFilterBar> {
  late final _configStream = SettingsService.watchConfig();
  late final _statusesStream = StatusService.streamDefs();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: StreamBuilder<Map<String, dynamic>>(
        stream: _configStream,
        builder: (context, configSnap) {
          final quick = SettingsService.readListQuickFilters(
            configSnap.data ?? const <String, dynamic>{},
          );
          return StreamBuilder<List<JobStatusDef>>(
            stream: _statusesStream,
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
                        selected: widget.selectedId == filter.id,
                        selectedColor: AppColors.accent,
                        checkmarkColor: Colors.black,
                        labelStyle: TextStyle(
                          color: widget.selectedId == filter.id
                              ? Colors.black
                              : Colors.black87,
                          fontWeight: widget.selectedId == filter.id
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                        onSelected: (_) => widget.onSelected(filter.id),
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
