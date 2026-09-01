import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../core/l10n/app_locale.dart';
import '../../core/utils/app_time_picker.dart';
import '../../models/calendar_event.dart';
import '../../services/calendar_event_service.dart';
import '../../shared/widgets/confirm_action_sheet.dart';

Future<void> showCalendarEventSheet(
  BuildContext context, {
  CalendarEvent? event,
  DateTime? startAt,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (sheetContext) {
      return _CalendarEventSheet(event: event, startAt: startAt);
    },
  );
}

class _CalendarEventSheet extends StatefulWidget {
  final CalendarEvent? event;
  final DateTime? startAt;

  const _CalendarEventSheet({this.event, this.startAt});

  @override
  State<_CalendarEventSheet> createState() => _CalendarEventSheetState();
}

class _CalendarEventSheetState extends State<_CalendarEventSheet> {
  late final TextEditingController _title;
  late DateTime _startAt;
  int _duration = 60;
  String _photoUrl = '';
  String? _localPhoto;
  bool _busy = false;
  CalendarEventPriority _priority = CalendarEventPriority.defaultValue;

  @override
  void initState() {
    super.initState();
    final event = widget.event;
    _title = TextEditingController(text: event?.title ?? '');
    _startAt = event?.startAt ?? widget.startAt ?? DateTime.now();
    _duration = event?.durationMinutes ?? 60;
    _photoUrl = event?.photoUrl ?? '';
    _priority = event?.priority ?? CalendarEventPriority.defaultValue;
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _startAt,
      firstDate: DateTime(2020),
      lastDate: DateTime(2040),
    );
    if (date == null || !mounted) return;
    setState(() {
      _startAt = DateTime(
        date.year,
        date.month,
        date.day,
        _startAt.hour,
        _startAt.minute,
      );
    });
  }

  Future<void> _pickTime() async {
    final time = await showAppTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _startAt.hour, minute: _startAt.minute),
      helpText: 'Время'.tr,
    );
    if (time == null || !mounted) return;
    setState(() {
      _startAt = DateTime(
        _startAt.year,
        _startAt.month,
        _startAt.day,
        time.hour,
        time.minute,
      );
    });
  }

  Future<void> _pickPhoto() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 78,
      maxWidth: 1600,
    );
    if (picked == null || !mounted) return;
    setState(() => _localPhoto = picked.path);
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Напишите текст мероприятия'.tr)),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      var id = widget.event?.id ?? '';
      id = await CalendarEventService.save(
        CalendarEvent(
          id: id,
          title: title,
          startAt: _startAt,
          durationMinutes: _duration,
          photoUrl: _photoUrl,
          priority: _priority,
        ),
      );
      var photoUrl = _photoUrl;
      if (_localPhoto != null) {
        photoUrl = await CalendarEventService.uploadPhoto(
          eventId: id,
          localPath: _localPhoto!,
        );
        await CalendarEventService.save(
          CalendarEvent(
            id: id,
            title: title,
            startAt: _startAt,
            durationMinutes: _duration,
            photoUrl: photoUrl,
            priority: _priority,
          ),
        );
      }
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${'Не удалось сохранить'.tr}: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final id = widget.event?.id ?? '';
    if (id.isEmpty) {
      Navigator.pop(context);
      return;
    }
    final action = await showConfirmActionSheet(
      context,
      title: 'Удалить мероприятие?'.tr,
      saveLabel: 'Оставить'.tr,
      discardLabel: 'Удалить'.tr,
      showDiscard: true,
    );
    if (action != UnsavedChangesAction.discard || !mounted) return;
    await CalendarEventService.delete(id);
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final dateLabel = DateFormat(
      'd MMMM yyyy',
      AppLocale.instance.dateLocale,
    ).format(_startAt);
    final timeLabel = DateFormat('HH:mm').format(_startAt);
    final preview = _localPhoto ?? _photoUrl;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 12, 20, 16 + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              widget.event == null
                  ? 'Новое мероприятие'.tr
                  : 'Мероприятие'.tr,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: Color(0xFF14557F),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              minLines: 2,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Текст'.tr,
                border: const OutlineInputBorder(),
                filled: true,
                fillColor: Colors.grey.shade50,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Приоритет'.tr,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Colors.grey.shade700,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final item in CalendarEventPriority.values) ...[
                  if (item != CalendarEventPriority.values.first)
                    const SizedBox(width: 8),
                  Expanded(
                    child: _PriorityFlagChip(
                      priority: item,
                      selected: _priority == item,
                      onTap: _busy
                          ? null
                          : () => setState(() => _priority = item),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event, color: Color(0xFF14557F)),
              title: Text(dateLabel),
              subtitle: Text('День'.tr),
              onTap: _busy ? null : _pickDate,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule, color: Color(0xFF14557F)),
              title: Text(timeLabel),
              subtitle: Text('Время'.tr),
              onTap: _busy ? null : _pickTime,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.timer_outlined, color: Color(0xFF14557F)),
              title: Text('$_duration ${'мин'.tr}'),
              subtitle: Text('Длительность'.tr),
              trailing: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: _duration,
                  items: [
                    for (final m in const [30, 45, 60, 90, 120])
                      DropdownMenuItem(value: m, child: Text('$m ${'мин'.tr}')),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) {
                          if (value == null) return;
                          setState(() => _duration = value);
                        },
                ),
              ),
            ),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _busy ? null : _pickPhoto,
              child: Container(
                height: 140,
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.black12),
                  image: preview.isEmpty
                      ? null
                      : DecorationImage(
                          image: preview.startsWith('http')
                              ? NetworkImage(preview)
                              : FileImage(File(preview)) as ImageProvider,
                          fit: BoxFit.cover,
                        ),
                ),
                child: preview.isEmpty
                    ? Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add_a_photo_outlined,
                              color: Colors.grey.shade600, size: 32),
                          const SizedBox(height: 6),
                          Text('Фото'.tr, style: TextStyle(color: Colors.grey.shade700)),
                        ],
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 20),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: LinearProgressIndicator(),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                RoundActionButton(
                  color: const Color(0xFFE53935),
                  icon: Icons.close_rounded,
                  tooltip: widget.event == null ? 'Отмена'.tr : 'Удалить'.tr,
                  onTap: _busy
                      ? () {}
                      : () {
                          if (widget.event == null) {
                            Navigator.pop(context);
                          } else {
                            _delete();
                          }
                        },
                ),
                RoundActionButton(
                  color: const Color(0xFF22C55E),
                  icon: Icons.check_rounded,
                  tooltip: 'Сохранить'.tr,
                  onTap: _busy ? () {} : _save,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PriorityFlagChip extends StatelessWidget {
  final CalendarEventPriority priority;
  final bool selected;
  final VoidCallback? onTap;

  const _PriorityFlagChip({
    required this.priority,
    required this.selected,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = priority.color;
    return Material(
      color: selected ? color.withValues(alpha: 0.14) : Colors.grey.shade50,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? color : Colors.black12,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            children: [
              Icon(
                selected ? Icons.flag : Icons.flag_outlined,
                color: color,
                size: 26,
              ),
              const SizedBox(height: 4),
              Text(
                priority.labelRu.tr,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.15,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: selected ? color : Colors.grey.shade800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
