import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../../core/app_feedback.dart';
import '../../../../core/constants.dart';
import '../../../../core/motion.dart';
import '../../../../core/utils/app_date_picker.dart';
import '../../../../core/utils/thumb_image.dart';
import '../../../../models/job.dart';
import '../../../../services/services.dart';
import '../../../calls/call_screen.dart';
import '../../../messages/conversation_screen.dart';
import '../job_details_controller.dart';
import '../job_details_screen.dart';
import '../editors/job_tile_editors.dart';
import '../editors/call_recording_page.dart';
import '../editors/source_email_page.dart';
import '../../../../core/l10n/app_locale.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../shared/stale_routes.dart';
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
    return ctrl.hasJobSite && site.isNotEmpty
        ? site
        : owner.isNotEmpty
        ? owner
        : site;
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
      sheetAnimationStyle: AppMotion.sheet,
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
                      child: Text(
                        'Выберите статус'.tr,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                          color: Color(0xFF1A1A1A),
                        ),
                      ),
                    ),
                    const Divider(height: 1),
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
                              if (_statusNeedsNewDate(status)) {
                                await _editVisit(followUpStatus: status);
                              } else if (_shouldCompleteJob(status)) {
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

  /// «Дата визита» — только календарь, время и галочка SMS: правим дату/время
  /// этого визита (или ставим первый), статус заявки не меняется.
  /// [followUpStatus] — «Установка» / «Повторный визит» из меню статусов:
  /// эта заявка остаётся на своей дате, а на новую дату создаётся отдельная
  /// заявка с этим статусом.
  Future<void> _editVisit({JobVisit? existing, String? followUpStatus}) async {
    final followUp = followUpStatus != null && existing == null;
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
        ).add(const Duration(days: 7));
    if (existing == null && startAt.isBefore(now)) {
      startAt = now.add(const Duration(days: 1));
    }
    final canSms = _bookingPhone.isNotEmpty && !ctrl.needsReview;
    var sendSms = canSms && existing == null;
    final statusLabel = followUp
        ? trAny(StatusService.labelOf(followUpStatus))
        : '';

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheet) {
            return SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      followUp ? statusLabel : 'Дата визита'.tr,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                    if (followUp)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Эта заявка останется на своей дате, а на новую дату создастся отдельная заявка с этим статусом.'
                              .tr,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            color: Color(0xFF3D3D3D),
                          ),
                        ),
                      ),
                    const Divider(height: 16),
                    Text(
                      appDateTimeLabel(startAt),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _visitPickerBox(
                      icon: Icons.calendar_month_rounded,
                      title: 'Дата'.tr,
                      child: AppDateTimePanel(
                        value: startAt,
                        firstDate: DateTime(now.year - 1),
                        lastDate: DateTime(now.year + 2),
                        showTime: false,
                        onChanged: (v) => setSheet(() => startAt = v),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _visitPickerBox(
                      icon: Icons.schedule_rounded,
                      title: 'Время'.tr,
                      child: AppTimeWheel(
                        value: startAt,
                        height: 120,
                        onChanged: (v) => setSheet(() => startAt = v),
                      ),
                    ),
                    const SizedBox(height: 4),
                    CheckboxListTile(
                      value: sendSms,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(
                        'Отправить SMS с подтверждением визита'.tr,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: Color(0xFF1A1A1A),
                        ),
                      ),
                      subtitle: canSms
                          ? null
                          : Text(
                              _bookingPhone.isEmpty
                                  ? 'Нет телефона для SMS'.tr
                                  : 'Сначала нажмите «Проверено» — потом можно слать SMS.'
                                        .tr,
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.orange.shade800,
                              ),
                            ),
                      onChanged: canSms
                          ? (value) => setSheet(() => sendSms = value ?? false)
                          : null,
                    ),
                    SizedBox(
                      height: 52,
                      child: ElevatedButton.icon(
                        onPressed: () => Navigator.pop(sheetContext, true),
                        icon: const Icon(Icons.check_circle, size: 22),
                        label: Text(
                          followUp ? 'Заказ принят'.tr : 'Сохранить'.tr,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF22C55E),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
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
    if (saved != true) return;

    if (existing != null) {
      final visit = existing.copyWith(startAt: startAt);
      await ctrl.updateVisit(visit, correction: true);
      if (!await ctrl.commitChanges() || !mounted) return;
      if (sendSms && visit.isScheduled) await _resendVisitBookingSms(visit);
      return;
    }

    // Кнопка «Заказ принят»: визит сразу помечается подтверждённым.
    final visit = JobVisit.create(
      startAt: startAt,
      durationMinutes: ctrl.durationMinutes,
      note: followUp ? followUpStatus : '',
    ).withManualConfirm(JobVisit.confirmConfirmed);
    if (followUp && ctrl.visits.isNotEmpty) {
      final newJobId = await ctrl.rescheduleToNewJob(visit, followUpStatus);
      if (!mounted) return;
      if (newJobId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Не удалось создать заявку на новую дату'.tr),
            backgroundColor: Colors.orange.shade800,
          ),
        );
        return;
      }
      if (sendSms) {
        await _resendVisitBookingSms(visit, jobId: newJobId);
        if (!mounted) return;
      }
      final newJob = await JobService.getById(newJobId);
      if (newJob != null && mounted) _openJobCard(newJob);
      return;
    }
    // Заявка без даты: визит ставится в неё же. Статус не трогаем, кроме
    // выбранного в меню «Установка» / «Повторный визит».
    await ctrl.saveVisits([...ctrl.visits, visit]);
    if (followUp) await ctrl.updateStatus(followUpStatus);
    if (!await ctrl.commitChanges() || !mounted) return;
    if (sendSms) await _resendVisitBookingSms(visit);
  }

  /// Всё про саму работу — одним листом вместо россыпи плиток:
  /// описание и фото — рядом, мелочи — одной строкой из трёх ячеек.
  Widget _buildWorkSection() {
    final fromEmail = Job.intakeSourceOf(ctrl.jobData) == 'email';
    final line = Colors.grey.shade200;
    final divider = Divider(height: 1, thickness: 1, color: line);
    final split = VerticalDivider(width: 1, thickness: 1, color: line);
    return Material(
      color: Colors.white,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _descriptionRow()),
                split,
                Expanded(child: _photosRow()),
              ],
            ),
          ),
          divider,
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _workCell(
                    icon: Icons.timer_outlined,
                    title: 'Длительность'.tr,
                    value: _visitDurationLabel(ctrl.durationMinutes),
                    onTap: _pickVisitDuration,
                  ),
                ),
                split,
                Expanded(child: _packingCell()),
                split,
                Expanded(child: _trackingCell()),
              ],
            ),
          ),
          if (fromEmail) ...[divider, _emailRow()],
        ],
      ),
    );
  }

  Widget _workRow({
    required IconData icon,
    required String title,
    required Widget child,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
  }) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: AppColors.primary),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            child,
          ],
        ),
      ),
    );
  }

  Widget _workCell({
    required IconData icon,
    required String title,
    required String value,
    VoidCallback? onTap,
    bool muted = false,
    String? copyValue,
  }) {
    final valueToCopy = copyValue ?? value;
    final canCopy = valueToCopy.isNotEmpty && valueToCopy != '—';
    return InkWell(
      onTap: onTap,
      onLongPress: canCopy
          ? () => AppFeedback.copy(context, valueToCopy)
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 10, 6, 10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 16, color: AppColors.primary),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              value,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                height: 1.2,
                fontWeight: FontWeight.w700,
                color: muted ? Colors.grey : Colors.black87,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _descriptionRow() {
    final description = ctrl.currentDescription.trim();
    final empty = description.isEmpty || description == 'Нет описания';
    return _workRow(
      icon: Icons.notes,
      title: 'Описание'.tr,
      onTap: () => openDescriptionEditor(context, ctrl),
      onLongPress: empty ? null : () => AppFeedback.copy(context, description),
      child: Text(
        empty ? 'Нажмите, чтобы описать неисправность'.tr : description,
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          height: 1.25,
          fontWeight: FontWeight.w600,
          color: empty ? Colors.grey : Colors.black87,
        ),
      ),
    );
  }

  Widget _photosRow() {
    final photos = ctrl.attachments.where((item) {
      final kind = (item['kind'] ?? '').toString();
      return kind != 'call' && kind != 'signature';
    }).toList();
    final count = photos.length;
    // Половина ширины: три миниатюры влезают и на узком телефоне.
    // LayoutBuilder тут нельзя — ячейка внутри IntrinsicHeight.
    const thumb = 42.0;
    const gap = 4.0;
    const fit = 3;
    final Widget body;
    if (ctrl.isUploadingImage) {
      body = Text(
        'Загрузка...'.tr,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      );
    } else if (count == 0) {
      body = Text(
        'Нажмите, чтобы добавить фото'.tr,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Colors.grey,
        ),
      );
    } else {
      final shown = count < fit ? count : fit;
      final hidden = count - shown;
      body = Row(
        children: [
          for (var i = 0; i < shown; i++) ...[
            if (i > 0) const SizedBox(width: gap),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: thumb,
                height: thumb,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_tileImage(photos[i]) case final image?)
                      Image(image: image, fit: BoxFit.cover)
                    else
                      ColoredBox(
                        color: Colors.grey.shade200,
                        child: Icon(
                          Icons.image_outlined,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    if (hidden > 0 && i == shown - 1)
                      ColoredBox(
                        color: Colors.black54,
                        child: Center(
                          child: Text(
                            '+$hidden',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      );
    }
    return _workRow(
      icon: Icons.photo_camera_outlined,
      title: count == 0 ? 'Фото'.tr : '${'Фото'.tr} · $count',
      onTap: () => openPhotosEditor(context, ctrl),
      child: body,
    );
  }

  Widget _packingCell() {
    final packingItems = packingItemsFromNotes(ctrl.packingNotes);
    final packing = packingItems.isEmpty
        ? ''
        : packingItems.length == 1
        ? packingItems.first
        : '${packingItems.length}';
    return _workCell(
      icon: Icons.inventory_2_outlined,
      title: 'С собой'.tr,
      value: packing.isEmpty ? '—' : packing,
      muted: packing.isEmpty,
      onTap: () => openPackingEditor(context, ctrl),
    );
  }

  Widget _trackingCell() {
    final tracking = ctrl.trackingNumber.isEmpty
        ? ''
        : [
            ctrl.trackingNumber,
            if (ctrl.trackingStatus.isNotEmpty)
              _trackingLabel(ctrl.trackingStatus),
          ].join(' · ');
    return _workCell(
      icon: Icons.local_shipping_outlined,
      title: 'Отслеживание'.tr,
      value: tracking.isEmpty ? '—' : tracking,
      copyValue: ctrl.trackingNumber.isNotEmpty ? ctrl.trackingNumber : null,
      muted: tracking.isEmpty,
      onTap: _editTracking,
    );
  }

  Widget _emailRow() {
    final emailSubject = (ctrl.jobData['sourceEmailSubject'] ?? '')
        .toString()
        .trim();
    final emailPreview = (ctrl.jobData['sourceEmailPreview'] ?? '')
        .toString()
        .trim();
    final emailFrom = (ctrl.jobData['sourceEmailFrom'] ?? '').toString().trim();
    return _workRow(
      icon: Icons.email_outlined,
      title: context.tr('Письмо', 'Email'),
      onTap: () => openSourceEmailSheet(
        context,
        jobData: ctrl.jobData,
        jobId: ctrl.jobId,
        clientId: ctrl.clientId,
        clientName: (ctrl.jobData['clientName'] ?? '').toString(),
        clientEmail: ctrl.clientEmail,
      ),
      child: Text(
        emailSubject.isNotEmpty
            ? emailSubject
            : (emailFrom.isNotEmpty
                  ? emailFrom
                  : (emailPreview.isNotEmpty
                        ? emailPreview
                        : context.tr('Открыть письмо', 'Open the email'))),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
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

  ({String type, String brand, String model}) _applianceSummary() {
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
    return (type: type, brand: brand.trim(), model: model.trim());
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

  /// Сравнение «на глаз»: регистр и лишние пробелы ничего не значат.
  static String _flatText(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  static bool _sameText(String a, String b) => _flatText(a) == _flatText(b);

  /// «123 Main St., Toronto» и «123 Main St Toronto» — одно место.
  static bool _sameAddress(String a, String b) =>
      _flatText(a.replaceAll(RegExp(r'[.,]'), ' ')) ==
      _flatText(b.replaceAll(RegExp(r'[.,]'), ' '));

  Future<void> _editJobSite() async {
    final clientName = (ctrl.jobData['clientName'] ?? '').toString().trim();
    final clientPhone = (ctrl.jobData['clientPhone'] ?? '').toString().trim();
    final clientAddress = (ctrl.jobData['clientAddress'] ?? '')
        .toString()
        .trim();
    final clientEmail = ctrl.clientEmail.trim();

    // Пустое поле места работы берём из карточки клиента — по каждому полю
    // отдельно. Раньше подстановка была «всё или ничего»: заявка, где знали
    // имя на месте, но не адрес, открывалась с пустым адресом, и кнопка «OK»
    // требовала вписать его руками.
    String orClient(String own, String fromClient) =>
        own.trim().isEmpty ? fromClient : own.trim();

    final nameCtrl = TextEditingController(
      text: orClient(ctrl.jobSiteName, clientName),
    );
    final phoneCtrl = TextEditingController(
      text: orClient(ctrl.jobSitePhone, clientPhone),
    );
    final emailCtrl = TextEditingController(
      text: orClient(ctrl.jobSiteEmail, clientEmail),
    );
    final parts = splitAddress(orClient(ctrl.jobSiteAddress, clientAddress));
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
                          const Icon(
                            Icons.error_outline,
                            color: Colors.red,
                            size: 18,
                          ),
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
                        // Что совпало с карточкой клиента — в заявку не пишем:
                        // пусть подставляется на лету, тогда правка карточки
                        // клиента сразу видна в заявке.
                        final siteName = _sameText(nameCtrl.text, clientName)
                            ? ''
                            : nameCtrl.text.trim();
                        final sitePhone =
                            SmsService.normalizePhone(phoneCtrl.text) ==
                                SmsService.normalizePhone(clientPhone)
                            ? ''
                            : phoneCtrl.text.trim();
                        final siteEmail = _sameText(emailCtrl.text, clientEmail)
                            ? ''
                            : emailCtrl.text.trim();
                        final siteAddress = _sameAddress(address, clientAddress)
                            ? ''
                            : address;
                        if (siteName.isEmpty &&
                            sitePhone.isEmpty &&
                            siteEmail.isEmpty &&
                            siteAddress.isEmpty) {
                          ctrl.clearJobSite();
                        } else {
                          ctrl.updateJobSite(
                            name: siteName,
                            phone: sitePhone,
                            address: siteAddress,
                            email: siteEmail,
                          );
                        }
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

  /// Рамка с заголовком в окне визита: календарь и часы — отдельными блоками.
  Widget _visitPickerBox({
    required IconData icon,
    required String title,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: AppColors.primary),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          child,
        ],
      ),
    );
  }

  /// «Установка» и «Повторный визит» — это новый выезд: сразу дата, время и SMS.
  /// Остальные статусы дату карточки не трогают.
  bool _statusNeedsNewDate(String status) =>
      status == JobStatuses.repeatVisit || JobStatuses.isInstallStatus(status);

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
    final template = templates['job_done'] ?? SettingsService.defaultJobDoneSms;
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

  /// Верх карточки: что чиним — слева и крупно, где заказ сейчас — справа.
  Widget _buildTopRow() {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 11, child: _buildApplianceHero()),
          const SizedBox(width: 8),
          Expanded(
            flex: 9,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _buildStatusButton()),
                const SizedBox(height: 6),
                Expanded(child: _buildOrderConfirmStrip(_orderConfirmVisit)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildApplianceHero() {
    final appliance = _applianceSummary();
    final model = appliance.model;
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: InkWell(
        onTap: () => openApplianceEditor(context, ctrl),
        onLongPress: model.isNotEmpty
            ? () => AppFeedback.copy(context, model)
            : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              AppliancePicture(type: appliance.type, size: 72),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      trAny(appliance.type),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        height: 1.1,
                      ),
                    ),
                    if (appliance.brand.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        appliance.brand,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: AppColors.primary,
                        ),
                      ),
                    ],
                    const SizedBox(height: 2),
                    Text(
                      model.isNotEmpty ? model : 'Модель не указана'.tr,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                        color: model.isNotEmpty
                            ? Colors.grey.shade700
                            : Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusButton() {
    final color = ctrl.getStatusColor();
    final onColor = color.computeLuminance() > 0.55
        ? Colors.black
        : Colors.white;
    return Material(
      color: color,
      elevation: 1,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: _showStatusMenu,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 2, 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Статус'.tr,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: onColor.withValues(alpha: 0.8),
                      ),
                    ),
                    Text(
                      trAny(StatusService.labelOf(ctrl.currentStatus)),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        height: 1.1,
                        color: onColor,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.arrow_drop_down, color: onColor),
            ],
          ),
        ),
      ),
    );
  }

  /// Дата визита — шкала переносов: слева первое время (старт), правее
  /// каждый перенос, последним — текущий визит.
  Widget _buildVisitsCard() {
    final visits = ctrl.visits;
    final hasVisits = visits.isNotEmpty;
    final accent = hasVisits ? AppColors.primary : Colors.orange.shade800;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: hasVisits
            ? AppColors.primary.withValues(alpha: 0.06)
            : Colors.orange.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: hasVisits
              ? AppColors.primary.withValues(alpha: 0.25)
              : Colors.orange.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.calendar_month_rounded, size: 16, color: accent),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  'Дата визита'.tr,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: accent,
                  ),
                ),
              ),
              if (visits.length > 1)
                Text(
                  '${'Визитов'.tr}: ${visits.length}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade600,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (!hasVisits)
            InkWell(
              onTap: () => _editVisit(),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  'Не запланировано'.tr,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    color: Colors.orange.shade800,
                  ),
                ),
              ),
            )
          else
            _visitTimeline(visits, _orderConfirmVisit),
          if (ctrl.currentStatus == JobStatuses.waitingPart &&
              !visits.any((visit) => visit.isScheduled))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Ожидание запчасти — дату возврата ставить не нужно. Когда запчасть приедет — статус → «Установка».'
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
    );
  }

  Widget _visitTimeline(List<JobVisit> visits, JobVisit? current) {
    var currentIndex = current == null
        ? -1
        : visits.indexWhere((visit) => visit.id == current.id);
    if (currentIndex < 0) currentIndex = visits.length - 1;
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = visits.length;
        final share = constraints.maxWidth / count;
        final nodeWidth = share < 96 ? 96.0 : share;
        final row = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < count; i++)
              SizedBox(
                width: nodeWidth,
                child: _visitNode(
                  visits[i],
                  index: i,
                  count: count,
                  currentIndex: currentIndex,
                ),
              ),
          ],
        );
        if (nodeWidth * count <= constraints.maxWidth + 0.5) return row;
        // Не влезает — листается вбок, текущий визит (справа) сразу виден.
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: true,
          child: row,
        );
      },
    );
  }

  Widget _visitNode(
    JobVisit visit, {
    required int index,
    required int count,
    required int currentIndex,
  }) {
    final isCurrent = index == currentIndex;
    final note = visit.note.trim();
    const doneColor = Color(0xFF2E7D32);
    const cancelColor = Color(0xFFC62828);
    final Color dotColor;
    final Color captionColor;
    final String caption;
    IconData? icon;
    if (isCurrent) {
      dotColor = AppColors.primary;
      captionColor = AppColors.primary;
      caption = count == 1 ? note : 'Сейчас'.tr;
    } else if (visit.isDone) {
      dotColor = doneColor;
      captionColor = doneColor;
      caption = note.isNotEmpty ? note : 'Выполнен'.tr;
      icon = Icons.check;
    } else if (visit.isCancelled) {
      dotColor = cancelColor;
      captionColor = cancelColor;
      caption = 'Отменён'.tr;
      icon = Icons.close;
    } else {
      dotColor = Colors.grey.shade500;
      captionColor = Colors.grey.shade600;
      caption = index == 0 ? 'Старт'.tr : 'Перенос'.tr;
    }
    final struck = !isCurrent && !visit.isDone;
    final dotSize = isCurrent ? 18.0 : (icon != null ? 15.0 : 12.0);
    final lineDone = AppColors.primary.withValues(alpha: 0.55);
    final lineTodo = Colors.grey.shade300;
    Widget segment(bool show, bool done) => Expanded(
      child: Container(
        height: 2,
        color: show ? (done ? lineDone : lineTodo) : Colors.transparent,
      ),
    );
    final when = DateFormat(
      'd MMM',
      AppLocale.instance.dateLocale,
    ).format(visit.startAt);
    final time = DateFormat('HH:mm').format(visit.startAt);
    final textColor = isCurrent
        ? const Color(0xFF1A1A1A)
        : (visit.isDone ? Colors.black87 : Colors.grey.shade600);
    return InkWell(
      onTap: () => _editVisit(existing: visit),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Column(
          children: [
            SizedBox(
              height: 20,
              child: Row(
                children: [
                  segment(index > 0, index <= currentIndex),
                  Container(
                    width: dotSize,
                    height: dotSize,
                    decoration: BoxDecoration(
                      color: dotColor,
                      shape: BoxShape.circle,
                      border: isCurrent
                          ? Border.all(color: Colors.white, width: 3)
                          : null,
                      boxShadow: isCurrent
                          ? [
                              BoxShadow(
                                color: dotColor.withValues(alpha: 0.45),
                                blurRadius: 4,
                              ),
                            ]
                          : null,
                    ),
                    child: icon == null
                        ? null
                        : Icon(icon, size: dotSize - 5, color: Colors.white),
                  ),
                  segment(index < count - 1, index < currentIndex),
                ],
              ),
            ),
            const SizedBox(height: 3),
            if (caption.isNotEmpty)
              Text(
                caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  color: captionColor,
                ),
              ),
            Text(
              when,
              maxLines: 1,
              style: TextStyle(
                fontSize: isCurrent ? 14 : 12,
                fontWeight: isCurrent ? FontWeight.w900 : FontWeight.w700,
                color: textColor,
                decoration: struck ? TextDecoration.lineThrough : null,
              ),
            ),
            Text(
              time,
              maxLines: 1,
              style: TextStyle(
                fontSize: isCurrent ? 16 : 12,
                fontWeight: isCurrent ? FontWeight.w900 : FontWeight.w700,
                color: isCurrent ? AppColors.primary : textColor,
                decoration: struck ? TextDecoration.lineThrough : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOrderConfirmStrip(JobVisit? visit) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: visit == null ? null : () => _pickVisitConfirm(visit),
        borderRadius: BorderRadius.circular(12),
        child: VisitConfirmBadge.strip(visit, jobStatus: ctrl.currentStatus),
      ),
    );
  }

  Future<void> _pickVisitConfirm(JobVisit visit) async {
    final current = visit.effectiveConfirmStatus;
    final picked = await VisitConfirmBadge.pick(context, current: current);
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
          [
            'pending',
            'approved',
            'sending',
            'error',
          ].contains(visit.bookingSmsState)) {
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
                ? (visit.smsBooking['error'] ?? 'Не удалось отправить SMS'.tr)
                      .toString()
                : '${'Подтверждение визита ещё не отправлено'.tr}: $when',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: busy || unknown
                      ? null
                      : () => _resendVisitBookingSms(visit),
                  icon: const Icon(Icons.send_rounded, size: 20),
                  label: Text(
                    approved
                        ? 'Продолжить'.tr
                        : failed
                        ? 'Повторить'.tr
                        : 'Отправить'.tr,
                  ),
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
                  onPressed: busy || unknown || approved
                      ? null
                      : () => _dismissPendingSms(visit),
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
      if (visit.id == expected.id &&
          visit.isActiveSlot &&
          AppTimeService.bookingSlotKey(visit.startAt) ==
              AppTimeService.bookingSlotKey(expected.startAt)) {
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
        message:
            'Подтверждение для этого времени визита не будет отправлено.'.tr,
        confirmLabel: 'Не отправлять'.tr,
      );
      if (!ok || !mounted) return;
      final current = _currentBookingVisit(visit);
      if (current == null || current.bookingSmsInProgress) return;
      visit = current;
      final slotKey = AppTimeService.bookingSlotKey(visit.startAt);
      // copyWith не умеет обнулять smsBookingPendingAt, но сервер смотрит на флаг.
      await ctrl.updateVisit(
        visit.copyWith(
          smsBookingPending: false,
          smsBookingSlotKey: slotKey,
          smsBooking: {
            'state': 'rejected',
            'slotKey': slotKey,
            'decidedAt': DateTime.now(),
          },
        ),
      );
      await ctrl.commitChanges();
    } finally {
      if (mounted) setState(() => _bookingBusy = false);
    }
  }

  /// [jobId] — визит из другой заявки (новая заявка после «Перенос визита»):
  /// он уже записан, в черновике этой карточки его нет.
  Future<void> _resendVisitBookingSms(JobVisit visit, {String? jobId}) async {
    if (_bookingBusy || visit.bookingSmsState == 'sending') return;
    if (visit.bookingSmsState == 'error' &&
        visit.smsBooking['retryAllowed'] == false) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Результат отправки неизвестен — сначала проверьте переписку.'.tr,
          ),
        ),
      );
      return;
    }
    AppFeedback.haptic();
    final phone = _bookingPhone;
    if (phone.isEmpty || ctrl.needsReview) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            phone.isEmpty
                ? 'Нет телефона для SMS'.tr
                : 'Сначала нажмите «Проверено» — потом можно слать SMS.'.tr,
          ),
          backgroundColor: Colors.orange.shade800,
        ),
      );
      return;
    }
    setState(() => _bookingBusy = true);
    try {
      final templates = await SettingsService.loadSmsTemplates();
      final name = ctrl.contactName.trim().isEmpty
          ? 'there'
          : ctrl.contactName.trim();
      final clock = AppTimeService.bookingWallClock(visit.startAt);
      final date = DateFormat('MMMM d', 'en_US').format(clock);
      final time = DateFormat('HH:mm').format(clock);
      final slotKey = AppTimeService.bookingSlotKey(visit.startAt);
      final template =
          templates['booking_confirm'] ??
          SettingsService.defaultBookingConfirmSms;
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
      final current = jobId == null ? _currentBookingVisit(visit) : visit;
      if (current == null || current.bookingSmsState == 'sending') return;
      visit = current;
      if (jobId == null && (ctrl.isCommitting || !await ctrl.commitChanges())) {
        return;
      }
      final key = '${visit.id}|$slotKey';
      if (visit.bookingSmsState == 'approved' &&
          visit.smsBooking['requestId'] is String) {
        _bookingRequestIds[key] = visit.smsBooking['requestId'] as String;
      } else if (visit.bookingSmsState == 'sent' ||
          (visit.bookingSmsState == 'error' &&
              visit.smsBooking['retryAllowed'] == true)) {
        _bookingRequestIds.remove(key);
      }
      final requestId = _bookingRequestIds.putIfAbsent(
        key,
        () => FirebaseFirestore.instance
            .collection('companies')
            .doc(kCompanyId)
            .collection('messages')
            .doc()
            .id,
      );
      // Пункт 18: если клиент уже подтвердил заказ, отправка SMS не должна
      // сбрасывать статус обратно в «Заказ не принят».
      final ok = await SmsService.sendSms(
        to: phone,
        body: body,
        clientId: ctrl.clientId,
        visitBooking: {
          'jobId': jobId ?? ctrl.jobId,
          'visitId': visit.id,
          'slotKey': slotKey,
          'requestId': requestId,
        },
      );
      if (ok) _bookingRequestIds.remove(key);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? 'SMS с подтверждением визита отправлено'.tr
                : SmsService.failureText(),
          ),
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
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (ctrl.needsReview) ...[
                  _reviewBanner(),
                  const SizedBox(height: 12),
                ],
                if (_twinJob != null) ...[
                  _buildDuplicateBanner(_twinJob!),
                  const SizedBox(height: 12),
                ],
                _buildTopRow(),
                const SizedBox(height: 12),
                _buildJobSiteAndCallsRow(),
                const SizedBox(height: 10),
                _buildWorkSection(),
                const SizedBox(height: 12),
                _buildVisitsCard(),
                if (!ctrl.needsReview && _pendingSmsVisit != null) ...[
                  const SizedBox(height: 12),
                  _pendingSmsBanner(_pendingSmsVisit!),
                ],
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
          ),
        ),
        // Маршрут, звонок и SMS — всегда под пальцем, не уезжают с прокруткой.
        _buildContactActions(),
      ],
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
            mergedInto ? subtitle : '${'Тот же номер'.tr} · $subtitle',
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
        twin.coalescedVisits.any(
          (visit) => visit.outcome != JobVisit.cancelled,
        ) ||
        twin.scheduledAt != null;
    if (mineHasVisit != twinHasVisit) return mineHasVisit;
    return false;
  }

  Future<void> _mergeWithTwin(Job twin) async {
    final keepCurrent = _keepCurrentJob(twin);
    final confirmed = await showConfirmCancelSheet(
      context,
      title: 'Соединить заявки?'.tr,
      message: keepCurrent
          ? 'Данные второй заявки перейдут сюда, она закроется.'.tr
          : 'Данные этой заявки перейдут во вторую, эта закроется.'.tr,
      confirmLabel: 'Соединить'.tr,
    );
    if (!confirmed || !mounted) return;
    setState(() => _mergeBusy = true);
    final dropId = keepCurrent ? twin.id : ctrl.jobId;
    final ok = await JobService.mergeDuplicate(
      keepId: keepCurrent ? ctrl.jobId : twin.id,
      dropId: dropId,
    );
    if (mounted) {
      setState(() => _mergeBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? 'Заявки соединены'.tr : 'Не удалось соединить'.tr),
        ),
      );
    }
    // Дубль закрыт — смотреть больше нечего: снимаем все его карточки,
    // включая эту, если закрыли её.
    if (ok) StaleRoutes.dropJob(dropId);
  }

  /// Без адреса Google Maps открывается пустой формой поиска — лучше сказать
  /// об этом вслух и дать открыть «Где работа», чем делать вид, что едем.
  Future<void> _openNavigator() async {
    final address = ctrl.workAddress.trim();
    if (!MapsService.hasRoutableAddress(address)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('В заявке нет адреса — впишите, куда ехать'.tr),
          action: SnackBarAction(
            label: 'Адрес'.tr,
            onPressed: _editJobSite,
          ),
        ),
      );
      return;
    }
    final opened = await MapsService.openNavigator(address);
    if (opened || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Google Maps не нашла этот адрес'.tr)),
    );
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
        onPressed: _openNavigator,
        onLongPress: address.isNotEmpty
            ? () => AppFeedback.copy(context, address)
            : null,
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
      onLongPress: phone.isNotEmpty
          ? () => AppFeedback.copy(context, phone)
          : null,
      background: const Color(0xFF008F3B),
      foreground: Colors.white,
      child: const Icon(Icons.phone, size: 28, color: Colors.white),
    );
  }

  Widget _smsButton() {
    final phone = _bestContactPhone();
    return _contactActionButton(
      onPressed: _smsSelected,
      onLongPress: phone.isNotEmpty
          ? () => AppFeedback.copy(context, phone)
          : null,
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
    return Material(
      color: Colors.white,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              Expanded(child: _routeButton()),
              const SizedBox(width: 8),
              Expanded(child: _callButton()),
              const SizedBox(width: 8),
              Expanded(child: _smsButton()),
            ],
          ),
        ),
      ),
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
    final confirm = await showConfirmCancelSheet(
      context,
      title: 'Отменить заявку?'.tr,
      message: 'Заявка попадёт в корзину на 30 дней.'.tr,
      confirmLabel: 'Отменить'.tr,
      cancelLabel: 'Нет'.tr,
    );
    if (!confirm || !mounted) return;
    final jobId = ctrl.jobId;
    await ctrl.rejectUnconfirmed();
    StaleRoutes.dropJob(jobId);
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
      await openCallRecordingSheet(context, items.last, jobId: ctrl.jobId);
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
                      _callInbound(item)
                          ? Icons.call_received
                          : Icons.call_made,
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
                      _callInbound(item) ? 'Клиент звонил'.tr : 'Мы звонили'.tr,
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
    return _compactSiteNameCard(
      name: siteName,
      // Куда ехать. Своего адреса ремонта нет — работаем по адресу клиента.
      address: ctrl.workAddress.trim(),
      onTap: _editJobSite,
    );
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

  /// Узкая полоска: значок слева, мелкая подпись и строка значения.
  /// Под значением можно дать вторую, более мелкую строку — так в «Где работа»
  /// помещается и имя, и адрес.
  Widget _compactStrip({
    required Widget leading,
    required String caption,
    required String value,
    String subvalue = '',
    Color? subvalueColor,
    Widget? badge,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
  }) {
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          child: Row(
            children: [
              leading,
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            caption,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ),
                        if (badge != null) ...[const SizedBox(width: 4), badge],
                      ],
                    ),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.2,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                    if (subvalue.isNotEmpty)
                      Text(
                        subvalue,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.15,
                          fontWeight: FontWeight.w600,
                          color: subvalueColor ?? Colors.grey.shade700,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _compactSiteNameCard({
    required String name,
    String address = '',
    VoidCallback? onTap,
  }) {
    final realName =
        name.isNotEmpty &&
        name != 'Клиент'.tr &&
        name != 'Контакт на адресе'.tr;
    final copyText = [
      if (realName) name,
      if (address.isNotEmpty) address,
    ].join(', ');
    return _compactStrip(
      leading: Icon(
        Icons.location_on_outlined,
        size: 22,
        color: AppColors.primary,
      ),
      caption: 'Где работа'.tr,
      value: name,
      subvalue: address.isEmpty ? 'Адрес не указан'.tr : address,
      subvalueColor: address.isEmpty ? Colors.red.shade400 : null,
      onTap: onTap,
      onLongPress: copyText.isEmpty
          ? null
          : () => AppFeedback.copy(context, copyText),
    );
  }

  Widget _compactRecordingCard({
    VoidCallback? onTap,
    String source = '',
    DateTime? when,
    bool inbound = true,
    int extraCount = 0,
  }) {
    final sourceLabel = Job.intakeSourceLabel(source);
    final sourceColor = Job.intakeSourceColor(source);
    final caption = when == null
        ? 'Запись разговора'.tr
        : (inbound ? 'Клиент звонил'.tr : 'Мы звонили'.tr);
    final value = when == null
        ? (sourceLabel.isEmpty ? '—' : sourceLabel.tr)
        : [
            DateFormat('d MMM', AppLocale.instance.dateLocale).format(when),
            Formatters.formatTime(when),
            if (extraCount > 0) '+$extraCount',
          ].join(' · ');
    return _compactStrip(
      leading: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: AppColors.accent,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.mic, color: Colors.black, size: 16),
      ),
      caption: caption,
      value: value,
      badge: when != null && sourceLabel.isNotEmpty
          ? Icon(Job.intakeSourceIcon(source), size: 12, color: sourceColor)
          : null,
      onTap: onTap,
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
              BoxShadow(
                color: Colors.black12,
                blurRadius: 4,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            children: [
              for (var i = 0; i < _changes.length; i++)
                _buildChangeRow(
                  _changes[i],
                  showDivider: i < _changes.length - 1,
                ),
            ],
          ),
        ),
      ],
    );
  }

  String _changeLabel(JobChangeEvent e) {
    switch (e.event) {
      case 'created':
        return '${'Создана'.tr}: ${e.data['detail'] ?? ''}';
      case 'status_changed':
        return '${e.data['from'] ?? ''} → ${e.data['to'] ?? ''}';
      case 'client_name_set':
        return '${'Имя'.tr}: ${e.data['value'] ?? ''}';
      case 'visit_added':
        return '${'Визит добавлен'.tr}: ${e.data['slot'] ?? ''}';
      case 'visit_moved':
        return '${'Визит перенесён'.tr}: ${e.data['from'] ?? ''} → ${e.data['to'] ?? ''}';
      case 'visit_confirmed':
        return '${'Клиент подтвердил'.tr}: ${e.data['slot'] ?? ''}';
      case 'visit_cancelled':
        return '${'Клиент отменил'.tr}: ${e.data['slot'] ?? ''}';
      case 'payment_recorded':
        return '${'Оплата'.tr} \$${(e.data['amount'] as num?)?.toStringAsFixed(0) ?? ''} (${e.data['method'] ?? ''})';
      case 'tip_recorded':
        return '${'Чаевые'.tr} \$${(e.data['amount'] as num?)?.toStringAsFixed(0) ?? ''}';
      case 'refund_recorded':
        return '${'Возврат'.tr} \$${(e.data['amount'] as num?)?.toStringAsFixed(0) ?? ''}';
      case 'invoice_fully_paid':
        return 'Счёт полностью оплачен'.tr;
      case 'merged_duplicate':
        return '${'Соединено с дубляжом'.tr}${e.data['detail'] == null || e.data['detail'].toString().isEmpty ? '' : ': ${trAny(e.data['detail'])}'}';
      case 'merged_into':
        return 'Дубляж — соединено с другой заявкой'.tr;
      default:
        return e.event;
    }
  }

  String _byLabel(String by) {
    switch (by) {
      case 'secretary':
        return 'Секретарь'.tr;
      case 'sms':
        return 'SMS'.tr;
      case 'email':
        return 'Почта'.tr;
      case 'stripe':
        return 'Stripe';
      case 'client':
        return 'Клиент'.tr;
      default:
        return 'Вы'.tr;
    }
  }

  Widget _buildChangeRow(JobChangeEvent e, {required bool showDivider}) {
    final label = _changeLabel(e);
    final by = _byLabel(e.by);
    final time = DateFormat(
      'd MMM HH:mm',
      AppLocale.instance.dateLocale,
    ).format(e.at);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
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
