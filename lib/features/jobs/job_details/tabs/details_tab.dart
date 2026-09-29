import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../../core/app_feedback.dart';
import '../../../../core/constants.dart';
import '../../../../core/utils/app_time_picker.dart';
import '../../../../core/utils/thumb_image.dart';
import '../../../../models/client.dart';
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
import '../../../../core/utils/formatters.dart';
import '../../../../shared/widgets/app_bar_save.dart';
import '../../../../shared/widgets/keyboard_safe.dart';
import '../../../../shared/widgets/visit_confirm_badge.dart';
import '../../../../shared/widgets/appliance_picture.dart';
import '../../../../widgets/smart_address_picker.dart';
import '../../../../shared/widgets/email_field.dart';
import '../../../../shared/widgets/confirm_action_sheet.dart';

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
  /// Вторая заявка с того же номера: дубляж, который сервер не стал соединять
  /// сам, либо та, в которую эту уже слили.
  Job? _twinJob;
  String _twinJobId = '';
  bool _mergeBusy = false;
  bool _bookingBusy = false;
  final Map<String, String> _bookingRequestIds = {};
  StreamSubscription<List<JobChangeEvent>>? _changesSub;
  List<JobChangeEvent> _changes = [];

  String get _bookingPhone {
    final site = ctrl.jobSitePhone.trim();
    final owner = (ctrl.jobData['clientPhone'] ?? '').toString().trim();
    return ctrl.hasJobSite && site.isNotEmpty ? site : owner.isNotEmpty ? owner : site;
  }

  @override
  void initState() {
    super.initState();
    ctrl.addListener(_onControllerChange);
    _loadRelatedJobs();
    unawaited(_loadTwinJob());
    _changesSub = ChangeLogService.streamChanges(ctrl.jobId).listen((events) {
      if (mounted) setState(() => _changes = events);
    });
  }

  @override
  void dispose() {
    ctrl.removeListener(_onControllerChange);
    _changesSub?.cancel();
    super.dispose();
  }

  void _onControllerChange() {
    if (mounted) setState(() {});
    if (_duplicateTwinId() != _twinJobId) unawaited(_loadTwinJob());
  }

  /// Заявка, с которой эту стоит соединить (или уже соединили).
  String _duplicateTwinId() {
    final merged = (ctrl.jobData['mergedIntoJobId'] ?? '').toString().trim();
    if (merged.isNotEmpty) return merged;
    if (ctrl.jobData['duplicateDismissed'] == true) return '';
    return (ctrl.jobData['possibleDuplicateOfJobId'] ?? '').toString().trim();
  }

  Future<void> _loadTwinJob() async {
    final id = _duplicateTwinId();
    _twinJobId = id;
    final twin = id.isEmpty ? null : await JobService.getById(id);
    if (!mounted) return;
    setState(() => _twinJob = twin?.isDeleted == true ? null : twin);
  }

  Future<JobChatContact?> _pickContact(
    String title, {
    bool phoneOnly = false,
  }) async {
    var contacts = ctrl.chatContacts;
    if (phoneOnly) {
      contacts = [
        for (final contact in contacts)
          if (contact.normalizedPhone.length >= 10) contact,
      ];
    }
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
    final phoneContacts = [
      for (final c in ctrl.chatContacts)
        if (c.normalizedPhone.length >= 10) c,
    ];
    JobChatContact? contact;
    if (phoneContacts.length == 1) {
      contact = phoneContacts.first;
    } else if (phoneContacts.length > 1) {
      contact = await _pickContact('Кому позвонить?'.tr, phoneOnly: true);
      if (contact == null || !mounted) return;
    }
    final phone = (contact?.phone ?? ctrl.contactPhone).trim();
    if (SmsService.normalizePhone(phone).length < 10) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Нет телефона'.tr)));
      return;
    }
    if (!mounted) return;
    await CallScreen.open(
      context,
      phoneNumber: phone,
      contactName: contact?.displayName ?? ctrl.contactName,
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
                            'После запчасти новый визит ставит статус «Установка». Старые выезды на календаре остаются «Перенос».'
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
                            'd MMM yyyy',
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
                      if (existing != null) ...[
                        SizedBox(
                          height: 44,
                          child: ElevatedButton.icon(
                            onPressed: () => _resendVisitBookingSms(existing),
                            icon: const Icon(Icons.sms_outlined, size: 20),
                            label: Text(
                              'Отправить SMS с подтверждением визита'.tr,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 13,
                                height: 1.1,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF008F3B),
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
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
                      if (JobStatuses.shouldMarkInstallOnReturnVisit(
                            currentStatus: ctrl.currentStatus,
                            isNewVisit: existing == null,
                          ) ||
                          (ctrl.currentStatus == JobStatuses.waitingPart &&
                              existing != null &&
                              !JobVisit.isSameDay(existing.startAt, startAt)))
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(
                            'После сохранения статус станет «Установка». Старый визит на календаре — «Перенос».'
                                .tr,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              color: Color(0xFF3D3D3D),
                            ),
                          ),
                        )
                      else if (JobStatuses.shouldWriteRescheduled(
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
                      Center(
                        child: RoundActionButton(
                          color: const Color(0xFF22C55E),
                          icon: Icons.check_rounded,
                          tooltip: 'Сохранить'.tr,
                          onTap: () {
                            note = noteCtrl.text.trim();
                            Navigator.pop(sheetContext, true);
                          },
                        ),
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
    final fromEmail = Job.intakeSourceOf(ctrl.jobData) == 'email';
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
            Expanded(child: _packingTile()),
            const SizedBox(width: 8),
            Expanded(child: _trackingTile()),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: _descriptionTile()),
            const SizedBox(width: 8),
            Expanded(child: _applianceTile()),
            const SizedBox(width: 8),
            Expanded(child: _photosTile()),
          ],
        ),
        if (fromEmail) ...[
          const SizedBox(height: 8),
          _emailTile(),
        ],
      ],
    );
  }

  Widget _packingTile() {
    final packingItems = packingItemsFromNotes(ctrl.packingNotes);
    final packing = packingItems.isEmpty
        ? ''
        : packingItems.length == 1
        ? packingItems.first
        : '${packingItems.length}';
    return _detailTile(
      icon: Icons.inventory_2_outlined,
      title: 'С собой'.tr,
      value: packing.isEmpty ? '—' : packing,
      muted: packing.isEmpty,
      onTap: () => openPackingEditor(context, ctrl),
    );
  }

  Widget _trackingTile() {
    final tracking = ctrl.trackingNumber.isEmpty
        ? ''
        : [
            ctrl.trackingNumber,
            if (ctrl.trackingStatus.isNotEmpty)
              _trackingLabel(ctrl.trackingStatus),
          ].join(' · ');
    return _detailTile(
      icon: Icons.local_shipping_outlined,
      title: 'Отслеживание'.tr,
      value: tracking.isEmpty ? '—' : tracking,
      copyValue: ctrl.trackingNumber.isNotEmpty ? ctrl.trackingNumber : null,
      muted: tracking.isEmpty,
      onTap: _editTracking,
    );
  }

  Widget _descriptionTile() {
    final description = ctrl.currentDescription.trim();
    final emptyDescription =
        description.isEmpty || description == 'Нет описания';
    return _detailTile(
      icon: Icons.notes,
      title: 'Описание'.tr,
      value: emptyDescription ? '—' : description,
      muted: emptyDescription,
      onTap: () => openDescriptionEditor(context, ctrl),
    );
  }

  Widget _applianceTile() {
    final appliance = _applianceSummary();
    return _detailTile(
      icon: Icons.kitchen,
      graphic: AppliancePicture(type: appliance.type, size: 44),
      title: 'Техника'.tr,
      value: appliance.label,
      onTap: () => openApplianceEditor(context, ctrl),
    );
  }

  Widget _photosTile() {
    final photoItems = ctrl.attachments.where((item) {
      final kind = (item['kind'] ?? '').toString();
      return kind != 'call' && kind != 'signature';
    }).toList();
    final photoCount = photoItems.length;
    return _detailTile(
      icon: Icons.photo_camera_outlined,
      title: 'Фото'.tr,
      value: ctrl.isUploadingImage
          ? 'Загрузка...'.tr
          : (photoCount == 0 ? '—' : '$photoCount'),
      muted: photoCount == 0 && !ctrl.isUploadingImage,
      thumbnail: photoCount == 0 ? null : photoItems.first,
      onTap: () => openPhotosEditor(context, ctrl),
    );
  }

  Widget _emailTile() {
    final emailSubject = (ctrl.jobData['sourceEmailSubject'] ?? '')
        .toString()
        .trim();
    final emailPreview = (ctrl.jobData['sourceEmailPreview'] ?? '')
        .toString()
        .trim();
    final emailFrom = (ctrl.jobData['sourceEmailFrom'] ?? '').toString().trim();
    return _detailTile(
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
    double height = 118,
    String? copyValue,
  }) {
    final thumb = _tileImage(thumbnail);
    final valueToCopy = copyValue ?? value;
    final canCopy = valueToCopy.isNotEmpty && valueToCopy != '—';
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        onLongPress: canCopy ? () => AppFeedback.copy(context, valueToCopy) : null,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          height: height,
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
    if (local.isNotEmpty && url.isEmpty) {
      return ResizeImage(
        FileImage(File(local)),
        width: 480,
        policy: ResizeImagePolicy.fit,
      );
    }
    if (url.isNotEmpty) return thumbImage(url, width: 480);
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

  Future<void> _editJobSite() async {
    final useClient =
        !ctrl.hasJobSite ||
        (ctrl.jobSiteName.trim().isEmpty &&
            ctrl.jobSitePhone.trim().isEmpty &&
            ctrl.jobSiteAddress.trim().isEmpty);
    final clientName = (ctrl.jobData['clientName'] ?? '').toString().trim();
    final clientPhone = (ctrl.jobData['clientPhone'] ?? '').toString().trim();
    final clientAddress =
        (ctrl.jobData['clientAddress'] ?? '').toString().trim();
    final clientEmail = ctrl.clientEmail.trim();

    final nameCtrl = TextEditingController(
      text: useClient && ctrl.jobSiteName.trim().isEmpty
          ? clientName
          : ctrl.jobSiteName,
    );
    final phoneCtrl = TextEditingController(
      text: useClient && ctrl.jobSitePhone.trim().isEmpty
          ? clientPhone
          : ctrl.jobSitePhone,
    );
    final emailCtrl = TextEditingController(
      text: useClient && ctrl.jobSiteEmail.trim().isEmpty
          ? clientEmail
          : ctrl.jobSiteEmail,
    );
    final parts = splitAddress(
      useClient && ctrl.jobSiteAddress.trim().isEmpty
          ? clientAddress
          : ctrl.jobSiteAddress,
    );
    final streetCtrl = TextEditingController(text: parts[0]);
    final cityCtrl = TextEditingController(text: parts[1]);
    final postalCtrl = TextEditingController(text: parts[2]);
    var unit = '';
    final peeled = peelUnit(parts[0]);
    if (peeled.unit.isNotEmpty) {
      streetCtrl.text = peeled.street;
      unit = peeled.unit;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        // Подсказка внутри окна: ScaffoldMessenger рисует её ПОД модальным
        // окном, поэтому нажатие выглядело как «кнопка не работает».
        var siteError = '';
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
                  if (siteError.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline,
                              color: Colors.red, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              siteError,
                              style: const TextStyle(color: Colors.red),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Center(
                    child: RoundActionButton(
                      color: kConfirmGreen,
                      icon: Icons.check_rounded,
                      tooltip: 'OK'.tr,
                      onTap: () {
                        final address = [
                          streetCtrl.text.trim(),
                          if (unit.trim().isNotEmpty) unit.trim(),
                          cityCtrl.text.trim(),
                          postalCtrl.text.trim(),
                        ].where((p) => p.isNotEmpty).join(', ');
                        // Держит только адрес — ехать надо по нему. Имя и
                        // телефон на месте часто неизвестны заранее.
                        if (address.isEmpty) {
                          setSheet(() => siteError = 'Укажите адрес работы'.tr);
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
                    Center(
                      child: RoundActionButton(
                        color: const Color(0xFF22C55E),
                        icon: Icons.check_rounded,
                        tooltip: 'Готово'.tr,
                        onTap: () => Navigator.pop(context, true),
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
    if (confirmed != true || !mounted) return;

    final extra = <String, dynamic>{};
    if (sendReview) {
      final ok = await _sendReviewSms(config);
      if (ok) {
        extra['reviewSmsSentAt'] = FieldValue.serverTimestamp();
      } else {
        extra['requestReviewSms'] = true;
      }
    } else {
      extra['reviewSmsSentAt'] = FieldValue.serverTimestamp();
    }

    await ctrl.updateStatus(
      JobStatuses.completed,
      extra: extra,
      persistNow: true,
    );
  }

  Future<bool> _sendReviewSms(Map<String, dynamic> config) async {
    final phone = ctrl.contactPhone.trim();
    if (phone.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Нет телефона для SMS'.tr),
            backgroundColor: Colors.orange.shade800,
          ),
        );
      }
      return false;
    }

    final templates = await SettingsService.loadSmsTemplates();
    final reviewUrl = SettingsService.readGoogleReviewUrl(config);
    final name = ctrl.contactName.trim().isEmpty
        ? 'there'
        : ctrl.contactName.trim();
    final address = ctrl.workAddress.trim();
    final template =
        templates['job_done'] ?? SettingsService.defaultJobDoneSms;
    var body = template
        .replaceAll('{name}', name)
        .replaceAll('{date}', '')
        .replaceAll('{time}', '')
        .replaceAll('{address}', address)
        .replaceAll('{review}', reviewUrl)
        .replaceAll('{appliance}', '')
        .trim();
    // Только если ссылки в тексте нет вообще: шаблон с вписанной руками
    // ссылкой иначе получал вторую, из настроек.
    if (reviewUrl.isNotEmpty && !RegExp(r'https?://').hasMatch(body)) {
      body = '$body $reviewUrl'.trim();
    }

    final ok = await SmsService.sendSms(
      to: phone,
      body: body,
      clientId: ctrl.clientId,
    );
    if (!mounted) return ok;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'SMS с просьбой об отзыве отправлено'.tr
              : SmsService.failureText(),
        ),
        backgroundColor: ok ? Colors.green : Colors.red,
      ),
    );
    return ok;
  }

  Widget _buildStatusButton() {
    final color = ctrl.getStatusColor();
    final onColor =
        color.computeLuminance() > 0.55 ? Colors.black : Colors.white;
    return ElevatedButton(
      onPressed: _showStatusMenu,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: onColor,
        elevation: 1,
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        alignment: Alignment.centerLeft,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Статус заказа'.tr,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: onColor.withValues(alpha: 0.85),
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
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
              ),
              Icon(Icons.arrow_drop_down, color: onColor),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildClientIconButton() {
    final name = (ctrl.jobData['clientName'] ?? '').toString().trim();
    final label = name.isEmpty ? 'Клиент'.tr : name;
    return Tooltip(
      message: 'Карточка клиента'.tr,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: _openClientCard,
          onLongPress: name.isNotEmpty ? () => AppFeedback.copy(context, name) : null,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: double.infinity,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Клиент'.tr,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.grey,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(Icons.person, color: AppColors.primary, size: 20),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: AppColors.primary,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openClientCard() async {
    var clientId = ctrl.clientId.trim();
    final name    = (ctrl.jobData['clientName']    ?? '').toString().trim();
    final phone   = (ctrl.jobData['clientPhone']   ?? '').toString().trim();
    final address = (ctrl.jobData['clientAddress'] ?? '').toString().trim();
    final email   = ctrl.clientEmail.trim();

    // Если заявка не привязана к карточке клиента — найти по телефону
    // или создать новую карточку и сразу привязать к заявке.
    if (clientId.isEmpty) {
      Client? found;
      if (phone.isNotEmpty) {
        found = await ClientService.findByPhone(phone);
      }
      if (!mounted) return;

      if (found != null) {
        // Нашли существующего клиента (в т.ч. из корзины) — привязываем
        clientId = found.id;
      } else if (name.isNotEmpty || phone.isNotEmpty) {
        // Создаём новую карточку из данных заявки
        clientId = await ClientService.createOrUpdate(
          fullName: name.isNotEmpty ? name : phone,
          phone: phone,
          address: address,
          email: email.isEmpty ? null : email,
        );
      }
      if (!mounted) return;

      // Записываем clientId в заявку фоном
      if (clientId.isNotEmpty) {
        unawaited(JobService.update(ctrl.jobId, {'clientId': clientId}));
      }
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ClientDetailsScreen(
          clientId: clientId,
          clientData: {
            'name':    name,
            'fullName': name,
            'phone':   phone,
            'address': address,
            'email':   email,
          },
        ),
      ),
    );
  }

  Widget _buildVisitsCard() {
    final visits = ctrl.visits;
    final current = _orderConfirmVisit;
    final hasReschedule = visits.length > 1 && current != null;
    final previous = hasReschedule
        ? [
            for (final visit in visits)
              if (visit.id != current.id) visit,
          ]
        : const <JobVisit>[];
    final dateOnly = current == null
        ? 'Не запланировано'.tr
        : DateFormat(
            'd MMM',
            AppLocale.instance.dateLocale,
          ).format(current.startAt);
    final timeOnly = current == null
        ? '—'
        : DateFormat('HH:mm').format(current.startAt);
    final iconColor =
        current == null ? Colors.orange.shade800 : AppColors.primary;
    final dateColor =
        current == null ? Colors.orange.shade800 : Colors.black;
    const addSize = 48.0;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 7,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
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
                  Text(
                    'Дата визита'.tr,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: () => _editVisit(current),
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 1,
                              horizontal: 2,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.calendar_month_rounded,
                                      size: 18,
                                      color: iconColor,
                                    ),
                                    const SizedBox(width: 4),
                                    Flexible(
                                      child: Text(
                                        dateOnly,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 13,
                                          color: dateColor,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.access_time_rounded,
                                      size: 18,
                                      color: iconColor,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      timeOnly,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 13,
                                        color: dateColor,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (previous.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: 6, top: 2),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              for (final visit in previous)
                                _buildPreviousVisitChip(visit),
                            ],
                          ),
                        ),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: addSize,
                        height: addSize,
                        child: Material(
                          color: AppColors.accent,
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            onTap: () {
                              AppFeedback.haptic();
                              _editVisit();
                            },
                            borderRadius: BorderRadius.circular(12),
                            child: const Icon(
                              Icons.add_rounded,
                              size: 26,
                              color: Colors.black,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (ctrl.currentStatus == JobStatuses.waitingPart &&
                      !visits.any((visit) => visit.isScheduled))
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'Ожидание запчасти — дату возврата ставить не нужно. Добавьте визит, когда запчасть приедет.'
                            .tr,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                          color: Colors.orange.shade800,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: _buildOrderConfirmStrip(current),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOrderConfirmStrip(JobVisit? visit) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: visit == null ? null : () => _pickVisitConfirm(visit),
        borderRadius: BorderRadius.circular(12),
        child: VisitConfirmBadge.stamp(
          visit,
          jobStatus: ctrl.currentStatus,
          expand: true,
        ),
      ),
    );
  }

  Future<void> _pickVisitConfirm(JobVisit visit) async {
    final current = visit.effectiveConfirmStatus;
    final picked = await VisitConfirmBadge.pick(
      context,
      current: current,
    );
    if (!mounted || picked == null || picked == current) return;
    await ctrl.updateVisitConfirm(visit, picked);
  }

  JobVisit? get _orderConfirmVisit {
    final visits = ctrl.visits.where((v) => v.isScheduled).toList();
    if (visits.isEmpty) {
      return ctrl.visits.isNotEmpty ? ctrl.visits.last : null;
    }
    return visits.reduce((a, b) {
      final cmp = a.startAt.compareTo(b.startAt);
      if (cmp != 0) return cmp > 0 ? a : b;
      return a.id.compareTo(b.id) >= 0 ? a : b;
    });
  }

  /// Визит, для которого сервер отложил SMS до подтверждения владельца.
  JobVisit? get _pendingSmsVisit {
    for (final visit in ctrl.visits) {
      if (visit.isActiveSlot &&
          ['pending', 'approved', 'sending', 'error'].contains(visit.bookingSmsState)) {
        return visit;
      }
    }
    return null;
  }

  /// «SMS ждёт отправки»: сервер только пометил визит, отправляет владелец.
  Widget _pendingSmsBanner(JobVisit visit) {
    final clock = AppTimeService.bookingWallClock(visit.startAt);
    final when =
        '${DateFormat('d MMM', AppLocale.instance.dateLocale).format(clock)}'
        ' · ${DateFormat('HH:mm').format(clock)}';
    final sending = visit.bookingSmsState == 'sending';
    final approved = visit.bookingSmsState == 'approved';
    final busy = _bookingBusy || sending;
    final failed = visit.bookingSmsState == 'error';
    final unknown = failed && visit.smsBooking['retryAllowed'] == false;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.sms_outlined, size: 20, color: Colors.orange.shade800),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  sending
                      ? 'SMS отправляется'.tr
                      : approved
                      ? 'SMS одобрено'.tr
                      : failed
                      ? 'Проверьте отправку SMS'.tr
                      : 'SMS ждёт отправки'.tr,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    color: Colors.orange.shade900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            sending
                ? '${'Ожидаем результат отправки'.tr}: $when'
                : approved
                ? '${'Нажмите «Продолжить», чтобы завершить отправку'.tr}: $when'
                : failed
                ? (visit.smsBooking['error'] ?? 'Не удалось отправить SMS'.tr).toString()
                : '${'Подтверждение визита ещё не отправлено'.tr}: $when',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: busy || unknown ? null : () => _resendVisitBookingSms(visit),
                  icon: const Icon(Icons.send_rounded, size: 20),
                  label: Text(approved ? 'Продолжить'.tr : failed ? 'Повторить'.tr : 'Отправить'.tr),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF22C55E),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: busy || unknown || approved ? null : () => _dismissPendingSms(visit),
                  icon: const Icon(Icons.close_rounded, size: 20),
                  label: Text('Не отправлять'.tr),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE53935),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  JobVisit? _currentBookingVisit(JobVisit expected) {
    for (final visit in ctrl.visits) {
      if (visit.id == expected.id && visit.isActiveSlot &&
          AppTimeService.bookingSlotKey(visit.startAt) == AppTimeService.bookingSlotKey(expected.startAt)) {
        return visit;
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Визит изменился. Откройте его заново.'.tr)),
      );
    }
    return null;
  }

  Future<void> _dismissPendingSms(JobVisit visit) async {
    if (_bookingBusy || visit.bookingSmsInProgress) return;
    setState(() => _bookingBusy = true);
    try {
      AppFeedback.haptic();
      final ok = await showConfirmCancelSheet(
        context,
        title: 'Не отправлять SMS?'.tr,
        message: 'Подтверждение для этого времени визита не будет отправлено.'.tr,
        confirmLabel: 'Не отправлять'.tr,
      );
      if (!ok || !mounted) return;
      final current = _currentBookingVisit(visit);
      if (current == null || current.bookingSmsInProgress) return;
      visit = current;
      final slotKey = AppTimeService.bookingSlotKey(visit.startAt);
      // copyWith не умеет обнулять smsBookingPendingAt, но сервер смотрит на флаг.
      await ctrl.updateVisit(visit.copyWith(
        smsBookingPending: false,
        smsBookingSlotKey: slotKey,
        smsBooking: {
          'state': 'rejected',
          'slotKey': slotKey,
          'decidedAt': DateTime.now(),
        },
      ));
      await ctrl.commitChanges();
    } finally {
      if (mounted) setState(() => _bookingBusy = false);
    }
  }

  Widget _buildPreviousVisitChip(JobVisit visit) {
    final label =
        '${DateFormat('d MMM', AppLocale.instance.dateLocale).format(visit.startAt)} · ${DateFormat('HH:mm').format(visit.startAt)}';
    return InkWell(
      onTap: () => _editVisit(visit),
      borderRadius: BorderRadius.circular(4),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Color(0xFF9E9E9E),
          decoration: TextDecoration.lineThrough,
          height: 1.1,
        ),
      ),
    );
  }

  Future<void> _resendVisitBookingSms(JobVisit visit) async {
    if (_bookingBusy || visit.bookingSmsState == 'sending') return;
    if (visit.bookingSmsState == 'error' && visit.smsBooking['retryAllowed'] == false) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Результат отправки неизвестен — сначала проверьте переписку.'.tr)),
      );
      return;
    }
    AppFeedback.haptic();
    final phone = _bookingPhone;
    if (phone.isEmpty || ctrl.needsReview) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(phone.isEmpty
              ? 'Нет телефона для SMS'.tr
              : 'Сначала нажмите «Проверено» — потом можно слать SMS.'.tr),
          backgroundColor: Colors.orange.shade800,
        ),
      );
      return;
    }
    setState(() => _bookingBusy = true);
    try {
      final templates = await SettingsService.loadSmsTemplates();
      final name = ctrl.contactName.trim().isEmpty ? 'there' : ctrl.contactName.trim();
      final clock = AppTimeService.bookingWallClock(visit.startAt);
      final date = DateFormat('MMMM d', 'en_US').format(clock);
      final time = DateFormat('HH:mm').format(clock);
      final slotKey = AppTimeService.bookingSlotKey(visit.startAt);
      final template = templates['booking_confirm'] ?? SettingsService.defaultBookingConfirmSms;
      final body = template
          .replaceAll('{name}', name)
          .replaceAll('{date}', date)
          .replaceAll('{time}', time)
          .replaceAll('{address}', ctrl.workAddress.trim())
          .replaceAll('{review}', '')
          .replaceAll('{appliance}', '')
          .trim();

      // Пункт 13: SMS уходит только после явного подтверждения владельца,
      // и владелец видит текст до отправки.
      if (!mounted) return;
      final confirmed = await showConfirmCancelSheet(
        context,
        title: visit.bookingSmsState == 'sent'
            ? 'SMS уже отправлено. Отправить повторно?'.tr
            : 'Отправить SMS клиенту?'.tr,
        message: '$phone\n\n$body',
        confirmLabel: 'Отправить'.tr,
      );
      if (!confirmed || !mounted) return;
      final current = _currentBookingVisit(visit);
      if (current == null || current.bookingSmsState == 'sending') return;
      visit = current;
      if (ctrl.isCommitting || !await ctrl.commitChanges()) return;
      final key = '${visit.id}|$slotKey';
      if (visit.bookingSmsState == 'approved' && visit.smsBooking['requestId'] is String) {
        _bookingRequestIds[key] = visit.smsBooking['requestId'] as String;
      } else if (visit.bookingSmsState == 'sent' ||
          (visit.bookingSmsState == 'error' && visit.smsBooking['retryAllowed'] == true)) {
        _bookingRequestIds.remove(key);
      }
      final requestId = _bookingRequestIds.putIfAbsent(key, () => FirebaseFirestore.instance
          .collection('companies').doc(kCompanyId).collection('messages').doc().id);
      // Пункт 18: если клиент уже подтвердил заказ, отправка SMS не должна
      // сбрасывать статус обратно в «Заказ не принят».
      final ok = await SmsService.sendSms(
        to: phone,
        body: body,
        clientId: ctrl.clientId,
        visitBooking: {
          'jobId': ctrl.jobId,
          'visitId': visit.id,
          'slotKey': slotKey,
          'requestId': requestId,
        },
      );
      if (ok) _bookingRequestIds.remove(key);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok
              ? 'SMS с подтверждением визита отправлено'.tr
              : SmsService.failureText()),
          backgroundColor: ok ? Colors.green : Colors.orange.shade800,
        ),
      );
    } finally {
      if (mounted) setState(() => _bookingBusy = false);
    }
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
            _reviewBanner(),
            const SizedBox(height: 16),
          ],
          if (_twinJob != null) ...[
            _buildDuplicateBanner(_twinJob!),
            const SizedBox(height: 16),
          ],
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _buildStatusButton()),
                const SizedBox(width: 8),
                Expanded(child: _buildClientIconButton()),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _buildJobSiteAndCallsRow(),
          const SizedBox(height: 12),
          _buildVisitsCard(),
          if (!ctrl.needsReview && _pendingSmsVisit != null) ...[
            const SizedBox(height: 12),
            _pendingSmsBanner(_pendingSmsVisit!),
          ],
          const SizedBox(height: 12),
          _buildContactActions(),
          const SizedBox(height: 12),
          _buildJobTiles(),
          if (_originalJob != null) ...[
            const SizedBox(height: 12),
            _buildOriginalJobLink(),
          ],
          if (_relatedJobs.isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildRelatedJobs(),
          ],
          if (_changes.isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildChangeHistory(),
          ],
        ],
      ),
    );
  }

  Widget _reviewBanner() {
    return Container(
              width: double.infinity,
              margin: EdgeInsets.zero,
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
                    _reviewBannerText(),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () => ctrl.markReviewed(),
                          icon: const Icon(Icons.check_rounded),
                          label: Text('Подтвердить'.tr),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF22C55E),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _rejectUnconfirmedJob,
                          icon: const Icon(Icons.close_rounded),
                          label: Text('Отменить'.tr),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFDC2626),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
  }

  /// Тот же номер и меньше двух суток между заявками. Входящие черновики
  /// сервер соединяет сам; здесь остаются случаи, где решает мастер.
  Widget _buildDuplicateBanner(Job twin) {
    final mergedInto = (ctrl.jobData['mergedIntoJobId'] ?? '')
        .toString()
        .trim()
        .isNotEmpty;
    final when = DateFormat(
      'd MMM, HH:mm',
      AppLocale.instance.dateLocale,
    ).format(twin.scheduledAt ?? twin.createdAt);
    final subtitle = [
      twin.clientName.trim(),
      trAny(twin.applianceType),
      when,
    ].where((part) => part.isNotEmpty).join(' · ');
    final color = mergedInto ? Colors.blueGrey : Colors.amber;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            mergedInto ? 'Соединено с заявкой'.tr : 'Похоже на дубляж'.tr,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            mergedInto
                ? subtitle
                : '${'Тот же номер'.tr} · $subtitle',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _openJobCard(twin),
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: Text('Открыть'.tr),
                ),
              ),
              if (!mergedInto) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _mergeBusy ? null : () => _mergeWithTwin(twin),
                    icon: _mergeBusy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.merge_rounded, size: 18),
                    label: Text('Соединить'.tr),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF22C55E),
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (!mergedInto)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _mergeBusy
                    ? null
                    : () => JobService.dismissDuplicateHint(ctrl.jobId),
                child: Text(
                  'Не дубляж'.tr,
                  style: TextStyle(color: Colors.grey.shade700),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _openJobCard(Job job) {
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
  }

  /// Главной остаётся заявка с визитом; если визита нет ни там, ни там —
  /// та, что пришла раньше (метку сервер ставит на более свежую).
  bool _keepCurrentJob(Job twin) {
    final mineHasVisit =
        ctrl.visits.any((visit) => visit.outcome != JobVisit.cancelled) ||
        ctrl.scheduledAt != null;
    final twinHasVisit =
        twin.coalescedVisits.any((visit) => visit.outcome != JobVisit.cancelled) ||
        twin.scheduledAt != null;
    if (mineHasVisit != twinHasVisit) return mineHasVisit;
    return false;
  }

  Future<void> _mergeWithTwin(Job twin) async {
    final keepCurrent = _keepCurrentJob(twin);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Соединить заявки?'.tr),
        content: Text(
          keepCurrent
              ? 'Данные второй заявки перейдут сюда, она закроется.'.tr
              : 'Данные этой заявки перейдут во вторую, эта закроется.'.tr,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Отмена'.tr),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Соединить'.tr),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _mergeBusy = true);
    final ok = await JobService.mergeDuplicate(
      keepId: keepCurrent ? ctrl.jobId : twin.id,
      dropId: keepCurrent ? twin.id : ctrl.jobId,
    );
    if (!mounted) return;
    setState(() => _mergeBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'Заявки соединены'.tr : 'Не удалось соединить'.tr),
      ),
    );
    // Эту заявку закрыли как дубль — смотреть больше нечего.
    if (ok && !keepCurrent) Navigator.pop(context);
  }

  Widget _routeButton() {
    final travelHint = ctrl.travelTime.trim();
    final showTravelHint =
        travelHint.isNotEmpty && travelHint != 'GO' && travelHint != '...';
    final address = ctrl.workAddress.trim();
    return Tooltip(
      message: showTravelHint
          ? '${'Проложить маршрут'.tr} · $travelHint'
          : 'Проложить маршрут'.tr,
      child: _contactActionButton(
        onPressed: () => MapsService.openNavigator(address),
        onLongPress: address.isNotEmpty ? () => AppFeedback.copy(context, address) : null,
        background: AppColors.accent,
        foreground: Colors.black,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (ctrl.isLoadingTime)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.black,
                ),
              )
            else
              const _GoogleMapsLogoIcon(),
            const SizedBox(width: 6),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  ctrl.isLoadingTime
                      ? '...'
                      : (travelHint.isEmpty ? 'GO' : travelHint),
                  maxLines: 1,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Лучший доступный телефон: сначала contactPhone, затем первый из chatContacts.
  String _bestContactPhone() {
    final direct = ctrl.contactPhone.trim();
    if (direct.isNotEmpty) return direct;
    for (final c in ctrl.chatContacts) {
      if (c.normalizedPhone.length >= 10) return c.phone.trim();
    }
    return '';
  }

  Widget _callButton() {
    final phone = _bestContactPhone();
    return _contactActionButton(
      onPressed: _callSelected,
      onLongPress: phone.isNotEmpty ? () => AppFeedback.copy(context, phone) : null,
      background: const Color(0xFF008F3B),
      foreground: Colors.white,
      child: const Icon(Icons.phone, size: 28, color: Colors.white),
    );
  }

  Widget _smsButton() {
    final phone = _bestContactPhone();
    return _contactActionButton(
      onPressed: _smsSelected,
      onLongPress: phone.isNotEmpty ? () => AppFeedback.copy(context, phone) : null,
      background: const Color(0xFF1E88E5),
      foreground: Colors.white,
      child: const Icon(Icons.sms, size: 28, color: Colors.white),
    );
  }

  Widget _buildJobSiteAndCallsRow() {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _sitePiece()),
          const SizedBox(width: 8),
          Expanded(child: _recordingPiece()),
        ],
      ),
    );
  }

  Widget _buildContactActions() {
    return Row(
      children: [
        Expanded(child: _routeButton()),
        const SizedBox(width: 8),
        Expanded(child: _callButton()),
        const SizedBox(width: 8),
        Expanded(child: _smsButton()),
      ],
    );
  }

  Widget _contactActionButton({
    required VoidCallback onPressed,
    required Widget child,
    required Color background,
    required Color foreground,
    VoidCallback? onLongPress,
  }) {
    return SizedBox(
      height: 56,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onPressed,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Align(
              alignment: Alignment.center,
              child: DefaultTextStyle.merge(
                style: TextStyle(
                  color: foreground,
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _jobSource() => Job.intakeSourceOf(ctrl.jobData);

  String _reviewBannerText() {
    switch (_jobSource()) {
      case 'email':
        return context.tr(
          'Заявка с почты. Проверьте данные, подтвердите или отмените.',
          'Job from email. Check the details, confirm or cancel.',
        );
      case 'website':
        return context.tr(
          'Заявка с сайта. Проверьте данные, подтвердите или отмените.',
          'Job from the website. Check the details, confirm or cancel.',
        );
      case 'sms':
        return context.tr(
          'Заявка из SMS. Проверьте данные, подтвердите или отмените.',
          'Job from SMS. Check the details, confirm or cancel.',
        );
      default:
        return context.tr(
          'Заявка с телефона. Проверьте данные, подтвердите или отмените.',
          'Job from a phone call. Check the details, confirm or cancel.',
        );
    }
  }

  Future<void> _rejectUnconfirmedJob() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Отменить заявку?'.tr),
        content: Text(
          'Заявка попадёт в корзину на 30 дней.'.tr,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Нет'.tr),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
            ),
            child: Text('Отменить'.tr),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    await ctrl.rejectUnconfirmed();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  DateTime? _callWhen(Map<String, dynamic> item) {
    return CallRecord.parseStamp(item['startTime']) ??
        CallRecord.parseStamp(item['uploadedAt']) ??
        CallRecord.parseStamp(item['createdAt']);
  }

  bool _callInbound(Map<String, dynamic> item) {
    final direction = (item['direction'] ?? '').toString().toLowerCase();
    return direction != 'outbound';
  }

  Future<void> _openJobCalls() async {
    final items = ctrl.callItems;
    if (items.isEmpty) return;
    if (items.length == 1) {
      await openCallRecordingSheet(
        context,
        items.last,
        jobId: ctrl.jobId,
      );
      return;
    }
    final chosen = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      useRootNavigator: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Звонки по заявке'.tr,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 8),
                for (final item in items.reversed)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      _callInbound(item) ? Icons.call_received : Icons.call_made,
                      color: _callInbound(item)
                          ? const Color(0xFF008F3B)
                          : AppColors.primary,
                    ),
                    title: Text(
                      _callWhen(item) == null
                          ? 'Звонок'.tr
                          : Formatters.formatDateTime(_callWhen(item)),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      _callInbound(item)
                          ? 'Клиент звонил'.tr
                          : 'Мы звонили'.tr,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.pop(sheetContext, item),
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || chosen == null) return;
    await openCallRecordingSheet(context, chosen, jobId: ctrl.jobId);
  }

  Widget _sitePiece() {
    final clientName = (ctrl.jobData['clientName'] ?? '').toString().trim();
    final siteName = ctrl.hasJobSite
        ? (ctrl.jobSiteName.isEmpty
            // Другого человека на месте не назвали — там сам клиент.
            ? (clientName.isEmpty ? 'Контакт на адресе'.tr : clientName)
            : ctrl.jobSiteName)
        : (clientName.isEmpty ? 'Клиент'.tr : clientName);
    return _compactSiteNameCard(name: siteName, onTap: _editJobSite);
  }

  Widget _recordingPiece() {
    final callItems = ctrl.callItems;
    final lastCall = callItems.isEmpty ? null : callItems.last;
    return _compactRecordingCard(
      source: _jobSource(),
      when: lastCall == null ? null : _callWhen(lastCall),
      inbound: lastCall == null ? true : _callInbound(lastCall),
      extraCount: callItems.length > 1 ? callItems.length - 1 : 0,
      onTap: lastCall != null
          ? _openJobCalls
          : (_jobSource() == 'email' || _jobSource() == 'website'
              ? () => openSourceEmailSheet(
                    context,
                    jobData: ctrl.jobData,
                    jobId: ctrl.jobId,
                    clientId: ctrl.clientId,
                    clientName: (ctrl.jobData['clientName'] ?? '').toString(),
                    clientEmail: ctrl.clientEmail,
                  )
              : null),
    );
  }

  Widget _compactSiteNameCard({
    required String name,
    VoidCallback? onTap,
  }) {
    final canCopy = name.isNotEmpty && name != 'Клиент'.tr && name != 'Контакт на адресе'.tr;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        onLongPress: canCopy ? () => AppFeedback.copy(context, name) : null,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Где работа'.tr,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                name,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                  height: 1.15,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _compactRecordingCard({
    VoidCallback? onTap,
    String source = '',
    DateTime? when,
    bool inbound = true,
    int extraCount = 0,
  }) {
    final hasWhen = when != null;
    final sourceLabel = Job.intakeSourceLabel(source);
    final sourceColor = Job.intakeSourceColor(source);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.mic, color: Colors.black, size: 20),
              ),
              if (sourceLabel.isNotEmpty) ...[
                const SizedBox(height: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: sourceColor.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Job.intakeSourceIcon(source),
                        size: 13,
                        color: sourceColor,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        sourceLabel.tr,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.1,
                          fontWeight: FontWeight.w800,
                          color: sourceColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 6),
              if (hasWhen) ...[
                Text(
                  inbound ? 'Клиент звонил'.tr : 'Мы звонили'.tr,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.1,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  Formatters.formatDate(when),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.15,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1A1A1A),
                  ),
                ),
                Text(
                  Formatters.formatTime(when),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  style: const TextStyle(
                    fontSize: 16,
                    height: 1.1,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1A1A1A),
                  ),
                ),
                if (extraCount > 0)
                  Text(
                    '+$extraCount',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                    ),
                  ),
              ] else
                Text(
                  'Запись разговора'.tr,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.15,
                    fontWeight: FontWeight.w800,
                    color: Colors.grey.shade700,
                  ),
                ),
            ],
          ),
        ),
      ),
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

  Widget _buildChangeHistory() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'История'.tr,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: Colors.black54,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
              BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2)),
            ],
          ),
          child: Column(
            children: [
              for (var i = 0; i < _changes.length; i++)
                _buildChangeRow(_changes[i], showDivider: i < _changes.length - 1),
            ],
          ),
        ),
      ],
    );
  }

  String _changeLabel(JobChangeEvent e) {
    switch (e.event) {
      case 'created': return '${'Создана'.tr}: ${e.data['detail'] ?? ''}';
      case 'status_changed': return '${e.data['from'] ?? ''} → ${e.data['to'] ?? ''}';
      case 'client_name_set': return '${'Имя'.tr}: ${e.data['value'] ?? ''}';
      case 'visit_added': return '${'Визит добавлен'.tr}: ${e.data['slot'] ?? ''}';
      case 'visit_moved': return '${'Визит перенесён'.tr}: ${e.data['from'] ?? ''} → ${e.data['to'] ?? ''}';
      case 'visit_confirmed': return '${'Клиент подтвердил'.tr}: ${e.data['slot'] ?? ''}';
      case 'visit_cancelled': return '${'Клиент отменил'.tr}: ${e.data['slot'] ?? ''}';
      case 'payment_recorded': return '${'Оплата'.tr} \$${(e.data['amount'] as num?)?.toStringAsFixed(0) ?? ''} (${e.data['method'] ?? ''})';
      case 'tip_recorded': return '${'Чаевые'.tr} \$${(e.data['amount'] as num?)?.toStringAsFixed(0) ?? ''}';
      case 'refund_recorded': return '${'Возврат'.tr} \$${(e.data['amount'] as num?)?.toStringAsFixed(0) ?? ''}';
      case 'invoice_fully_paid': return 'Счёт полностью оплачен'.tr;
      case 'merged_duplicate': return '${'Соединено с дубляжом'.tr}${e.data['detail'] == null || e.data['detail'].toString().isEmpty ? '' : ': ${trAny(e.data['detail'])}'}';
      case 'merged_into': return 'Дубляж — соединено с другой заявкой'.tr;
      default: return e.event;
    }
  }

  String _byLabel(String by) {
    switch (by) {
      case 'secretary': return 'Секретарь'.tr;
      case 'sms': return 'SMS'.tr;
      case 'email': return 'Почта'.tr;
      case 'stripe': return 'Stripe';
      case 'client': return 'Клиент'.tr;
      default: return 'Вы'.tr;
    }
  }

  Widget _buildChangeRow(JobChangeEvent e, {required bool showDivider}) {
    final label = _changeLabel(e);
    final by = _byLabel(e.by);
    final time = DateFormat('d MMM HH:mm', AppLocale.instance.dateLocale).format(e.at);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                by,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              const SizedBox(width: 6),
              Text(
                time,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
              ),
            ],
          ),
        ),
        if (showDivider)
          const Divider(height: 1, indent: 16, color: Colors.black12),
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
        IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close, color: Colors.redAccent),
          tooltip: 'Отмена'.tr,
        ),
        IconButton(
          onPressed: _save,
          icon: const Icon(Icons.check_rounded, color: Color(0xFF22C55E)),
          tooltip: 'Сохранить'.tr,
        ),
      ],
    );
  }
}

class _GoogleMapsLogoIcon extends StatelessWidget {
  const _GoogleMapsLogoIcon();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 28,
      height: 28,
      child: CustomPaint(painter: _GoogleMapsLogoPainter()),
    );
  }
}

class _GoogleMapsLogoPainter extends CustomPainter {
  const _GoogleMapsLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2;
    final pin = Path()
      ..moveTo(cx, h)
      ..cubicTo(w * 0.04, h * 0.58, w * 0.04, h * 0.08, cx, h * 0.08)
      ..cubicTo(w * 0.96, h * 0.08, w * 0.96, h * 0.58, cx, h)
      ..close();
    canvas.drawPath(pin, Paint()..color = const Color(0xFFE53935));
    canvas.drawCircle(
      Offset(cx, h * 0.34),
      w * 0.18,
      Paint()..color = const Color(0xFF6D1B16),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
