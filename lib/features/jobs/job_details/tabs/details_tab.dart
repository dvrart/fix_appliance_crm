import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../../core/constants.dart';
import '../../../../core/utils/app_time_picker.dart';
import '../../../../models/job.dart';
import '../../../../services/services.dart';
import '../../../clients/client_details_screen.dart';
import '../../../calls/call_screen.dart';
import '../../../messages/conversation_screen.dart';
import '../job_details_controller.dart';
import '../job_details_screen.dart';
import '../editors/job_tile_editors.dart';
import '../editors/call_recording_page.dart';
import '../editors/source_email_page.dart';
import '../../../../core/l10n/app_locale.dart';
import '../../../../shared/widgets/keyboard_safe.dart';
import '../../../../shared/widgets/visit_confirm_badge.dart';
import '../../../../shared/widgets/appliance_picture.dart';
import '../../../../widgets/smart_address_picker.dart';
import '../../../../shared/widgets/email_field.dart';

class DetailsTab extends StatefulWidget {
  final JobDetailsController controller;

  const DetailsTab({super.key, required this.controller});

  @override
  State<DetailsTab> createState() => _DetailsTabState();
}

class _DetailsTabState extends State<DetailsTab> {
  JobDetailsController get ctrl => widget.controller;
  List<Job> _relatedJobs = const [];
  Job? _originalJob;

  @override
  void initState() {
    super.initState();
    ctrl.addListener(_onControllerChange);
    _loadRelatedJobs();
  }

  @override
  void dispose() {
    ctrl.removeListener(_onControllerChange);
    super.dispose();
  }

  void _onControllerChange() {
    if (mounted) setState(() {});
  }

  Future<JobChatContact?> _pickContact(String title) async {
    final contacts = ctrl.chatContacts;
    if (contacts.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Нет телефона'.tr)));
      return null;
    }
    if (contacts.length == 1) return contacts.first;
    return showModalBottomSheet<JobChatContact>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
              ),
              for (final contact in contacts)
                ListTile(
                  leading: Icon(
                    contact.id == 'site' ? Icons.location_on : Icons.person,
                    color: AppColors.primary,
                  ),
                  title: Text(contact.displayName),
                  subtitle: Text('${contact.label} · ${contact.phone}'),
                  onTap: () => Navigator.pop(context, contact),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _callSelected() async {
    final contact = await _pickContact('Кому позвонить?'.tr);
    if (contact == null || !mounted) return;
    await CallScreen.open(
      context,
      phoneNumber: contact.phone,
      contactName: contact.displayName,
      jobId: ctrl.jobId,
    );
  }

  Future<void> _smsSelected() async {
    final contact = await _pickContact('Кому написать?'.tr);
    if (contact == null || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ConversationScreen(
          phoneNumber: contact.phone,
          email: contact.email.contains('@') ? contact.email : null,
          contactName: contact.displayName,
          clientId: ctrl.clientId,
          jobId: ctrl.jobId,
          recipients: [
            for (final item in ctrl.chatContacts)
              ConversationPeer(
                id: item.id,
                label: item.label,
                name: item.displayName,
                phone: item.phone,
                email: item.email,
              ),
          ],
        ),
      ),
    );
  }

  void _showStatusMenu() {
    final hostContext = context;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return StreamBuilder<List<String>>(
          stream: StatusService.streamAll(),
          builder: (context, snapshot) {
            final statuses = StatusService.idsForStatusMenu(
              snapshot.data ?? JobStatuses.all,
              current: ctrl.currentStatus,
            );
            final maxHeight = MediaQuery.of(context).size.height * 0.7;
            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Выберите статус'.tr,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                              color: Color(0xFF1A1A1A),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '«Перенос» ставится сам, когда после запчасти вы назначаете новый визит.'
                                .tr,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF3D3D3D),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: statuses.length,
                        itemBuilder: (context, index) {
                          final status = statuses[index];
                          final isSelected = ctrl.currentStatus == status;
                          return ListTile(
                            leading: Icon(
                              isSelected
                                  ? Icons.check_circle
                                  : Icons.circle_outlined,
                              color: StatusService.colorOf(status),
                            ),
                            title: Text(
                              trAny(StatusService.labelOf(status)),
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF1A1A1A),
                              ),
                            ),
                            selected: isSelected,
                            onTap: () async {
                              Navigator.pop(sheetContext);
                              if (_shouldCompleteJob(status)) {
                                await _completeJobFlow();
                              } else {
                                await ctrl.updateStatus(status);
                                if (status == JobStatuses.waitingPart &&
                                    hostContext.mounted) {
                                  ScaffoldMessenger.of(
                                    hostContext,
                                  ).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Дата следующего визита не нужна, пока нет запчасти. Когда она приедет — добавьте визит. Заявка в очереди запчастей (фургон).'
                                            .tr,
                                      ),
                                    ),
                                  );
                                }
                              }
                            },
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showPriorityMenu() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Выберите приоритет'.tr,
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
              ),
              ...JobPriorities.all.map((priority) {
                final isSelected = ctrl.currentPriority == priority;
                return ListTile(
                  leading: Icon(
                    isSelected ? Icons.check_circle : Icons.circle_outlined,
                    color: JobPriorities.getColor(priority),
                  ),
                  title: Text(trAny(priority)),
                  selected: isSelected,
                  onTap: () {
                    ctrl.updatePriority(priority);
                    Navigator.pop(context);
                  },
                );
              }),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  Future<void> _editVisit([JobVisit? existing]) async {
    final now = DateTime.now();
    final last = ctrl.visits.isNotEmpty ? ctrl.visits.last.startAt : now;
    var startAt =
        existing?.startAt ??
        DateTime(
          last.year,
          last.month,
          last.day,
          last.hour,
          last.minute,
        ).add(existing == null ? const Duration(days: 7) : Duration.zero);
    if (existing == null && startAt.isBefore(now)) {
      startAt = now.add(const Duration(days: 1));
    }
    var duration = existing?.durationMinutes ?? ctrl.durationMinutes;
    var note = existing?.note ?? '';
    var outcome = existing?.outcome ?? JobVisit.scheduled;
    final noteCtrl = TextEditingController(text: note);

    const presets = ['Диагностика', 'Установка', 'Повторный выезд'];

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return KeyboardAvoidingSheet(
          child: StatefulBuilder(
            builder: (context, setSheet) {
              Future<void> pickDate() async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: startAt.isBefore(now) ? now : startAt,
                  firstDate: DateTime(now.year - 1),
                  lastDate: DateTime(now.year + 2),
                );
                if (picked == null) return;
                setSheet(() {
                  startAt = DateTime(
                    picked.year,
                    picked.month,
                    picked.day,
                    startAt.hour,
                    startAt.minute,
                  );
                });
              }

              Future<void> pickTime() async {
                final picked = await showAppTimePicker(
                  context: context,
                  initialTime: TimeOfDay.fromDateTime(startAt),
                  helpText: 'Выберите время'.tr,
                );
                if (picked == null) return;
                setSheet(() {
                  startAt = DateTime(
                    startAt.year,
                    startAt.month,
                    startAt.day,
                    picked.hour,
                    picked.minute,
                  );
                });
              }

              return SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        existing == null ? 'Добавить визит'.tr : 'Визит'.tr,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 12),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          Icons.calendar_month,
                          color: AppColors.primary,
                        ),
                        title: Text(
                          DateFormat(
                            'd MMMM yyyy',
                            AppLocale.instance.dateLocale,
                          ).format(startAt),
                        ),
                        trailing: const Icon(
                          Icons.edit,
                          size: 18,
                          color: Colors.grey,
                        ),
                        onTap: pickDate,
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.schedule, color: AppColors.primary),
                        title: Text(DateFormat('HH:mm').format(startAt)),
                        trailing: const Icon(
                          Icons.edit,
                          size: 18,
                          color: Colors.grey,
                        ),
                        onTap: pickTime,
                      ),
                      Row(
                        children: [
                          Icon(Icons.timer_outlined, color: AppColors.primary),
                          const SizedBox(width: 12),
                          Expanded(child: Text('Длительность визита'.tr)),
                          DropdownButton<int>(
                            value:
                                const [
                                  30,
                                  45,
                                  60,
                                  90,
                                  120,
                                  180,
                                ].contains(duration)
                                ? duration
                                : 60,
                            underline: const SizedBox.shrink(),
                            items: [
                              DropdownMenuItem(
                                value: 30,
                                child: Text('30 мин'.tr),
                              ),
                              DropdownMenuItem(
                                value: 45,
                                child: Text('45 мин'.tr),
                              ),
                              DropdownMenuItem(
                                value: 60,
                                child: Text('1 час'.tr),
                              ),
                              DropdownMenuItem(
                                value: 90,
                                child: Text('1.5 часа'.tr),
                              ),
                              DropdownMenuItem(
                                value: 120,
                                child: Text('2 часа'.tr),
                              ),
                              DropdownMenuItem(
                                value: 180,
                                child: Text('3 часа'.tr),
                              ),
                            ],
                            onChanged: (value) {
                              if (value != null)
                                setSheet(() => duration = value);
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: noteCtrl,
                        decoration: InputDecoration(
                          labelText: 'Заметка'.tr,
                          hintText: 'Например: диагностика, установка'.tr,
                          border: const OutlineInputBorder(),
                        ),
                        onChanged: (value) => note = value,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final preset in presets)
                            Builder(
                              builder: (context) {
                                final selected = note.trim() == preset;
                                return ChoiceChip(
                                  label: Text(
                                    trAny(preset),
                                    style: const TextStyle(
                                      color: Color(0xFF1A1A1A),
                                      fontWeight: FontWeight.w800,
                                      fontSize: 14,
                                    ),
                                  ),
                                  selected: selected,
                                  showCheckmark: false,
                                  selectedColor: AppColors.accent,
                                  backgroundColor: const Color(0xFFE8EEF3),
                                  side: BorderSide(
                                    color: selected
                                        ? const Color(0xFFC9A015)
                                        : AppColors.primary,
                                    width: 1.4,
                                  ),
                                  onSelected: (_) {
                                    noteCtrl.text = preset;
                                    setSheet(() => note = preset);
                                  },
                                );
                              },
                            ),
                        ],
                      ),
                      if (JobStatuses.shouldWriteRescheduled(
                        ctrl.currentStatus,
                        mark: existing == null
                            ? JobStatuses.shouldMarkRescheduledOnNewVisit(
                                currentStatus: ctrl.currentStatus,
                                alreadyHasVisits: ctrl.visits.isNotEmpty,
                              )
                            : !JobVisit.isSameDay(existing.startAt, startAt),
                      ))
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(
                            'После сохранения статус станет «Перенос».'.tr,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              color: Color(0xFF3D3D3D),
                            ),
                          ),
                        ),
                      if (existing != null) ...[
                        const SizedBox(height: 8),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('Выполнен'.tr),
                          value: outcome == JobVisit.done,
                          onChanged: (value) {
                            setSheet(() {
                              outcome = value
                                  ? JobVisit.done
                                  : JobVisit.scheduled;
                            });
                          },
                        ),
                      ],
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: () {
                          note = noteCtrl.text.trim();
                          Navigator.pop(sheetContext, true);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                        ),
                        child: Text('Сохранить'.tr),
                      ),
                      if (existing != null && existing.isScheduled)
                        TextButton(
                          onPressed: () async {
                            Navigator.pop(sheetContext, false);
                            await ctrl.removeVisit(existing.id);
                          },
                          child: Text(
                            'Удалить визит'.tr,
                            style: const TextStyle(color: Colors.red),
                          ),
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

    Future<void>.delayed(const Duration(milliseconds: 350), noteCtrl.dispose);
    if (saved != true) return;

    final visit = existing == null
        ? JobVisit.create(
            startAt: startAt,
            durationMinutes: duration,
            note: note,
          )
        : existing.copyWith(
            startAt: startAt,
            durationMinutes: duration,
            note: note,
            outcome: outcome,
          );
    if (existing == null) {
      await ctrl.addVisit(visit);
    } else {
      await ctrl.updateVisit(visit);
    }
  }

  Widget _buildJobTiles() {
    final packingItems = packingItemsFromNotes(ctrl.packingNotes);
    final packing = packingItems.isEmpty
        ? ''
        : packingItems.length == 1
        ? packingItems.first
        : '${packingItems.length}';
    final description = ctrl.currentDescription.trim();
    final emptyDescription =
        description.isEmpty || description == 'Нет описания';
    final tracking = ctrl.trackingNumber.isEmpty
        ? ''
        : [
            ctrl.trackingNumber,
            if (ctrl.trackingStatus.isNotEmpty)
              _trackingLabel(ctrl.trackingStatus),
          ].join(' · ');
    final appliance = _applianceSummary();
    final photoItems = ctrl.attachments.where((item) {
      final kind = (item['kind'] ?? '').toString();
      return kind != 'call' && kind != 'signature';
    }).toList();
    final photoCount = photoItems.length;
    final photoThumb = photoCount == 0 ? null : photoItems.first;
    final callItems = ctrl.callItems;
    final lastCall = callItems.isEmpty ? null : callItems.last;
    final callSummary = lastCall == null
        ? ''
        : (lastCall['summary'] ?? lastCall['transcription'] ?? '').toString();
    final fromEmail = Job.intakeSourceOf(ctrl.jobData) == 'email';
    final emailSubject = (ctrl.jobData['sourceEmailSubject'] ?? '')
        .toString()
        .trim();
    final emailPreview = (ctrl.jobData['sourceEmailPreview'] ?? '')
        .toString()
        .trim();
    final emailFrom = (ctrl.jobData['sourceEmailFrom'] ?? '').toString().trim();

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _detailTile(
                icon: Icons.timer_outlined,
                title: 'Длительность'.tr,
                value: _visitDurationLabel(ctrl.durationMinutes),
                onTap: _pickVisitDuration,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _detailTile(
                icon: Icons.inventory_2_outlined,
                title: 'С собой'.tr,
                value: packing.isEmpty ? '—' : packing,
                muted: packing.isEmpty,
                onTap: () => openPackingEditor(context, ctrl),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _detailTile(
                icon: Icons.local_shipping_outlined,
                title: 'Отслеживание'.tr,
                value: tracking.isEmpty ? '—' : tracking,
                muted: tracking.isEmpty,
                onTap: _editTracking,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _detailTile(
          icon: Icons.notes,
          title: 'Описание'.tr,
          value: emptyDescription ? '—' : description,
          muted: emptyDescription,
          onTap: () => openDescriptionEditor(context, ctrl),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _detailTile(
                icon: Icons.kitchen,
                graphic: AppliancePicture(type: appliance.type, size: 56),
                title: 'Техника'.tr,
                value: appliance.label,
                onTap: () => openApplianceEditor(context, ctrl),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _detailTile(
                icon: Icons.photo_camera_outlined,
                title: 'Фото'.tr,
                value: ctrl.isUploadingImage
                    ? 'Загрузка...'.tr
                    : (photoCount == 0 ? '—' : '$photoCount'),
                muted: photoCount == 0 && !ctrl.isUploadingImage,
                thumbnail: photoThumb,
                onTap: () => openPhotosEditor(context, ctrl),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (fromEmail)
          _detailTile(
            icon: Icons.email_outlined,
            graphic: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: const Color(0xFF2E7D32).withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.email_outlined,
                color: Color(0xFF2E7D32),
                size: 22,
              ),
            ),
            title: context.tr('Письмо', 'Email'),
            value: emailSubject.isNotEmpty
                ? emailSubject
                : (emailFrom.isNotEmpty
                      ? emailFrom
                      : (emailPreview.isNotEmpty
                            ? emailPreview
                            : context.tr('Открыть письмо', 'Open the email'))),
            onTap: () => openSourceEmailSheet(
              context,
              jobData: ctrl.jobData,
              jobId: ctrl.jobId,
              clientId: ctrl.clientId,
              clientName: (ctrl.jobData['clientName'] ?? '').toString(),
              clientEmail: ctrl.clientEmail,
            ),
          )
        else
          _detailTile(
            icon: Icons.mic,
            graphic: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.accent,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.mic, color: Colors.black, size: 22),
            ),
            title: callItems.length > 1
                ? '${'Звонок'.tr} (${callItems.length})'
                : 'Звонок'.tr,
            value: lastCall == null
                ? 'После разговора появится запись'.tr
                : (callSummary.trim().isEmpty
                      ? 'Запись'.tr
                      : callSummary.trim()),
            muted: lastCall == null,
            onTap: lastCall == null
                ? null
                : () => openCallRecordingSheet(
                    context,
                    lastCall,
                    jobId: ctrl.jobId,
                  ),
          ),
      ],
    );
  }

  Widget _detailTile({
    required IconData icon,
    required String title,
    required String value,
    VoidCallback? onTap,
    bool muted = false,
    Map<String, dynamic>? thumbnail,
    Widget? graphic,
  }) {
    final thumb = _tileImage(thumbnail);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          height: 118,
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Column(
            children: [
              if (graphic != null)
                graphic
              else if (thumb != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    height: 36,
                    width: 36,
                    child: Image(image: thumb, fit: BoxFit.cover),
                  ),
                )
              else
                Icon(icon, color: AppColors.primary, size: 26),
              const SizedBox(height: 8),
              Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.15,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: Text(
                  value,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: muted ? Colors.grey : Colors.black87,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  ImageProvider? _tileImage(Map<String, dynamic>? attachment) {
    if (attachment == null) return null;
    final local = (attachment['localPath'] ?? '').toString();
    final url = (attachment['url'] ?? '').toString();
    if (local.isNotEmpty && url.isEmpty) return FileImage(File(local));
    if (url.isNotEmpty) return NetworkImage(url);
    return null;
  }

  ({IconData icon, String label, String type}) _applianceSummary() {
    final appliances = ctrl.jobData['appliances'];
    Map<String, dynamic>? primary;
    if (appliances is List &&
        appliances.isNotEmpty &&
        appliances.first is Map) {
      primary = Map<String, dynamic>.from(appliances.first as Map);
    }
    final type =
        (ctrl.jobData['applianceType'] ?? primary?['type'] ?? 'Техника')
            .toString();
    final brand = (ctrl.jobData['brand'] ?? primary?['brand'] ?? '').toString();
    final model = (ctrl.jobData['model'] ?? primary?['model'] ?? '').toString();
    final label = [
      trAny(type),
      if (brand.isNotEmpty) brand,
      if (model.isNotEmpty) model,
    ].join(' · ');
    return (icon: ApplianceCategories.getIcon(type), label: label, type: type);
  }

  Future<void> _pickVisitDuration() async {
    const options = [30, 45, 60, 90, 120, 180];
    final picked = await showModalBottomSheet<int>(
      context: context,
      useRootNavigator: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Длительность нового визита'.tr,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
              ),
              for (final minutes in options)
                ListTile(
                  leading: Icon(
                    ctrl.durationMinutes == minutes
                        ? Icons.check_circle
                        : Icons.circle_outlined,
                    color: AppColors.primary,
                  ),
                  title: Text(_visitDurationLabel(minutes)),
                  selected: ctrl.durationMinutes == minutes,
                  onTap: () => Navigator.pop(context, minutes),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (picked != null) await ctrl.updateDurationMinutes(picked);
  }

  String _trackingLabel(String status) {
    switch (status) {
      case 'delivered':
        return 'Доставлено'.tr;
      case 'out_for_delivery':
        return 'Курьер сегодня'.tr;
      case 'shipped':
        return 'Отправлено'.tr;
      default:
        return status;
    }
  }

  Future<void> _editTracking() async {
    final stored = (ctrl.jobData['trackingCarrier'] ?? '').toString().trim();
    final result = await showDialog<_TrackingEditResult>(
      context: context,
      builder: (context) => _TrackingEditDialog(
        trackingNumber: ctrl.trackingNumber,
        amazonOrderId: ctrl.amazonOrderId,
        carrier: stored.isNotEmpty
            ? stored
            : (ctrl.amazonOrderId.isNotEmpty ? 'amazon' : 'other'),
      ),
    );
    if (result == null || !mounted) return;
    await ctrl.updateTracking(
      number: result.number,
      amazonId: result.amazonId,
      carrier: result.carrier,
    );
  }

  void _editClientAddress() {
    final raw = (ctrl.jobData['clientAddress'] ?? '').toString();
    final parts = splitAddress(raw);
    showSmartAddressPicker(
      context: context,
      initialStreet: parts[0],
      initialCity: parts[1],
      initialPostal: parts[2],
      onSaved: (street, city, postal, unit) {
        ctrl.updateClientAddress(
          street: street,
          city: city,
          postal: postal,
          unit: unit,
        );
      },
    );
  }

  Future<void> _editJobSite() async {
    final nameCtrl = TextEditingController(text: ctrl.jobSiteName);
    final phoneCtrl = TextEditingController(text: ctrl.jobSitePhone);
    final emailCtrl = TextEditingController(text: ctrl.jobSiteEmail);
    final parts = splitAddress(ctrl.jobSiteAddress);
    final streetCtrl = TextEditingController(text: parts[0]);
    final cityCtrl = TextEditingController(text: parts[1]);
    final postalCtrl = TextEditingController(text: parts[2]);
    var unit = '';

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return KeyboardAvoidingSheet(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: StatefulBuilder(
            builder: (context, setSheet) {
              return Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Где работа'.tr,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          TextField(
                            controller: nameCtrl,
                            textCapitalization: TextCapitalization.words,
                            decoration: InputDecoration(
                              labelText: 'Имя на месте'.tr,
                              prefixIcon: const Icon(Icons.person_outline),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: phoneCtrl,
                            keyboardType: TextInputType.phone,
                            decoration: InputDecoration(
                              labelText: 'Телефон на месте'.tr,
                              prefixIcon: const Icon(Icons.phone_android),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          GestureDetector(
                            onTap: () {
                              showSmartAddressPicker(
                                context: context,
                                initialStreet: streetCtrl.text,
                                initialCity: cityCtrl.text,
                                initialPostal: postalCtrl.text,
                                initialUnit: unit,
                                onSaved: (street, city, postal, nextUnit) {
                                  streetCtrl.text = street;
                                  cityCtrl.text = city;
                                  postalCtrl.text = postal;
                                  unit = nextUnit;
                                  setSheet(() {});
                                },
                              );
                            },
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade50,
                                border: Border.all(color: Colors.grey.shade300),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.location_on,
                                    color: Colors.grey,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      cityCtrl.text.isEmpty &&
                                              streetCtrl.text.isEmpty
                                          ? 'Адрес работы (куда ехать)...'.tr
                                          : [
                                                  streetCtrl.text,
                                                  if (unit.trim().isNotEmpty)
                                                    unit.trim(),
                                                  cityCtrl.text,
                                                  postalCtrl.text,
                                                ]
                                                .where((p) => p.isNotEmpty)
                                                .join(', '),
                                    ),
                                  ),
                                  Icon(Icons.search, color: AppColors.primary),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          EmailAutocompleteField(
                            controller: emailCtrl,
                            decoration: InputDecoration(
                              labelText: 'Электронный адрес'.tr,
                              prefixIcon: const Icon(Icons.email_outlined),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        final address = [
                          streetCtrl.text.trim(),
                          if (unit.trim().isNotEmpty) unit.trim(),
                          cityCtrl.text.trim(),
                          postalCtrl.text.trim(),
                        ].where((p) => p.isNotEmpty).join(', ');
                        if (nameCtrl.text.trim().isEmpty ||
                            phoneCtrl.text.trim().isEmpty ||
                            address.isEmpty) {
                          ScaffoldMessenger.of(sheetContext).showSnackBar(
                            SnackBar(
                              content: Text(
                                'Укажите имя, телефон и адрес работы'.tr,
                              ),
                            ),
                          );
                          return;
                        }
                        ctrl.updateJobSite(
                          name: nameCtrl.text,
                          phone: phoneCtrl.text,
                          address: address,
                          email: emailCtrl.text,
                        );
                        Navigator.pop(sheetContext);
                      },
                      child: Text('OK'.tr),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              );
            },
          ),
        );
      },
    );
    nameCtrl.dispose();
    phoneCtrl.dispose();
    emailCtrl.dispose();
    streetCtrl.dispose();
    cityCtrl.dispose();
    postalCtrl.dispose();
  }

  Map<String, String> _applianceFields() {
    final appliances = ctrl.jobData['appliances'];
    Map<String, dynamic>? primary;
    if (appliances is List &&
        appliances.isNotEmpty &&
        appliances.first is Map) {
      primary = Map<String, dynamic>.from(appliances.first as Map);
    }
    return {
      'type': (ctrl.jobData['applianceType'] ?? primary?['type'] ?? '')
          .toString(),
      'brand': (ctrl.jobData['brand'] ?? primary?['brand'] ?? '').toString(),
      'model': (ctrl.jobData['model'] ?? primary?['model'] ?? '').toString(),
      'serial': (ctrl.jobData['serialNumber'] ?? primary?['serialNumber'] ?? '')
          .toString(),
    };
  }

  Future<void> _loadRelatedJobs() async {
    final fields = _applianceFields();
    final jobs = await JobService.findRelatedAppliances(
      excludeJobId: ctrl.jobId,
      clientId: ctrl.clientId,
      serialNumber: fields['serial'] ?? '',
      model: fields['model'] ?? '',
      brand: fields['brand'] ?? '',
    );
    Job? original;
    final originId = (ctrl.jobData['repeatOfJobId'] ?? '').toString().trim();
    if (originId.isNotEmpty) {
      original = await JobService.getById(originId);
    }
    if (!mounted) return;
    setState(() {
      _relatedJobs = jobs;
      _originalJob = original;
    });
  }

  Future<void> _createRepeatCall() async {
    final original = await JobService.getById(ctrl.jobId);
    if (original == null) return;
    final jobId = await JobService.createRepeatFrom(original);
    final created = await JobService.getById(jobId);
    if (!mounted || created == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => JobDetailsScreen(
          jobId: created.id,
          clientId: created.clientId,
          jobData: created.toMap(),
        ),
      ),
    );
  }

  Widget _buildRepeatCallButton() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _createRepeatCall,
        icon: const Icon(Icons.replay),
        label: Text('Повторный вызов'.tr),
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF8E24AA),
          side: const BorderSide(color: Color(0xFF8E24AA)),
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );
  }

  Widget _buildOriginalJobLink() {
    final job = _originalJob!;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.history, color: Color(0xFF8E24AA)),
      title: Text('Исходная заявка'.tr),
      subtitle: Text(
        [
          trAny(job.status),
          DateFormat(
            'd MMM yyyy',
            AppLocale.instance.dateLocale,
          ).format(job.scheduledAt ?? job.createdAt),
        ].join(' · '),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => JobDetailsScreen(
              jobId: job.id,
              clientId: job.clientId,
              jobData: job.toMap(),
            ),
          ),
        );
      },
    );
  }

  bool _shouldCompleteJob(String status) {
    if (JobStatuses.isCompletedStatus(ctrl.currentStatus)) return false;
    if (JobStatuses.isInstallStatus(status)) return false;
    final label = StatusService.labelOf(status);
    if (JobStatuses.isInstallStatus(label) && status != JobStatuses.completed) {
      return false;
    }
    return JobStatuses.isCompletedStatus(status) ||
        JobStatuses.isCompletedStatus(label);
  }

  Future<void> _completeJobFlow() async {
    final config = await SettingsService.loadConfig();
    if (!mounted) return;
    var sendReview = SettingsService.readAutoReviewSmsEnabled(config);

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheet) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Работа завершена'.tr,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      value: sendReview,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        'Отправить SMS с просьбой об отзыве'.tr,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1A1A1A),
                        ),
                      ),
                      onChanged: (value) =>
                          setSheet(() => sendReview = value ?? false),
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text('Готово'.tr),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (confirmed != true || !mounted) return;

    await ctrl.updateStatus(
      JobStatuses.completed,
      extra: sendReview
          ? null
          : {'reviewSmsSentAt': FieldValue.serverTimestamp()},
    );
  }

  Widget _buildStatusChip() {
    final color = ctrl.getStatusColor();
    return GestureDetector(
      onTap: _showStatusMenu,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Статус'.tr,
              style: const TextStyle(
                fontSize: 11,
                color: Colors.grey,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                Expanded(
                  child: Text(
                    trAny(StatusService.labelOf(ctrl.currentStatus)),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: color,
                      fontSize: 15,
                    ),
                  ),
                ),
                Icon(Icons.arrow_drop_down, color: color),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClientIconButton() {
    return Tooltip(
      message: 'Карточка клиента'.tr,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: _openClientCard,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: Icon(Icons.person, color: AppColors.primary, size: 26),
          ),
        ),
      ),
    );
  }

  Widget _buildPriorityFlag() {
    final color = ctrl.getPriorityColor();
    return Tooltip(
      message: 'Приоритет'.tr,
      child: Material(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: _showPriorityMenu,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color.withValues(alpha: 0.3)),
            ),
            child: Icon(Icons.flag, color: color, size: 26),
          ),
        ),
      ),
    );
  }

  void _openClientCard() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ClientDetailsScreen(
          clientId: ctrl.clientId,
          clientData: {
            'name': ctrl.jobData['clientName'] ?? '',
            'phone': ctrl.jobData['clientPhone'] ?? '',
            'address': ctrl.jobData['clientAddress'] ?? '',
          },
        ),
      ),
    );
  }

  Widget _buildVisitsCard() {
    final visits = ctrl.visits;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
      decoration: BoxDecoration(
        color: visits.isNotEmpty
            ? AppColors.primary.withOpacity(0.06)
            : Colors.orange.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: visits.isNotEmpty
              ? AppColors.primary.withOpacity(0.25)
              : Colors.orange.withOpacity(0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.calendar_month,
                color: visits.isNotEmpty ? AppColors.primary : Colors.orange,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'История визитов'.tr,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () => _editVisit(),
                icon: const Icon(Icons.add, size: 18),
                label: Text('Добавить'.tr),
              ),
            ],
          ),
          if (ctrl.currentStatus == JobStatuses.waitingPart &&
              !visits.any((visit) => visit.isScheduled))
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 0, 8, 12),
              child: Text(
                'Ожидание запчасти — дату возврата ставить не нужно. Добавьте визит, когда запчасть приедет.'
                    .tr,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: Colors.orange.shade800,
                ),
              ),
            )
          else if (visits.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 0, 8, 12),
              child: Text(
                'Не запланировано — нажмите «Добавить», чтобы назначить'.tr,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: Colors.orange.shade800,
                ),
              ),
            ),
          for (final visit in visits) _buildVisitTile(visit),
        ],
      ),
    );
  }

  Widget _buildVisitTile(JobVisit visit) {
    final done = visit.isDone;
    return InkWell(
      onTap: () => _editVisit(visit),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(2, 6, 8, 10),
        child: Row(
          children: [
            Icon(
              done ? Icons.check_circle : Icons.event,
              color: done ? Colors.green : AppColors.primary,
              size: 22,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    DateFormat(
                      'd MMMM yyyy',
                      AppLocale.instance.dateLocale,
                    ).format(visit.startAt),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      decoration: done ? TextDecoration.lineThrough : null,
                      color: done ? Colors.black54 : Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        [
                          DateFormat('HH:mm').format(visit.startAt),
                          _visitDurationLabel(visit.durationMinutes),
                          if (visit.note.trim().isNotEmpty) visit.note.trim(),
                        ].join(' · '),
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade700,
                        ),
                      ),
                      VisitConfirmBadge(
                        status: VisitConfirmBadge.visualOf(visit),
                        compact: true,
                        iconOnly: true,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Icon(Icons.edit, color: Colors.grey.shade400, size: 18),
          ],
        ),
      ),
    );
  }

  String _visitDurationLabel(int minutes) {
    switch (minutes) {
      case 30:
        return '30 мин'.tr;
      case 45:
        return '45 мин'.tr;
      case 60:
        return '1 час'.tr;
      case 90:
        return '1.5 часа'.tr;
      case 120:
        return '2 часа'.tr;
      case 180:
        return '3 часа'.tr;
      default:
        return '$minutes ${'мин'.tr}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (ctrl.needsReview) ...[
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.shade300),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    Job.intakeSourceOf(ctrl.jobData) == 'email'
                        ? context.tr(
                            'ИИ создал эту заявку из письма. Проверьте данные и подтвердите.',
                            'AI created this job from an email. Check the details and confirm.',
                          )
                        : 'ИИ создал эту заявку после звонка. Проверьте данные и подтвердите.'
                              .tr,
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () => ctrl.markReviewed(),
                      icon: const Icon(Icons.check),
                      label: Text('Проверено'.tr),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange.shade700,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 6.0;
              final usable = (constraints.maxWidth - gap * 2).clamp(
                0.0,
                double.infinity,
              );
              return IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: usable * 0.60, child: _buildStatusChip()),
                    const SizedBox(width: gap),
                    SizedBox(
                      width: usable * 0.30,
                      child: _buildClientIconButton(),
                    ),
                    const SizedBox(width: gap),
                    SizedBox(width: usable * 0.10, child: _buildPriorityFlag()),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          _buildVisitsCard(),
          const SizedBox(height: 12),
          _buildContactCard(),
          const SizedBox(height: 12),
          _buildJobTiles(),
          const SizedBox(height: 12),
          _buildRepeatCallButton(),
          if (_originalJob != null) ...[
            const SizedBox(height: 8),
            _buildOriginalJobLink(),
          ],
          if (_relatedJobs.isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildRelatedJobs(),
          ],
        ],
      ),
    );
  }

  Widget _buildContactCard() {
    final clientName = (ctrl.jobData['clientName'] ?? 'Клиент'.tr).toString();
    final clientPhone = (ctrl.jobData['clientPhone'] ?? '').toString();
    final clientAddress = (ctrl.jobData['clientAddress'] ?? '').toString();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _addressBlock(
            icon: Icons.person,
            title: 'Клиент'.tr,
            name: clientName,
            phone: clientPhone,
            address: clientAddress.isEmpty
                ? 'Адрес не указан'.tr
                : clientAddress,
            onEdit: _editClientAddress,
          ),
          const SizedBox(height: 14),
          if (ctrl.hasJobSite)
            _addressBlock(
              icon: Icons.home_work_outlined,
              title: 'Где работа'.tr,
              name: ctrl.jobSiteName.isEmpty
                  ? 'Контакт на адресе'.tr
                  : ctrl.jobSiteName,
              phone: ctrl.jobSitePhone,
              address: ctrl.jobSiteAddress.isEmpty
                  ? 'Адрес не указан'.tr
                  : ctrl.jobSiteAddress,
              onEdit: _editJobSite,
              onClear: () => ctrl.clearJobSite(),
            )
          else
            SizedBox(
              width: double.infinity,
              height: 48,
              child: OutlinedButton.icon(
                onPressed: _editJobSite,
                icon: const Icon(Icons.add_home_work_outlined),
                label: Text(
                  'Другой адрес работы'.tr,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: BorderSide(color: AppColors.primary, width: 1.4),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => MapsService.openNavigator(ctrl.workAddress),
                  icon: ctrl.isLoadingTime
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.black,
                          ),
                        )
                      : const Icon(Icons.directions_car),
                  label: Text(ctrl.isLoadingTime ? '...' : ctrl.travelTime),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.black,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _callSelected,
                icon: const Icon(Icons.phone),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.green.shade100,
                  foregroundColor: Colors.green.shade800,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _smsSelected,
                icon: const Icon(Icons.sms),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.blue.shade100,
                  foregroundColor: Colors.blue.shade800,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _addressBlock({
    required IconData icon,
    required String title,
    required String name,
    required String phone,
    required String address,
    required VoidCallback onEdit,
    VoidCallback? onClear,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: AppColors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: AppColors.primary,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Изменить'.tr,
              icon: Icon(Icons.edit, color: Colors.grey.shade600, size: 20),
              onPressed: onEdit,
            ),
            if (onClear != null)
              IconButton(
                tooltip: 'Убрать'.tr,
                icon: const Icon(
                  Icons.close,
                  color: Colors.redAccent,
                  size: 20,
                ),
                onPressed: onClear,
              ),
          ],
        ),
        Text(
          name,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        if (phone.trim().isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(phone.trim(), style: TextStyle(color: Colors.grey.shade800)),
        ],
        const SizedBox(height: 4),
        GestureDetector(
          onTap: onEdit,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  address,
                  style: TextStyle(color: Colors.grey.shade700),
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.grey.shade400),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRelatedJobs() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Эта техника раньше'.tr,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
        ),
        const SizedBox(height: 6),
        for (final job in _relatedJobs.take(5))
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(trAny(job.status)),
            subtitle: Text(
              job.scheduledAt != null
                  ? DateFormat(
                      'd MMM yyyy',
                      AppLocale.instance.dateLocale,
                    ).format(job.scheduledAt!)
                  : DateFormat(
                      'd MMM yyyy',
                      AppLocale.instance.dateLocale,
                    ).format(job.createdAt),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => JobDetailsScreen(
                    jobId: job.id,
                    clientId: job.clientId,
                    jobData: job.toMap(),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

class _TrackingEditResult {
  final String number;
  final String amazonId;
  final String carrier;

  const _TrackingEditResult({
    required this.number,
    required this.amazonId,
    required this.carrier,
  });
}

const _kTrackingSuppliers = <String, String>{
  'amazon': 'Amazon',
  'reliable_parts': 'Reliable Parts',
  'partselect': 'PartSelect',
  'encompass': 'Encompass / RepairClinic',
  'marcone': 'Marcone',
  'ebay': 'eBay',
  'carrier': 'UPS / FedEx / Purolator / Canada Post',
  'other': 'Другой',
};

class _TrackingEditDialog extends StatefulWidget {
  final String trackingNumber;
  final String amazonOrderId;
  final String carrier;

  const _TrackingEditDialog({
    required this.trackingNumber,
    required this.amazonOrderId,
    required this.carrier,
  });

  @override
  State<_TrackingEditDialog> createState() => _TrackingEditDialogState();
}

class _TrackingEditDialogState extends State<_TrackingEditDialog> {
  late final TextEditingController _numberCtrl;
  late final TextEditingController _amazonCtrl;
  late String _carrier;
  bool _pickingSupplier = false;

  @override
  void initState() {
    super.initState();
    _numberCtrl = TextEditingController(text: widget.trackingNumber);
    _amazonCtrl = TextEditingController(text: widget.amazonOrderId);
    _carrier = _kTrackingSuppliers.containsKey(widget.carrier)
        ? widget.carrier
        : 'other';
  }

  @override
  void dispose() {
    _numberCtrl.dispose();
    _amazonCtrl.dispose();
    super.dispose();
  }

  void _save() {
    FocusScope.of(context).unfocus();
    Navigator.pop(
      context,
      _TrackingEditResult(
        number: _numberCtrl.text,
        amazonId: _amazonCtrl.text,
        carrier: _carrier,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final label = (_kTrackingSuppliers[_carrier] ?? 'Другой').tr;
    return AlertDialog(
      title: Text('Отслеживание'.tr),
      scrollable: true,
      content: SizedBox(
        width: (MediaQuery.sizeOf(context).width - 72).clamp(240.0, 320.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: () => setState(() => _pickingSupplier = !_pickingSupplier),
              borderRadius: BorderRadius.circular(8),
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: 'Поставщик'.tr,
                  border: const OutlineInputBorder(),
                  suffixIcon: Icon(
                    _pickingSupplier ? Icons.expand_less : Icons.expand_more,
                  ),
                ),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (_pickingSupplier) ...[
              const SizedBox(height: 8),
              for (final entry in _kTrackingSuppliers.entries)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  selected: entry.key == _carrier,
                  title: Text(
                    entry.value.tr,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: entry.key == _carrier
                      ? const Icon(Icons.check, size: 18)
                      : null,
                  onTap: () {
                    setState(() {
                      _carrier = entry.key;
                      _pickingSupplier = false;
                    });
                  },
                ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _numberCtrl,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              decoration: InputDecoration(
                labelText: 'Трек-номер'.tr,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _amazonCtrl,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              decoration: InputDecoration(
                labelText: 'Номер заказа'.tr,
                hintText: '123-1234567-1234567',
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Отмена'.tr),
        ),
        TextButton(onPressed: _save, child: Text('Сохранить'.tr)),
      ],
    );
  }
}
