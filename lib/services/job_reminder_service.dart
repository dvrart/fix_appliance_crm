import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_feedback.dart';
import '../core/constants.dart';
import '../core/l10n/app_locale.dart';
import '../core/utils/app_date_picker.dart';
import '../features/jobs/job_details/job_details_screen.dart';
import '../features/jobs/job_details/widgets/full_screen_gallery.dart';
import '../models/job.dart';
import '../shared/app_nav.dart';
import '../shared/widgets/appliance_picture.dart';
import '../shared/widgets/dispose_on_close.dart';
import 'job_service.dart';
import 'local_notification_service.dart';

/// Фото или файл, приложенный к напоминанию. Лежит в личной папке
/// приложения на телефоне — напоминание тоже личное и живёт здесь же.
class JobReminderFile {
  final String path;
  final String name;

  const JobReminderFile({required this.path, required this.name});

  static final _imageExt = RegExp(
    r'\.(jpe?g|png|gif|webp|heic|heif|bmp)$',
    caseSensitive: false,
  );

  bool get isImage => _imageExt.hasMatch(path) || _imageExt.hasMatch(name);

  Map<String, dynamic> toJson() => {'path': path, 'name': name};

  static JobReminderFile? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = (raw['path'] ?? '').toString().trim();
    if (path.isEmpty) return null;
    final name = (raw['name'] ?? '').toString().trim();
    return JobReminderFile(
      path: path,
      name: name.isEmpty ? path.split(RegExp(r'[\\/]')).last : name,
    );
  }
}

class JobReminderEntry {
  final String jobId;
  final String clientId;
  final String clientName;
  final String applianceType;
  final String city;
  final String description;
  final DateTime remindAt;
  final bool fired;

  /// Текст, который мастер написал себе в напоминание.
  final String note;
  final List<JobReminderFile> files;

  /// Мастер уже открыл сработавшее напоминание. Оно с текстом или фото
  /// остаётся в карточке (колокольчик), но из списка сработавших уходит.
  final bool seen;

  const JobReminderEntry({
    required this.jobId,
    required this.clientId,
    required this.clientName,
    required this.applianceType,
    required this.city,
    required this.description,
    required this.remindAt,
    this.fired = false,
    this.note = '',
    this.files = const [],
    this.seen = false,
  });

  bool get hasContent => note.trim().isNotEmpty || files.isNotEmpty;

  JobReminderEntry copyWith({
    DateTime? remindAt,
    bool? fired,
    String? clientName,
    String? applianceType,
    String? city,
    String? description,
    String? note,
    List<JobReminderFile>? files,
    bool? seen,
  }) {
    return JobReminderEntry(
      jobId: jobId,
      clientId: clientId,
      clientName: clientName ?? this.clientName,
      applianceType: applianceType ?? this.applianceType,
      city: city ?? this.city,
      description: description ?? this.description,
      remindAt: remindAt ?? this.remindAt,
      fired: fired ?? this.fired,
      note: note ?? this.note,
      files: files ?? this.files,
      seen: seen ?? this.seen,
    );
  }

  Map<String, dynamic> toJson() => {
    'jobId': jobId,
    'clientId': clientId,
    'clientName': clientName,
    'applianceType': applianceType,
    'city': city,
    'description': description,
    'remindAt': remindAt.toIso8601String(),
    'fired': fired,
    if (note.trim().isNotEmpty) 'note': note.trim(),
    if (files.isNotEmpty) 'files': [for (final f in files) f.toJson()],
    if (seen) 'seen': true,
  };

  factory JobReminderEntry.fromJson(Map<String, dynamic> map) {
    final dt = DateTime.tryParse((map['remindAt'] ?? '').toString());
    final rawFiles = map['files'];
    return JobReminderEntry(
      jobId: (map['jobId'] ?? '').toString().trim(),
      clientId: (map['clientId'] ?? '').toString().trim(),
      clientName: (map['clientName'] ?? '').toString().trim(),
      applianceType: (map['applianceType'] ?? '').toString().trim(),
      city: (map['city'] ?? '').toString().trim(),
      description: (map['description'] ?? '').toString().trim(),
      remindAt: (dt ?? DateTime.now()).toLocal(),
      fired: map['fired'] == true,
      note: (map['note'] ?? '').toString().trim(),
      files: rawFiles is List
          ? [
              for (final raw in rawFiles) ?JobReminderFile.fromJson(raw),
            ]
          : const [],
      seen: map['seen'] == true,
    );
  }
}

/// Личные напоминания мастера по рабочим карточкам:
/// срабатывают в выбранный день и время в шторке телефона и в приложении,
/// а также зажигают колокольчик в правом верхнем углу.
class JobReminderService {
  static const _prefsKey = 'job_reminders_v1';
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);
  static final Map<String, JobReminderEntry> _entries = {};
  static Timer? _timer;
  static bool _started = false;

  static Future<void> start() async {
    if (_started) return;
    _started = true;
    await _loadFromPrefs();
    await _tick();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_tick());
    });
  }

  static Future<void> _loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.trim().isEmpty) return;
      final decoded = json.decode(raw);
      if (decoded is! List) return;
      _entries.clear();
      for (final item in decoded) {
        if (item is Map) {
          final entry = JobReminderEntry.fromJson(
            Map<String, dynamic>.from(item),
          );
          if (entry.jobId.isNotEmpty) {
            _entries[entry.jobId] = entry;
          }
        }
      }
      revision.value++;
    } catch (_) {}
  }

  static Future<void> _saveToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = [for (final e in _entries.values) e.toJson()];
      await prefs.setString(_prefsKey, json.encode(list));
    } catch (_) {}
  }

  static DateTime? reminderFor(String jobId, [Map<String, dynamic>? jobData]) {
    final local = _entries[jobId];
    if (local != null) return local.remindAt;
    if (jobData != null) {
      final raw = (jobData['reminderAt'] ?? '').toString().trim();
      if (raw.isNotEmpty) {
        return DateTime.tryParse(raw)?.toLocal();
      }
    }
    return null;
  }

  static bool isDue(String jobId, [Map<String, dynamic>? jobData]) {
    final dt = reminderFor(jobId, jobData);
    if (dt == null) return false;
    return !dt.isAfter(DateTime.now());
  }

  static JobReminderEntry? entryFor(String jobId) => _entries[jobId];

  /// Все сработавшие напоминания (время которых уже наступило), кроме тех,
  /// что мастер уже открыл.
  static List<JobReminderEntry> dueReminders([List<Job> jobs = const []]) {
    final now = DateTime.now();
    final byId = <String, JobReminderEntry>{};
    for (final entry in _entries.values) {
      if (!entry.remindAt.isAfter(now) && !entry.seen) {
        byId[entry.jobId] = entry;
      }
    }
    for (final job in jobs) {
      if (job.isDeleted) continue;
      // Своя запись на телефоне главнее копии в заявке.
      if (_entries.containsKey(job.id)) continue;
      final dt = job.reminderAt?.toLocal();
      if (dt == null || dt.isAfter(now)) continue;
      byId.putIfAbsent(
        job.id,
        () => JobReminderEntry(
          jobId: job.id,
          clientId: job.clientId,
          clientName: job.contactName,
          applianceType: job.applianceType,
          city: job.city ?? '',
          description: job.description,
          remindAt: dt,
          fired: true,
        ),
      );
    }
    final list = byId.values.toList()
      ..sort((a, b) => b.remindAt.compareTo(a.remindAt));
    return list;
  }

  static Future<void> _tick() async {
    final now = DateTime.now();
    var changed = false;
    for (final entry in _entries.values.toList()) {
      if (!entry.fired && !entry.remindAt.isAfter(now)) {
        final updated = entry.copyWith(fired: true);
        _entries[entry.jobId] = updated;
        changed = true;
        AppFeedback.pleasant();
        final title = _notificationTitle(updated);
        final body = _notificationBody(updated);
        unawaited(
          LocalNotificationService.showJobReminderNow(
            jobId: updated.jobId,
            clientId: updated.clientId,
            title: title,
            body: body,
            applianceType: updated.applianceType,
            clientName: updated.clientName,
            city: updated.city,
          ),
        );
      }
    }
    if (changed) {
      await _saveToPrefs();
      revision.value++;
    }
  }

  static String _notificationTitle(JobReminderEntry entry) {
    final who = entry.clientName.trim().isNotEmpty
        ? entry.clientName.trim()
        : 'Рабочая карточка'.tr;
    return '${'Напоминание'.tr}: $who';
  }

  static String _notificationBody(JobReminderEntry entry) {
    final parts = <String>[
      // Свой текст мастера — первым: ради него напоминание и ставили.
      if (entry.note.trim().isNotEmpty) entry.note.trim(),
      if (entry.files.isNotEmpty)
        '📎 ${entry.files.length}',
      if (entry.applianceType.trim().isNotEmpty &&
          entry.applianceType.trim() != 'Техника')
        trAny(entry.applianceType.trim()),
      if (entry.city.trim().isNotEmpty) entry.city.trim(),
      if (entry.description.trim().isNotEmpty &&
          entry.description.trim() != 'Нет описания')
        entry.description.trim(),
    ];
    return parts.isEmpty
        ? 'Откройте рабочую карточку'.tr
        : parts.join(' · ');
  }

  static Future<void> setReminder({
    required String jobId,
    required String clientId,
    required Map<String, dynamic> jobData,
    required DateTime remindAt,
    String note = '',
    List<JobReminderFile> files = const [],
  }) async {
    String clientName = '';
    String applianceType = '';
    String city = '';
    String description = '';
    try {
      final parsed = Job.fromMap(jobData, jobId);
      clientName = parsed.contactName;
      applianceType = parsed.applianceType;
      city = parsed.city ?? '';
      description = parsed.description;
    } catch (_) {
      clientName = (jobData['clientName'] ?? '').toString().trim();
      applianceType = (jobData['applianceType'] ?? '').toString().trim();
      city = (jobData['city'] ?? '').toString().trim();
      description = (jobData['description'] ?? '').toString().trim();
    }

    final now = DateTime.now();
    final fired = !remindAt.isAfter(now);
    final entry = JobReminderEntry(
      jobId: jobId,
      clientId: clientId,
      clientName: clientName,
      applianceType: applianceType,
      city: city,
      description: description,
      remindAt: remindAt,
      fired: fired,
      note: note.trim(),
      files: List.unmodifiable(files),
    );
    // Убранные из напоминания файлы больше никому не нужны.
    final kept = {for (final f in files) f.path};
    _deleteFiles([
      for (final f in _entries[jobId]?.files ?? const <JobReminderFile>[])
        if (!kept.contains(f.path)) f,
    ]);
    _entries[jobId] = entry;
    await _saveToPrefs();
    revision.value++;

    unawaited(
      JobService.update(jobId, {
        'reminderAt': remindAt.toIso8601String(),
      }),
    );

    await LocalNotificationService.scheduleJobReminder(
      jobId: jobId,
      clientId: clientId,
      title: _notificationTitle(entry),
      body: _notificationBody(entry),
      remindAt: remindAt,
      applianceType: applianceType,
      clientName: clientName,
      city: city,
    );
  }

  static Future<void> clearReminder(String jobId) async {
    final removed = _entries.remove(jobId);
    if (removed != null) _deleteFiles(removed.files);
    await _saveToPrefs();
    revision.value++;
    unawaited(
      JobService.update(jobId, {
        'reminderAt': null,
      }),
    );
    await LocalNotificationService.cancelJobReminder(jobId);
  }

  /// Мастер открыл сработавшее напоминание. Если в нём есть текст или файлы,
  /// оно остаётся в колокольчике карточки, чтобы их можно было прочитать и
  /// посмотреть; пустое — убирается, как раньше.
  static Future<void> markOpened(String jobId) async {
    final entry = _entries[jobId];
    if (entry == null || !entry.hasContent) {
      await clearReminder(jobId);
      return;
    }
    if (!entry.remindAt.isAfter(DateTime.now())) {
      _entries[jobId] = entry.copyWith(seen: true, fired: true);
      await _saveToPrefs();
      revision.value++;
    }
    await LocalNotificationService.cancelJobReminder(jobId);
  }

  static void _deleteFiles(List<JobReminderFile> files) {
    for (final file in files) {
      unawaited(
        File(file.path).delete().then((_) {}, onError: (Object _) {}),
      );
    }
  }

  static Future<Directory> _filesDir(String jobId) async {
    final base = await getApplicationDocumentsDirectory();
    final safe = jobId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final dir = Directory('${base.path}/job_reminders/$safe');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<JobReminderFile?> _storeBytes(
    String jobId,
    List<int> bytes,
    String name,
  ) async {
    if (bytes.isEmpty) return null;
    final dir = await _filesDir(jobId);
    final cleanName = name.trim().isEmpty ? 'file' : name.trim();
    final safe = cleanName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final file = File(
      '${dir.path}/${DateTime.now().millisecondsSinceEpoch}_$safe',
    );
    await file.writeAsBytes(bytes, flush: true);
    return JobReminderFile(path: file.path, name: cleanName);
  }

  static Future<JobReminderFile?> _pickPhoto(
    String jobId,
    ImageSource source,
  ) async {
    final picked = await ImagePicker().pickImage(
      source: source,
      imageQuality: 85,
      maxWidth: 1920,
      maxHeight: 1920,
    );
    if (picked == null) return null;
    return _storeBytes(jobId, await picked.readAsBytes(), picked.name);
  }

  static Future<JobReminderFile?> _pickAnyFile(String jobId) async {
    final picked = await FilePicker.pickFile();
    if (picked == null) return null;
    return _storeBytes(jobId, await picked.readAsBytes(), picked.name);
  }

  static Future<void> _openFile(
    BuildContext context,
    List<JobReminderFile> files,
    JobReminderFile file,
  ) async {
    if (file.isImage) {
      final images = files.where((f) => f.isImage).toList();
      await Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(
          builder: (_) => FullScreenGallery(
            images: [
              for (final f in images) {'localPath': f.path},
            ],
            initialIndex: images.indexOf(file).clamp(0, images.length - 1),
          ),
        ),
      );
      return;
    }
    // Не фото (PDF и т.п.) — отдаём системе: она предложит, чем открыть.
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path, name: file.name)], title: file.name),
      );
    } catch (_) {
      if (context.mounted) {
        AppFeedback.toast(context, 'Файл не открылся'.tr);
      }
    }
  }

  static Widget _fileThumb(
    BuildContext context, {
    required List<JobReminderFile> files,
    required JobReminderFile file,
    VoidCallback? onRemove,
    double size = 56,
  }) {
    final radius = BorderRadius.circular(10);
    final Widget picture = file.isImage
        ? Image.file(
            File(file.path),
            width: size,
            height: size,
            fit: BoxFit.cover,
            cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).ceil(),
            errorBuilder: (_, _, _) => Icon(
              Icons.broken_image_outlined,
              color: AppColors.inkMuted,
            ),
          )
        : Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.insert_drive_file_outlined,
                  size: size * 0.4,
                  color: AppColors.primaryOnCard,
                ),
                Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 9, color: AppColors.inkMuted),
                ),
              ],
            ),
          );
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Material(
              color: AppColors.cardMuted,
              borderRadius: radius,
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => _openFile(context, files, file),
                child: Center(child: picture),
              ),
            ),
          ),
          if (onRemove != null)
            Positioned(
              top: -6,
              right: -6,
              child: GestureDetector(
                onTap: onRemove,
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: const BoxDecoration(
                    color: Color(0xFFD32F2F),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close, size: 14, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Лист выбора дня и времени напоминания для рабочей карточки.
  static Future<DateTime?> showPickerSheet(
    BuildContext context, {
    required String jobId,
    required String clientId,
    required Map<String, dynamic> jobData,
    ValueChanged<DateTime?>? onChanged,
  }) async {
    final existing = reminderFor(jobId, jobData);
    final now = DateTime.now();
    final defaultTime = existing != null && existing.isAfter(now)
        ? existing
        : DateTime(
            now.year,
            now.month,
            now.day,
            (now.hour + 1).clamp(0, 23),
            0,
          );
    var current = defaultTime;
    final entry = _entries[jobId];
    final noteCtrl = TextEditingController(text: entry?.note ?? '');
    final files = <JobReminderFile>[...?entry?.files];
    // Файлы, скопированные в этом окне: если окно закрыли без «Готово»,
    // они никому не нужны.
    final added = <JobReminderFile>[];
    var saved = false;
    var picking = false;

    final result = await showModalBottomSheet<DateTime>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) {
        return DisposeOnClose(
          disposables: [noteCtrl],
          child: StatefulBuilder(
          builder: (context, setSheet) {
            final stamp = DateFormat(
              'd MMM, HH:mm',
              AppLocale.instance.dateLocale,
            ).format(current);
            final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;

            Future<void> attach(
              Future<JobReminderFile?> Function() pick,
            ) async {
              if (picking) return;
              setSheet(() => picking = true);
              try {
                final file = await pick();
                if (file != null) {
                  added.add(file);
                  files.add(file);
                }
              } catch (_) {
                if (context.mounted) {
                  AppFeedback.toast(context, 'Не удалось добавить файл'.tr);
                }
              } finally {
                if (context.mounted) setSheet(() => picking = false);
              }
            }

            Widget attachButton(IconData icon, String label, VoidCallback onTap) {
              return Expanded(
                child: OutlinedButton.icon(
                  onPressed: picking ? null : onTap,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF7B1FA2),
                    side: BorderSide(
                      color: const Color(0xFF7B1FA2).withValues(alpha: 0.45),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    minimumSize: const Size.fromHeight(40),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: Icon(icon, size: 18),
                  label: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              );
            }

            return SafeArea(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  16,
                  10,
                  16,
                  12 + MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                          color: AppColors.border,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        const Icon(
                          Icons.notifications_active_outlined,
                          color: Color(0xFF7B1FA2),
                          size: 22,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            context.tr(
                              'Напомнить о карточке',
                              'Remind about job',
                            ),
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: AppColors.ink,
                            ),
                          ),
                        ),
                        Text(
                          stamp,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: AppColors.primaryOnCard,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: noteCtrl,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: context.tr(
                          'Текст напоминания (необязательно)',
                          'Reminder text (optional)',
                        ),
                        prefixIcon: const Icon(Icons.edit_note_rounded),
                        isDense: true,
                        filled: true,
                        fillColor: AppColors.cardMuted,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (files.isNotEmpty) ...[
                      SizedBox(
                        height: 64,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.only(top: 6, right: 6),
                          itemCount: files.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 10),
                          itemBuilder: (context, index) {
                            final file = files[index];
                            return _fileThumb(
                              context,
                              files: files,
                              file: file,
                              onRemove: () => setSheet(() {
                                files.remove(file);
                                if (added.remove(file)) _deleteFiles([file]);
                              }),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    Row(
                      children: [
                        attachButton(
                          Icons.photo_camera_outlined,
                          context.tr('Снять', 'Camera'),
                          () => attach(
                            () => _pickPhoto(jobId, ImageSource.camera),
                          ),
                        ),
                        const SizedBox(width: 6),
                        attachButton(
                          Icons.photo_library_outlined,
                          context.tr('Фото', 'Photo'),
                          () => attach(
                            () => _pickPhoto(jobId, ImageSource.gallery),
                          ),
                        ),
                        const SizedBox(width: 6),
                        attachButton(
                          Icons.attach_file_rounded,
                          context.tr('Файл', 'File'),
                          () => attach(() => _pickAnyFile(jobId)),
                        ),
                      ],
                    ),
                    if (picking)
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: LinearProgressIndicator(minHeight: 2),
                      ),
                    // С открытой клавиатурой календарь прячется: видно поле
                    // и время в заголовке, кнопка «Готово» не уезжает.
                    if (!keyboardOpen) ...[
                      const SizedBox(height: 6),
                      AppDateTimePanel(
                        value: current,
                        firstDate: DateTime(now.year, now.month, now.day),
                        lastDate: now.add(const Duration(days: 365 * 2)),
                        onChanged: (v) => setSheet(() => current = v),
                      ),
                    ],
                    const SizedBox(height: 8),
                    if (existing != null) ...[
                      SizedBox(
                        height: 44,
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            await clearReminder(jobId);
                            onChanged?.call(null);
                            if (sheetContext.mounted) {
                              Navigator.pop(sheetContext);
                            }
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFFD32F2F),
                            side: const BorderSide(color: Color(0xFFD32F2F)),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          icon: const Icon(Icons.notifications_off_outlined),
                          label: Text(
                            context.tr(
                              'Убрать напоминание',
                              'Remove reminder',
                            ),
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    AppSheetConfirmButton(
                      onPressed: picking
                          ? null
                          : () async {
                              saved = true;
                              await setReminder(
                                jobId: jobId,
                                clientId: clientId,
                                jobData: jobData,
                                remindAt: current,
                                note: noteCtrl.text,
                                files: files,
                              );
                              onChanged?.call(current);
                              if (sheetContext.mounted) {
                                Navigator.pop(sheetContext, current);
                              }
                            },
                    ),
                  ],
                ),
              ),
            );
          },
          ),
        );
      },
    );
    if (!saved) _deleteFiles(added);
    return result;
  }

  /// Открывает список сработавших напоминаний из колокольчика в правом верхнем углу.
  static Future<void> showDueRemindersSheet(
    BuildContext hostContext, [
    List<Job> jobs = const [],
  ]) {
    return showModalBottomSheet<void>(
      context: hostContext,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) {
        return ValueListenableBuilder<int>(
          valueListenable: revision,
          builder: (context, _, _) {
            final items = dueReminders(jobs);
            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.72,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 8),
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade400,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 12, 4),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.notifications_active_rounded,
                            color: Color(0xFF7B1FA2),
                            size: 24,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              context.tr('Напоминания', 'Reminders'),
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 20,
                              ),
                            ),
                          ),
                          if (items.isNotEmpty)
                            TextButton(
                              onPressed: () async {
                                for (final item in items) {
                                  await clearReminder(item.jobId);
                                }
                                if (sheetContext.mounted) {
                                  Navigator.pop(sheetContext);
                                }
                              },
                              child: Text(context.tr('Очистить', 'Clear all')),
                            ),
                        ],
                      ),
                    ),
                    const Divider(height: 12),
                    if (items.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          context.tr(
                            'Нет активных напоминаний',
                            'No active reminders',
                          ),
                          style: TextStyle(color: AppColors.inkMuted),
                        ),
                      )
                    else
                      Flexible(
                        child: ListView.builder(
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                          itemCount: items.length,
                          itemBuilder: (context, index) => _buildDueReminderTile(
                            context: context,
                            hostContext: hostContext,
                            sheetContext: sheetContext,
                            item: items[index],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  static Widget _buildDueReminderTile({
    required BuildContext context,
    required BuildContext hostContext,
    required BuildContext sheetContext,
    required JobReminderEntry item,
  }) {
    final timeLabel = DateFormat(
      'd MMM, HH:mm',
      AppLocale.instance.dateLocale,
    ).format(item.remindAt);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () async {
            HapticFeedback.selectionClick();
            await markOpened(item.jobId);
            if (sheetContext.mounted && Navigator.of(sheetContext).canPop()) {
              Navigator.pop(sheetContext);
            }
            await Future<void>.delayed(const Duration(milliseconds: 220));
            final job = await JobService.getById(item.jobId);
            if (job == null || !hostContext.mounted) return;
            await AppNav.openCard(
              hostContext,
              key: AppNav.jobKey(job.id),
              builder: (_) => JobDetailsScreen(
                jobId: job.id,
                clientId: job.clientId,
                jobData: job.toMap(),
              ),
            );
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFF7B1FA2).withValues(alpha: 0.4),
              ),
            ),
            child: Row(
              children: [
                AppliancePicture(
                  type: item.applianceType.isEmpty
                      ? 'Техника'
                      : item.applianceType,
                  size: 36,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              item.clientName.isEmpty
                                  ? 'Клиент'.tr
                                  : item.clientName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 14,
                                color: AppColors.ink,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            timeLabel,
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF7B1FA2),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _notificationBody(item),
                        maxLines: item.note.trim().isNotEmpty ? 3 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: item.note.trim().isNotEmpty
                              ? AppColors.ink
                              : AppColors.inkMuted,
                        ),
                      ),
                      if (item.files.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final file in item.files)
                              _fileThumb(
                                context,
                                files: item.files,
                                file: file,
                                size: 44,
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18, color: Colors.grey),
                  tooltip: 'Убрать'.tr,
                  onPressed: () => clearReminder(item.jobId),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
