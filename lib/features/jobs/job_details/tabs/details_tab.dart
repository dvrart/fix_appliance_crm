import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import '../../../../core/app_feedback.dart';
import '../../../../core/constants.dart';
import '../../../../core/motion.dart';
import '../../../../core/sms_text.dart';
import '../../../../core/utils/app_date_picker.dart';
import '../../../../models/client.dart';
import '../../../../models/job.dart';
import '../../../../services/services.dart';
import '../../../calls/call_screen.dart';
import '../../../messages/conversation_screen.dart';
import '../job_details_controller.dart';
import '../job_details_screen.dart';
import '../editors/job_tile_editors.dart';
import '../editors/warranty_report_sheet.dart';
import '../editors/call_recording_page.dart';
import '../../../../core/l10n/app_locale.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../shared/app_nav.dart';
import '../../../../shared/stale_routes.dart';
import '../../../../shared/widgets/app_bar_save.dart';
import '../../../../shared/widgets/dispose_on_close.dart';
import '../../../../shared/widgets/keyboard_safe.dart';
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
  bool _historyExpanded = false;
  final ScrollController _scrollController = ScrollController();
  String _verifiedAddressInput = '';
  bool _verifyingAddress = false;
  MapPlace? _verifiedPlace;
  int _addressCheckGen = 0;

  String get _bookingPhone {
    final site = ctrl.effectiveJobSitePhone.trim();
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
    unawaited(_verifyWorkAddress());
    _changesSub = ChangeLogService.streamChanges(ctrl.jobId).listen((events) {
      if (mounted) setState(() => _changes = events);
    });
  }

  @override
  void dispose() {
    ctrl.removeListener(_onControllerChange);
    _changesSub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _onControllerChange() {
    if (mounted) setState(() {});
    if (_duplicateTwinId() != _twinJobId) unawaited(_loadTwinJob());
    if (ctrl.workAddress.trim() != _verifiedAddressInput) {
      unawaited(_verifyWorkAddress());
    }
  }

  Future<void> _verifyWorkAddress() async {
    final address = ctrl.workAddress.trim();
    _verifiedAddressInput = address;
    final gen = ++_addressCheckGen;
    if (!MapsService.hasRoutableAddress(address)) {
      if (!mounted) return;
      setState(() {
        _verifyingAddress = false;
        _verifiedPlace = null;
      });
      return;
    }
    if (mounted) {
      setState(() => _verifyingAddress = true);
    }
    final place = await MapsService.resolvePlace(address);
    if (!mounted || gen != _addressCheckGen) return;
    setState(() {
      _verifyingAddress = false;
      _verifiedPlace = place;
    });
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
    if (ctrl.chatContacts.length <= 1) {
      await ctrl.ensureChatContactsLoaded();
      if (!mounted) return null;
    }
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
                    contact.isOwner ? Icons.person : Icons.location_on,
                    color: AppColors.primary,
                  ),
                  title: Text(contact.displayName),
                  subtitle: Text(contact.subtitleLine),
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
    final contact = await _pickContact('Кому позвонить?'.tr, phoneOnly: true);
    if (contact == null || !mounted) return;
    final phone = contact.phone.trim();
    if (SmsService.normalizePhone(phone).length < 10) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Нет телефона'.tr)));
      return;
    }
    await CallScreen.open(
      context,
      phoneNumber: phone,
      contactName: contact.displayName,
      jobId: ctrl.jobId,
    );
  }

  Future<void> _smsSelected() async {
    final contact = await _pickContact('Кому написать?'.tr);
    if (contact == null || !mounted) return;
    ctrl.setChatRole(contact.id);
    await AppNav.openCard(
      context,
      key: AppNav.chatKey(
        phone: contact.phone,
        email: contact.email.contains('@') ? contact.email : null,
        jobId: ctrl.jobId,
      ),
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
        onRecipientChanged: (peer) => ctrl.setChatRole(peer.id),
      ),
    );
  }

  void _showStatusMenu() {
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
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                          color: AppColors.ink,
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
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: AppColors.ink,
                              ),
                            ),
                            selected: isSelected,
                            onTap: () async {
                              Navigator.pop(sheetContext);
                              if (_statusNeedsNewDate(status)) {
                                await _editVisit(followUpStatus: status);
                              } else if (status == JobStatuses.call) {
                                // «Вызов» переносит эту же карточку на новый
                                // день и время — без второй заявки и без
                                // второго активного визита.
                                final active = _orderConfirmVisit;
                                await _editVisit(
                                  existing: active != null && active.isActiveSlot
                                      ? active
                                      : null,
                                  moveStatus: status,
                                );
                              } else if (_shouldCompleteJob(status)) {
                                await _completeJobFlow();
                              } else {
                                await ctrl.updateStatus(status);
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
  /// новый визит добавляется в эту же заявку, прошлые выезды закрываются.
  /// Отдельную заявку перенос больше не заводит — счёт, депозит, фото и
  /// переписка должны остаться в одной карточке.
  /// [moveStatus] — «Вызов» из меню статусов: активный визит ([existing])
  /// переезжает на новый день и время, а если его нет — ставится один.
  Future<void> _editVisit({
    JobVisit? existing,
    String? followUpStatus,
    String? moveStatus,
  }) async {
    final followUp = followUpStatus != null && existing == null;
    final moving = moveStatus != null;
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
    var sendSms = false;
    final statusLabel = followUp
        ? trAny(StatusService.labelOf(followUpStatus))
        : moving
        ? trAny(StatusService.labelOf(moveStatus))
        : '';

    final saved = await showModalBottomSheet<String>(
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
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            followUp || moving ? statusLabel : 'Дата визита'.tr,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                          ),
                        ),
                        // Корзина в заголовке, а не под кнопкой «Сохранить»:
                        // окно с календарём и колесом времени высокое, и
                        // кнопку внизу FIX просто не видел (11.10.2026).
                        if (existing != null && !moving)
                          IconButton(
                            onPressed: () =>
                                Navigator.pop(sheetContext, 'delete'),
                            icon: const Icon(Icons.delete_outline),
                            color: Colors.red.shade700,
                            tooltip: 'Удалить визит'.tr,
                          ),
                      ],
                    ),
                    if (followUp || moving)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          (moving
                                  ? 'Эта же карточка переедет на выбранный день и время — без копии.'
                                  : 'Новый визит добавится в эту же заявку: счёт и оплаты останутся на месте. Прошлые выезды закроются.')
                              .tr,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            color: AppColors.inkMuted,
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
                        color: AppColors.primaryOnCard,
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
                        'Отправить SMS о визите'.tr,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: AppColors.ink,
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
                        onPressed: () => Navigator.pop(sheetContext, 'save'),
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
    if (saved == 'delete' && existing != null) {
      if (!mounted) return;
      final onlyOne = ctrl.visits.length <= 1;
      final ok = await showConfirmCancelSheet(
        context,
        title: 'Удалить визит?'.tr,
        message: onlyOne
            ? '${appDateTimeLabel(existing.startAt)}\n\n${'У заявки не останется даты. Сама заявка, счёт и оплаты никуда не денутся.'.tr}'
            : '${appDateTimeLabel(existing.startAt)}\n\n${'Остальные визиты заявки останутся на месте.'.tr}',
        confirmLabel: 'Удалить'.tr,
      );
      if (!ok || !mounted) return;
      await ctrl.removeVisit(existing.id);
      await ctrl.commitChanges();
      return;
    }
    if (saved != 'save') return;

    if (existing != null) {
      final visit = existing.copyWith(startAt: startAt);
      await ctrl.updateVisit(visit, correction: true);
      if (moving && ctrl.currentStatus != moveStatus) {
        await ctrl.updateStatus(moveStatus);
      }
      if (!await ctrl.commitChanges() || !mounted) return;
      if (sendSms && visit.isScheduled) await _resendVisitBookingSms(visit);
      return;
    }

    // SMS, если мастер его выбрал, только сообщает дату и время — клиенту
    // больше не предлагается подтверждать визит ответом.
    final visit = JobVisit.create(
      startAt: startAt,
      durationMinutes: ctrl.durationMinutes,
      note: followUp ? followUpStatus : '',
    );
    // Визит всегда ставится в эту же заявку. Для «Установки» / «Повторного
    // визита» прошлые выезды закрываются, чтобы календарь не держал два окна.
    await ctrl.saveVisits([
      ...(followUp ? JobVisit.markAllScheduledDone(ctrl.visits) : ctrl.visits),
      visit,
    ]);
    if (followUp) {
      await ctrl.updateStatus(followUpStatus);
    } else if (moving && ctrl.currentStatus != moveStatus) {
      await ctrl.updateStatus(moveStatus);
    }
    if (!await ctrl.commitChanges() || !mounted) return;
    if (sendSms) await _resendVisitBookingSms(visit);
  }

  /// Сколько места осталось списку под содержимым. Ряд иконок забирает его
  /// себе, чтобы не висела пустая полоса между кнопками и «Историей».
  double _scrollSlack = 0;

  /// Высота ряда иконок: обычные 72 плюс свободное место под ними, но не
  /// больше полутора обычных высот. На заявках, где сверху стоят баннеры
  /// и свободного места почти нет, кнопки остаются как были.
  double get _quickIconHeight =>
      (72.0 + _scrollSlack).clamp(72.0, 72.0 * 1.5);

  void _measureScrollSlack() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final slack = _scrollController.position.maxScrollExtent <= 0
          ? -_scrollController.position.minScrollExtent
          : 0.0;
      final next = slack < 1 ? 0.0 : slack;
      if ((next - _scrollSlack).abs() < 1) return;
      setState(() => _scrollSlack = next);
    });
  }

  /// Маленькие вкладки («Информация», «Клиент звонил», «Фото», диагностика)
  /// собраны в один компактный ряд кнопок-иконок без текста (просьба FIX).
  Widget _buildQuickIconBar() {
    final description = ctrl.currentDescription.trim();
    final emptyInfo = description.isEmpty || description == 'Нет описания';
    final packing = packingItemsFromNotes(ctrl.packingNotes);
    final hasTracking =
        ctrl.trackingOrders.isNotEmpty ||
        ctrl.trackingPart.trim().isNotEmpty ||
        ctrl.trackingNumber.trim().isNotEmpty ||
        ctrl.amazonOrderId.trim().isNotEmpty ||
        ctrl.trackingCarrier.trim().isNotEmpty;
    final hasInfo = !emptyInfo || packing.isNotEmpty || hasTracking;

    final callItems = ctrl.callItems;
    final totalCalls = callItems.length + ctrl.otherClientCalls.length;
    final lastCall = callItems.isNotEmpty
        ? callItems.last
        : (ctrl.otherClientCalls.isEmpty ? null : ctrl.otherClientCalls.last);
    final source = _jobSource();
    final sourceLabel = Job.intakeSourceLabel(source);
    final sourceColor = Job.intakeSourceColor(source);
    final commsTooltip = lastCall == null
        ? 'Связь'.tr
        : (_callInbound(lastCall) ? 'Клиент звонил'.tr : 'Мы звонили'.tr);

    final photoCount = ctrl.attachments.where((item) {
      final kind = (item['kind'] ?? '').toString();
      return kind != 'call' && kind != 'signature';
    }).length;

    return Row(
      children: [
        Expanded(
          child: _quickIconTile(
            tooltip: 'Информация'.tr,
            color: AppColors.primary,
            hasData: hasInfo,
            onTap: () => openJobInfoEditor(context, ctrl),
            onLongPress: emptyInfo
                ? null
                : () => AppFeedback.copy(context, description),
            icon: Icon(
              Icons.info_outline_rounded,
              size: 34,
              color: AppColors.primary,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: _quickIconTile(
            tooltip: commsTooltip,
            color: const Color(0xFFD97706),
            fillColor: AppColors.accent.withValues(alpha: 0.32),
            hasData: totalCalls > 0,
            onTap: _openJobComms,
            icon: lastCall == null && sourceLabel.isNotEmpty
                ? Icon(Job.intakeSourceIcon(source), size: 26, color: sourceColor)
                : const _CassetteIcon(size: 34),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: _quickIconTile(
            tooltip: 'Фото'.tr,
            color: const Color(0xFF00897B),
            hasData: photoCount > 0,
            onTap: () => openPhotosEditor(context, ctrl),
            icon: ctrl.isUploadingImage
                ? const SizedBox(
                    width: 34,
                    height: 34,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: Color(0xFF00897B),
                    ),
                  )
                : const Icon(
                    Icons.add_a_photo_outlined,
                    size: 34,
                    color: Color(0xFF00897B),
                  ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(child: _buildPromisedTile()),
      ],
    );
  }

  Widget _quickIconTile({
    required String tooltip,
    required Color color,
    required Widget icon,
    required VoidCallback onTap,
    Color? fillColor,
    bool hasData = false,
    VoidCallback? onLongPress,
    String? caption,
  }) {
    final bg = Color.alphaBlend(
      fillColor ?? color.withValues(alpha: hasData ? 0.18 : 0.11),
      AppColors.card,
    );
    final height = _quickIconHeight;
    final grown = height > 76;
    // Значок растёт вместе с плиткой, но медленнее неё: иначе кассета на
    // жёлтой плитке упирается в края.
    final iconSize = grown ? 34.0 + (height - 72) * 0.32 : 34.0;
    // Плитка с подписью (у «Когда пообещал» на ней дата): значок поменьше,
    // под ним текст, без круглой подложки.
    final Widget content = caption == null
        ? (grown
              ? _iconBadge(color, iconSize + 22, _sizedIcon(icon, iconSize))
              : icon)
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _sizedIcon(icon, grown ? 26.0 + (height - 72) * 0.25 : 24.0),
              const SizedBox(height: 3),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Text(
                  caption,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.1,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
              ),
            ],
          );
    return Tooltip(
      message: tooltip,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: color.withValues(alpha: hasData ? 0.55 : 0.32),
            width: hasData ? 1.3 : 1.0,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          onLongPress: onLongPress,
          child: SizedBox(
            height: height,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Center(child: content),
                if (hasData)
                  Positioned(
                    top: 7,
                    right: 7,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sizedIcon(Widget icon, double size) {
    if (icon is Icon) return Icon(icon.icon, size: size, color: icon.color);
    if (icon is _CassetteIcon) return _CassetteIcon(size: size);
    return icon;
  }

  Widget _iconBadge(Color color, double size, Widget icon) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.card.withValues(alpha: 0.72),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 1.2),
      ),
      child: icon,
    );
  }

  List<Map<String, dynamic>> _applianceList() {
    final appliances = ctrl.jobData['appliances'];
    final list = <Map<String, dynamic>>[];
    if (appliances is List) {
      for (final item in appliances) {
        if (item is Map) list.add(Map<String, dynamic>.from(item));
      }
    }
    return list;
  }

  ({String type, String brand, String model}) _applianceSummary() {
    final list = _applianceList();
    final primary = list.isNotEmpty ? list.first : null;
    final type =
        (ctrl.jobData['applianceType'] ?? primary?['type'] ?? 'Техника')
            .toString();
    final brand = (ctrl.jobData['brand'] ?? primary?['brand'] ?? '').toString();
    final model = (ctrl.jobData['model'] ?? primary?['model'] ?? '').toString();
    return (type: type, brand: brand.trim(), model: model.trim());
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
    // Телефон, попавший в поле имени, в окно правки не переносим — иначе его
    // можно сохранить обратно как имя.
    final rawClientName = (ctrl.jobData['clientName'] ?? '').toString().trim();
    final clientName =
        Client.isPlaceholderName(rawClientName) ? '' : rawClientName;
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
      text: orClient(ctrl.effectiveJobSiteName, clientName),
    );
    final phoneCtrl = TextEditingController(
      text: orClient(ctrl.effectiveJobSitePhone, clientPhone),
    );
    final extraPhoneCtrls = <TextEditingController>[
      for (final p in ctrl.extraPhones) TextEditingController(text: p),
    ];
    final allPhoneCtrls = <TextEditingController>[...extraPhoneCtrls];
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
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        // Подсказка внутри окна: ScaffoldMessenger рисует её ПОД модальным
        // окном, поэтому нажатие выглядело как «кнопка не работает».
        var siteError = '';
        return DisposeOnClose(
          disposables: [
            nameCtrl,
            phoneCtrl,
            emailCtrl,
            streetCtrl,
            cityCtrl,
            postalCtrl,
            ...allPhoneCtrls,
          ],
          child: KeyboardAvoidingSheet(
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
                              color: AppColors.primaryOnCard,
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
                            for (var i = 0; i < extraPhoneCtrls.length; i++) ...[
                              const SizedBox(height: 10),
                              TextField(
                                controller: extraPhoneCtrls[i],
                                keyboardType: TextInputType.phone,
                                decoration: InputDecoration(
                                  labelText: '${'Доп. телефон'.tr} ${i + 1}',
                                  prefixIcon: const Icon(Icons.phone_android),
                                  border: const OutlineInputBorder(),
                                  suffixIcon: IconButton(
                                    tooltip: 'Удалить'.tr,
                                    icon: const Icon(Icons.close),
                                    onPressed: () {
                                      setSheet(() {
                                        extraPhoneCtrls.removeAt(i);
                                      });
                                    },
                                  ),
                                ),
                              ),
                            ],
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                onPressed: () {
                                  final next = TextEditingController();
                                  allPhoneCtrls.add(next);
                                  setSheet(() {
                                    extraPhoneCtrls.add(next);
                                  });
                                },
                                icon: const Icon(Icons.add, size: 18),
                                label: Text('Добавить телефон'.tr),
                              ),
                            ),
                            const SizedBox(height: 6),
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
                                  color: AppColors.cardMuted,
                                  border: Border.all(color: AppColors.border),
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
                          final typedName = nameCtrl.text.trim();
                          // Номер — не имя. Если его вписали в имя, на месте
                          // останется имя из карточки клиента.
                          final siteName = _sameText(typedName, clientName) ||
                                  Client.isPlaceholderName(typedName)
                              ? ''
                              : typedName;
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
                          final cleanedExtra = <String>[
                            for (final c in extraPhoneCtrls)
                              if (c.text.trim().isNotEmpty &&
                                  SmsService.normalizePhone(c.text) !=
                                      SmsService.normalizePhone(phoneCtrl.text) &&
                                  SmsService.normalizePhone(c.text) !=
                                      SmsService.normalizePhone(clientPhone))
                                c.text.trim(),
                          ];
                          if (siteName.isEmpty &&
                              sitePhone.isEmpty &&
                              siteEmail.isEmpty &&
                              siteAddress.isEmpty) {
                            ctrl.clearJobSite(extraPhones: cleanedExtra);
                          } else {
                            ctrl.updateJobSite(
                              name: siteName,
                              phone: sitePhone,
                              address: siteAddress,
                              email: siteEmail,
                              extraPhones: cleanedExtra,
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
          ),
        );
      },
    );
  }

  Map<String, String> _applianceFields() {
    final list = _applianceList();
    final primary = list.isNotEmpty ? list.first : null;
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
      // Контент под кнопками прибыл — дыра уменьшилась, ряд надо перемерить.
      _scrollSlack = 0;
    });
  }

  Widget _buildOriginalJobLink() {
    final job = _originalJob!;
    const color = Color(0xFF8E24AA);
    return Container(
      decoration: BoxDecoration(
        color: Color.alphaBlend(color.withValues(alpha: 0.12), AppColors.card),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        leading: const Icon(Icons.history, color: color, size: 20),
        title: Text(
          'Исходная заявка'.tr,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
        ),
        subtitle: Text(
          [
            trAny(job.status),
            DateFormat(
              'd MMM yyyy',
              AppLocale.instance.dateLocale,
            ).format(job.scheduledAt ?? job.createdAt),
          ].join(' · '),
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        trailing: const Icon(Icons.chevron_right, color: color),
        onTap: () {
          AppNav.openCard(
            context,
            key: AppNav.jobKey(job.id),
            builder: (_) => JobDetailsScreen(
              jobId: job.id,
              clientId: job.clientId,
              jobData: job.toMap(),
            ),
          );
        },
      ),
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
              Icon(icon, size: 18, color: AppColors.primaryOnCard),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AppColors.primaryOnCard,
                ),
              ),
            ],
          ),
          child,
        ],
      ),
    );
  }

  /// «Установка» и «Повторный визит» — это новый выезд в той же заявке: сразу
  /// дата, время и SMS. Остальные статусы дату карточки не трогают.
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

  /// Заявка привязана к паспорту техники, а отчёт пуст: на странице по QR
  /// тогда будет только дата без того, что сделали. Спрашиваем до закрытия.
  bool get _reportMissing =>
      ((ctrl.jobData['applianceIds'] as List?) ?? const []).isNotEmpty &&
      ctrl.currentSolution.trim().isEmpty;

  /// Отчёт по гарантийной технике. Пустую строку лист не отдаёт.
  Future<bool> _askForReport({String existing = ''}) async {
    final text = await WarrantyReportSheet.ask(
      context,
      existing: existing,
      draftProblem: ctrl.currentDescription,
      invoiceItems: _invoiceItemNames(),
    );
    if (text == null || text.trim().isEmpty) return false;
    await ctrl.updateProblemAndSolution(
      problem: ctrl.currentDescription == 'Нет описания'
          ? ''
          : ctrl.currentDescription,
      solution: text.trim(),
    );
    await ctrl.commitChanges();
    return true;
  }

  /// Названия позиций счёта — для черновика отчёта, без цен.
  List<String> _invoiceItemNames() {
    final docs = ctrl.jobData['documents'];
    if (docs is! List) return const [];
    final names = <String>[];
    for (final doc in docs) {
      if (doc is! Map) continue;
      if ((doc['type'] ?? 'Invoice').toString() == 'Estimate') continue;
      final items = doc['items'];
      if (items is! List) continue;
      for (final item in items) {
        final name = item is Map ? (item['name'] ?? '').toString().trim() : '';
        if (name.isNotEmpty && !names.contains(name)) names.add(name);
      }
    }
    return names;
  }

  Future<void> _completeJobFlow() async {
    if (_reportMissing) {
      final wrote = await _askForReport();
      if (!wrote || !mounted) return;
    }
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
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        color: AppColors.ink,
                      ),
                    ),
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      value: sendReview,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        'Отправить SMS с просьбой об отзыве'.tr,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppColors.ink,
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
    final chosen = await _pickContact('Кому отправить SMS?'.tr, phoneOnly: true);
    if (!mounted) return false;
    final phone = (chosen?.phone ?? ctrl.contactPhone).trim();
    final recipientName = chosen?.displayName ?? ctrl.contactName;
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
    final address = ctrl.workAddress.trim();
    final template = templates['job_done'] ?? SettingsService.defaultJobDoneSms;
    var body = SmsText.fillName(template, recipientName);
    body = SmsText.replacePlaceholder(body, 'date', '');
    body = SmsText.replacePlaceholder(body, 'time', '');
    body = SmsText.replacePlaceholder(body, 'address', address);
    body = SmsText.replacePlaceholder(body, 'review', reviewUrl);
    body = SmsText.replacePlaceholder(body, 'url', reviewUrl);
    body = SmsText.replacePlaceholder(body, 'appliance', '');
    body = body.trim();
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

  /// День и время, когда пообещали клиенту приехать со следующим визитом / запчастью.
  Future<void> _pickPromisedPartDay() async {
    final now = DateTime.now();
    final defaultInitial = DateTime(now.year, now.month, now.day + 2, 10, 0);
    final current = ctrl.promisedPartAt;
    final initial = current == null
        ? defaultInitial
        : (current.hour == 0 && current.minute == 0
              ? DateTime(current.year, current.month, current.day, 10, 0)
              : current);
    final picked = await showAppDateTimeSheet(
      context: context,
      initial: initial,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
      title: 'Пообещал к'.tr,
    );
    if (picked == null) return;
    await ctrl.updatePromisedPartAt(picked);
    if (!mounted) return;
    await ctrl.commitChanges();
  }

  String _formatPromisedPartAt(DateTime at) {
    final date = DateFormat('d MMM', AppLocale.instance.dateLocale).format(at);
    if (at.hour == 0 && at.minute == 0) return date;
    return '$date · ${DateFormat('HH:mm').format(at)}';
  }

  /// Верх карточки: что чиним — слева, где заказ сейчас — справа.
  Widget _buildTopRow() {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 11, child: _buildApplianceHero()),
          const SizedBox(width: 6),
          Expanded(flex: 9, child: _buildStatusButton()),
        ],
      ),
    );
  }

  /// Кнопка «Когда пообещал» в ряду рядом с «Фото»: на ней сама дата, к
  /// которой обещали клиенту. Красная — этот срок уже прошёл. Долгое
  /// нажатие убирает дату.
  Widget _buildPromisedTile() {
    final at = ctrl.promisedPartAt;
    final today = DateTime.now();
    final startOfToday = DateTime(today.year, today.month, today.day);
    final overdue = at != null && at.isBefore(startOfToday);
    final color = overdue ? const Color(0xFFC62828) : const Color(0xFFEF6C00);
    final caption = at == null
        ? context.tr('Когда пообещал', 'Promised by')
        : _formatPromisedPartAt(at).replaceFirst(' · ', '\n');
    return _quickIconTile(
      tooltip: at == null
          ? context.tr('Когда пообещал', 'Promised by')
          : '${context.tr('Пообещал к', 'Promised by')} ${_formatPromisedPartAt(at)}',
      color: color,
      hasData: at != null,
      onTap: _pickPromisedPartDay,
      onLongPress: at == null
          ? null
          : () async {
              await ctrl.updatePromisedPartAt(null);
              if (!mounted) return;
              await ctrl.commitChanges();
            },
      caption: caption,
      icon: Icon(Icons.handshake_outlined, size: 26, color: color),
    );
  }

  Widget _applianceCountBadge(int count) {
    return Container(
      width: 17,
      height: 17,
      decoration: BoxDecoration(
        color: AppColors.primary,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        '$count',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          height: 1.1,
        ),
      ),
    );
  }

  Widget _buildApplianceHero() {
    final appliance = _applianceSummary();
    final appliances = _applianceList();
    final model = appliance.model;
    final extraTypes = appliances.length > 1
        ? appliances
              .sublist(1)
              .map((a) => trAny((a['type'] ?? '').toString()))
              .where((type) => type.trim().isNotEmpty)
              .join(', ')
        : '';
    return Material(
      color: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(11),
        side: BorderSide(color: AppColors.border),
      ),
      child: InkWell(
        onTap: () => openApplianceEditor(context, ctrl),
        onLongPress: model.isNotEmpty
            ? () => AppFeedback.copy(context, model)
            : null,
        borderRadius: BorderRadius.circular(11),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              Stack(
                children: [
                  AppliancePicture(
                    type: appliances.length > 1 ? 'Техника' : appliance.type,
                    size: 54,
                  ),
                  if (appliances.length > 1)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: _applianceCountBadge(appliances.length),
                    ),
                ],
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      trAny(appliance.type),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14.5,
                        height: 1.1,
                      ),
                    ),
                    if (appliance.brand.isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(
                        appliance.brand,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                          color: AppColors.primaryOnCard,
                        ),
                      ),
                    ],
                    const SizedBox(height: 1),
                    Text(
                      model.isNotEmpty ? model : 'Модель не указана'.tr,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 11.5,
                        color: model.isNotEmpty
                            ? AppColors.inkMuted
                            : Colors.grey,
                      ),
                    ),
                    if (extraTypes.isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(
                        '+ $extraTypes',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                          color: AppColors.primaryOnCard,
                        ),
                      ),
                    ],
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
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        onTap: _showStatusMenu,
        borderRadius: BorderRadius.circular(11),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 2, 4),
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
                        fontSize: 9.5,
                        fontWeight: FontWeight.bold,
                        color: onColor.withValues(alpha: 0.8),
                      ),
                    ),
                    Text(
                      trAny(StatusService.labelOf(ctrl.currentStatus)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 12.5,
                        height: 1.1,
                        color: onColor,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.arrow_drop_down, size: 20, color: onColor),
            ],
          ),
        ),
      ),
    );
  }

  /// Верхняя плашка «Время следующего визита»: строго посередине крупно дата
  /// и время ближайшего/текущего выезда; если были переносы — под ней тонкая
  /// шкала переносов слева направо.
  Widget _buildVisitsCard() {
    final visits = ctrl.visits;
    final hasVisits = visits.isNotEmpty;
    final currentVisit = _orderConfirmVisit;
    final accent = hasVisits ? AppColors.primaryOnCard : Colors.orange.shade800;
    final canAdd = !visits.any((visit) => visit.isActiveSlot);
    final singleVisit = visits.length == 1 ? visits.first : null;
    final showWaitingHint =
        ctrl.currentStatus == JobStatuses.waitingPart &&
        !visits.any((visit) => visit.isScheduled);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: hasVisits
            ? AppColors.primary.withValues(alpha: 0.08)
            : Colors.orange.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: hasVisits
              ? AppColors.primary.withValues(alpha: 0.32)
              : Colors.orange.withValues(alpha: 0.45),
          width: 1.2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(9),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: canAdd ? 32 : 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.calendar_month_rounded,
                            size: 14,
                            color: accent,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              context.tr(
                                'Время следующего визита',
                                'Next visit time',
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                                color: accent,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      if (currentVisit == null)
                        Text(
                          'Нажмите «+», чтобы назначить день и время'.tr,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 13.5,
                            color: Colors.orange.shade800,
                          ),
                        )
                      else
                        _singleVisitChip(currentVisit),
                      if (singleVisit != null &&
                          singleVisit.note.trim().isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          singleVisit.note.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (canAdd)
                  Positioned(
                    right: 0,
                    child: _addVisitButton(),
                  ),
              ],
            ),
          ),
          if (visits.length > 1) ...[
            const SizedBox(height: 4),
            _visitTimeline(visits, currentVisit),
          ],
          if (showWaitingHint)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Ожидание запчасти — дату возврата ставить не нужно. Когда запчасть приедет — статус → «Установка».'
                    .tr,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                  color: Colors.orange.shade800,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _singleVisitChip(JobVisit visit) {
    final date = DateFormat(
      'EEE, d MMM',
      AppLocale.instance.dateLocale,
    ).format(visit.startAt);
    final time = DateFormat('HH:mm').format(visit.startAt);
    final Color dotColor;
    if (visit.isDone) {
      dotColor = const Color(0xFF2E7D32);
    } else if (visit.isCancelled) {
      dotColor = const Color(0xFFC62828);
    } else {
      dotColor = AppColors.primary;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3.5),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: dotColor.withValues(alpha: 0.45), width: 1.3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: date,
                    style: TextStyle(
                      color: visit.isCancelled
                          ? AppColors.inkMuted
                          : const Color(0xFF008F3B),
                    ),
                  ),
                  TextSpan(
                    text: ' · $time',
                    style: TextStyle(
                      color: visit.isCancelled
                          ? AppColors.inkMuted
                          : const Color(0xFFE53935),
                    ),
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 17,
                height: 1.15,
                fontWeight: FontWeight.w900,
                decoration: visit.isCancelled
                    ? TextDecoration.lineThrough
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Зелёный плюс в заголовке «Дата визита» — единственная кнопка, которая
  /// открывает календарь и колесо времени для нового выезда.
  Widget _addVisitButton() {
    return Material(
      color: const Color(0xFF22C55E),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => _editVisit(),
        child: Tooltip(
          message: 'Назначить время визита'.tr,
          child: const SizedBox(
            width: 26,
            height: 26,
            child: Icon(Icons.add_rounded, size: 18, color: Colors.white),
          ),
        ),
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
      dotColor = AppColors.primaryOnCard;
      captionColor = AppColors.primaryOnCard;
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
      captionColor = AppColors.inkMuted;
      caption = index == 0 ? 'Старт'.tr : 'Перенос'.tr;
    }
    final struck = !isCurrent && !visit.isDone;
    final dotSize = isCurrent ? 14.0 : (icon != null ? 13.0 : 10.0);
    final lineDone = AppColors.primaryOnCard.withValues(alpha: 0.55);
    final lineTodo = AppColors.border;
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
        ? AppColors.primaryOnCard
        : (visit.isDone ? AppColors.ink : AppColors.inkMuted);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 1),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 15,
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
                          ? Border.all(color: Colors.white, width: 2)
                          : null,
                    ),
                    child: icon == null
                        ? null
                        : Icon(icon, size: dotSize - 4, color: Colors.white),
                  ),
                  segment(index < count - 1, index < currentIndex),
                ],
              ),
            ),
            if (caption.isNotEmpty)
              Text(
                caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  height: 1.1,
                  fontWeight: FontWeight.w800,
                  color: captionColor,
                ),
              ),
            Text(
              '$when · $time',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: isCurrent ? 12.5 : 11,
                height: 1.15,
                fontWeight: isCurrent ? FontWeight.w900 : FontWeight.w700,
                color: textColor,
                decoration: struck ? TextDecoration.lineThrough : null,
              ),
            ),
          ],
        ),
      ),
    );
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
                : '${'SMS о визите ещё не отправлено'.tr}: $when',
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
        message: 'SMS об этом времени визита не будет отправлено.'.tr,
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
    if (ctrl.needsReview) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Сначала нажмите «Проверено» — потом можно слать SMS.'.tr,
          ),
          backgroundColor: Colors.orange.shade800,
        ),
      );
      return;
    }
    final chosen = await _pickContact('Кому отправить SMS?'.tr, phoneOnly: true);
    if (!mounted) return;
    final phone = (chosen?.phone ?? _bookingPhone).trim();
    final recipientName = chosen?.displayName ?? ctrl.contactName;
    if (phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Нет телефона для SMS'.tr),
          backgroundColor: Colors.orange.shade800,
        ),
      );
      return;
    }
    setState(() => _bookingBusy = true);
    try {
      final templates = await SettingsService.loadSmsTemplates();
      final clock = AppTimeService.bookingWallClock(visit.startAt);
      final date = DateFormat('MMMM d', 'en_US').format(clock);
      final time = DateFormat('HH:mm').format(clock);
      final slotKey = AppTimeService.bookingSlotKey(visit.startAt);
      final template =
          templates['booking_confirm'] ??
          SettingsService.defaultBookingConfirmSms;
      // Даже если в сохранённом шаблоне ещё лежит меню «1 / 0 / 5», клиенту
      // уходит только сообщение о дате и времени.
      var body = SmsText.stripConfirmAsk(
        SmsText.fillName(template, recipientName),
      );
      body = SmsText.replacePlaceholder(body, 'date', date);
      body = SmsText.replacePlaceholder(body, 'time', time);
      body = SmsText.replacePlaceholder(body, 'address', ctrl.workAddress.trim());
      body = SmsText.replacePlaceholder(body, 'review', '');
      body = SmsText.replacePlaceholder(body, 'appliance', '');
      body = body.trim();

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
                ? 'SMS о визите отправлено'.tr
                : SmsService.failureText(),
          ),
          backgroundColor: ok ? Colors.green : Colors.orange.shade800,
        ),
      );
    } finally {
      if (mounted) setState(() => _bookingBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, viewport) {
              const topPad = 6.0;
              const bottomPad = 6.0;
              final minScreenHeight = (viewport.maxHeight - topPad - bottomPad)
                  .clamp(0.0, double.infinity);
              final hasExtraBlocks =
                  ctrl.documents.isNotEmpty ||
                  _relatedJobs.isNotEmpty ||
                  _originalJob != null ||
                  ctrl.needsReview ||
                  _twinJob != null ||
                  (!ctrl.needsReview && _pendingSmsVisit != null);
              final mapHeight = hasExtraBlocks
                  ? (viewport.maxHeight * 0.14).clamp(84.0, 100.0)
                  : (viewport.maxHeight * 0.16).clamp(92.0, 112.0);
              _measureScrollSlack();
              return SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(12, topPad, 12, bottomPad),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ConstrainedBox(
                      constraints: BoxConstraints(minHeight: minScreenHeight),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildVisitsCard(),
                              const SizedBox(height: 6),
                              if (ctrl.needsReview) ...[
                                _reviewBanner(),
                                const SizedBox(height: 6),
                              ],
                              if (_twinJob != null) ...[
                                _buildDuplicateBanner(_twinJob!),
                                const SizedBox(height: 6),
                              ],
                              _buildTopRow(),
                              const SizedBox(height: 6),
                              _buildJobSiteCard(mapHeight: mapHeight),
                              const SizedBox(height: 6),
                              _buildQuickIconBar(),
                              if (!ctrl.needsReview &&
                                  _pendingSmsVisit != null) ...[
                                const SizedBox(height: 6),
                                _pendingSmsBanner(_pendingSmsVisit!),
                              ],
                              if (_originalJob != null) ...[
                                const SizedBox(height: 6),
                                _buildOriginalJobLink(),
                              ],
                              if (_relatedJobs.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                _buildRelatedJobs(),
                              ],
                              const SizedBox(height: 6),
                            ],
                          ),
                          _buildChangeHistoryHeader(),
                        ],
                      ),
                    ),
                    if (_historyExpanded) _buildChangeHistoryBody(),
                  ],
                ),
              );
            },
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
        color: AppColors.tint(Colors.orange, 0.12),
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
    AppNav.openCard(
      context,
      key: AppNav.jobKey(job.id),
      builder: (_) => JobDetailsScreen(
        jobId: job.id,
        clientId: job.clientId,
        jobData: job.toMap(),
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

  Widget _buildContactActions() {
    return Material(
      color: AppColors.card,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
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
      height: 50,
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

  /// Кто говорил: секретарь или мастер. Ради этой строки список и затевался —
  /// разговор с ИИ надо находить глазами, а не угадывать по времени.
  String _callAnsweredBy(Map<String, dynamic> item) {
    switch ((item['answeredBy'] ?? '').toString()) {
      case 'ai':
        return 'ответил ИИ'.tr;
      case 'master':
        return 'ответили вы'.tr;
      default:
        return '';
    }
  }

  Widget _callChoiceTile(BuildContext sheetContext, Map<String, dynamic> item) {
    final who = _callAnsweredBy(item);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        _callInbound(item) ? Icons.call_received : Icons.call_made,
        color: _callInbound(item) ? const Color(0xFF008F3B) : AppColors.primary,
      ),
      title: Text(
        _callWhen(item) == null
            ? 'Звонок'.tr
            : Formatters.formatDateTime(_callWhen(item)),
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        [
          _callInbound(item) ? 'Клиент звонил'.tr : 'Мы звонили'.tr,
          if (who.isNotEmpty) who,
        ].join(' · '),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.pop(sheetContext, item),
    );
  }

  Widget _callGroupTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 13,
          color: AppColors.inkMuted,
        ),
      ),
    );
  }

  /// Вся связь по заявке: записи разговоров, нить SMS и нить писем.
  ///
  /// Раньше плитка вела только в записи, а при заявке с почты показывала
  /// слово «Почта» и не открывалась вовсе (FIX, 12.10.2026). Теперь это
  /// одна точка входа: одно место — открываем сразу, несколько — список.
  Future<void> _openJobComms() async {
    final calls = [...ctrl.otherClientCalls, ...ctrl.callItems];
    final threads = await _loadCommsThreads();
    if (!mounted) return;
    if (calls.isEmpty && threads.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Разговоров и переписки по заявке нет'.tr)),
      );
      return;
    }
    if (calls.length + threads.length == 1) {
      if (calls.isNotEmpty) {
        await openCallRecordingSheet(context, calls.first, jobId: ctrl.jobId);
      } else {
        await _openCommsThread(threads.first);
      }
      return;
    }

    final linked = ctrl.callItems;
    final others = ctrl.otherClientCalls;
    final chosen = await showModalBottomSheet<Object>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.7,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Связь по заявке'.tr,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                      ),
                    ),
                    if (linked.isNotEmpty) ...[
                      _callGroupTitle('Звонки по заявке'.tr),
                      for (final item in linked.reversed)
                        _callChoiceTile(sheetContext, item),
                    ],
                    if (others.isNotEmpty) ...[
                      _callGroupTitle('Другие звонки клиента'.tr),
                      for (final item in others.reversed)
                        _callChoiceTile(sheetContext, item),
                    ],
                    if (threads.isNotEmpty) ...[
                      _callGroupTitle(
                        sheetContext.tr('Переписка', 'Message threads'),
                      ),
                      for (final thread in threads)
                        _threadChoiceTile(sheetContext, thread),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
    if (!mounted || chosen == null) return;
    if (chosen is _CommsThread) {
      await _openCommsThread(chosen);
      return;
    }
    await openCallRecordingSheet(
      context,
      chosen as Map<String, dynamic>,
      jobId: ctrl.jobId,
    );
  }

  /// Нити, в которых есть хотя бы одно сообщение. Читаем один раз по тапу:
  /// постоянная подписка на всю коллекцию сообщений ради плитки не нужна.
  Future<List<_CommsThread>> _loadCommsThreads() async {
    await ctrl.ensureChatContactsLoaded();
    final List<SmsMessage> messages;
    try {
      messages = await SmsService.streamAll().first;
    } catch (error) {
      debugPrint('Связь по заявке: $error');
      return const [];
    }
    final byKey = <String, _CommsThread>{};
    void collect({
      required bool email,
      required String address,
      required String name,
      String label = '',
    }) {
      final key = '${email ? 'email' : 'sms'}:${email ? SmsService.normalizeEmail(address) : SmsService.normalizePhone(address)}';
      if (address.isEmpty || byKey.containsKey(key)) return;
      final matched = [
        for (final message in messages)
          if (!message.isDeleted &&
              !message.isWebsiteFormMail &&
              message.isEmail == email &&
              (email
                  ? message.counterpartEmail ==
                        SmsService.normalizeEmail(address)
                  : SmsService.normalizePhone(
                              message.isOutbound ? message.to : message.from,
                            ) ==
                            SmsService.normalizePhone(address) &&
                        SmsService.normalizePhone(address).length >= 10))
            message,
      ];
      if (matched.isEmpty) return;
      matched.sort(
        (a, b) => (a.createdAt ?? DateTime(0)).compareTo(
          b.createdAt ?? DateTime(0),
        ),
      );
      final last = matched.last;
      byKey[key] = _CommsThread(
        email: email,
        address: address,
        name: name,
        label: label,
        count: matched.length,
        lastAt: last.createdAt,
        preview: last.displayBody.trim(),
      );
    }

    for (final contact in ctrl.chatContacts) {
      collect(
        email: false,
        address: contact.phone,
        name: contact.displayName,
        label: contact.label,
      );
      if (contact.email.contains('@')) {
        collect(
          email: true,
          address: contact.email,
          name: contact.displayName,
          label: contact.label,
        );
      }
    }
    // Письмо, с которого завели заявку: отправитель может не совпадать с
    // почтой в карточке клиента.
    final sourceEmail = (ctrl.jobData['sourceEmailFrom'] ?? '')
        .toString()
        .trim();
    if (sourceEmail.contains('@')) {
      collect(
        email: true,
        address: sourceEmail,
        name: (ctrl.jobData['clientName'] ?? '').toString().trim(),
        label: 'Хозяин'.tr,
      );
    }
    final threads = byKey.values.toList();
    threads.sort(
      (a, b) =>
          (b.lastAt ?? DateTime(0)).compareTo(a.lastAt ?? DateTime(0)),
    );
    return threads;
  }

  Widget _threadChoiceTile(BuildContext sheetContext, _CommsThread thread) {
    final when = thread.lastAt == null
        ? ''
        : Formatters.formatDateTime(thread.lastAt);
    final who = [
      if (thread.label.isNotEmpty) thread.label,
      if (thread.name.isNotEmpty && thread.name != thread.label) thread.name,
    ].join(' — ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        thread.email ? Icons.email_outlined : Icons.sms_outlined,
        color: thread.email
            ? const Color(0xFF2E7D32)
            : const Color(0xFF0277BD),
      ),
      title: Text(
        [
          thread.email ? 'Почта'.tr : 'SMS',
          if (who.isNotEmpty) who,
          thread.address,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        [
          '${'Сообщений'.tr}: ${thread.count}',
          if (when.isNotEmpty) when,
          if (thread.preview.isNotEmpty) thread.preview,
        ].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.pop(sheetContext, thread),
    );
  }

  Future<void> _openCommsThread(_CommsThread thread) async {
    await ConversationScreen.open(
      context,
      phoneNumber: thread.email ? '' : thread.address,
      email: thread.email ? thread.address : null,
      contactName: thread.name.isEmpty ? null : thread.name,
      clientId: ctrl.clientId.isEmpty ? null : ctrl.clientId,
      jobId: ctrl.jobId,
      initialChannel: thread.email
          ? ConversationChannel.email
          : ConversationChannel.sms,
      rootNavigator: true,
    );
  }

  String _onSiteContactSummary() {
    // Имя клиента, а не номер: в заявке имя иногда пустое, и без этой проверки
    // на его месте оказывался телефон из карточки клиента.
    final clientName = Client.isPlaceholderName(ctrl.jobData['clientName'])
        ? ''
        : (ctrl.jobData['clientName'] ?? '').toString().trim();
    final clientPhone = (ctrl.jobData['clientPhone'] ?? '').toString().trim();
    final siteName = ctrl.hasJobSite ? ctrl.effectiveJobSiteName.trim() : '';
    final sitePhone = ctrl.hasJobSite ? ctrl.effectiveJobSitePhone.trim() : '';
    final siteEmail = ctrl.hasJobSite ? ctrl.jobSiteEmail.trim() : '';
    final hasDistinctName =
        siteName.isNotEmpty &&
        !Client.isPlaceholderName(siteName) &&
        !_sameText(siteName, clientName) &&
        siteName != 'Клиент'.tr &&
        siteName != 'Контакт на адресе'.tr;
    final hasDistinctPhone =
        sitePhone.isNotEmpty &&
        SmsService.normalizePhone(sitePhone) !=
            SmsService.normalizePhone(clientPhone);
    final hasDistinctEmail =
        siteEmail.isNotEmpty && !_sameText(siteEmail, ctrl.clientEmail);
    final extraPhones = ctrl.extraPhones;
    if (!hasDistinctName &&
        !hasDistinctPhone &&
        !hasDistinctEmail &&
        extraPhones.isEmpty) {
      return '';
    }
    return [
      if (hasDistinctName)
        siteName
      else if (clientName.isNotEmpty)
        clientName,
      if (hasDistinctPhone) sitePhone,
      ...extraPhones,
      if (hasDistinctEmail && !hasDistinctPhone) siteEmail,
    ].where((p) => p.isNotEmpty).join(' · ');
  }

  Future<void> _openHouseMapSheet(MapPlace place) async {
    if (place.location == null) return;
    final contactLine = _onSiteContactSummary();
    final rawAddress = ctrl.workAddress.trim();
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      enableDrag: false,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => _HouseMapSheet(
        place: place,
        rawAddress: rawAddress,
        contactLine: contactLine,
      ),
    );
    if (!mounted) return;
    if (action == 'edit') {
      await _editJobSite();
    } else if (action == 'navigate') {
      await _openNavigator();
    }
  }

  /// Одна секция «Где работа» под «Датой визита»: слева адрес и проверка дома,
  /// справа превью карты. Карта открывает интерактивный вид по тапу.
  Widget _buildJobSiteCard({double mapHeight = 112}) {
    final address = ctrl.workAddress.trim();
    final hasAddress = MapsService.hasRoutableAddress(address);
    final place = _verifiedPlace;
    final houseFound =
        hasAddress &&
        !_verifyingAddress &&
        place != null &&
        place.isHouse &&
        place.location != null;
    final outsideArea =
        hasAddress && !_verifyingAddress && place?.insideServiceArea == false;
    final contactLine = _onSiteContactSummary();
    final copyText = [
      if (contactLine.isNotEmpty) contactLine,
      if (address.isNotEmpty) address,
    ].join(', ');

    final warnState = !hasAddress || (!_verifyingAddress && !houseFound);
    final accent = warnState ? Colors.orange.shade800 : AppColors.primaryOnCard;
    final borderColor = outsideArea
        ? Colors.red.withValues(alpha: 0.4)
        : warnState
        ? Colors.orange.withValues(alpha: 0.4)
        : AppColors.primary.withValues(alpha: 0.25);
    final bgColor = warnState
        ? Colors.orange.withValues(alpha: 0.08)
        : AppColors.card;

    final info = InkWell(
      onTap: _editJobSite,
      onLongPress: copyText.isEmpty
          ? null
          : () => AppFeedback.copy(context, copyText),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.location_on_rounded, size: 15, color: accent),
                const Spacer(),
                Icon(
                  Icons.edit_outlined,
                  size: 15,
                  color: Colors.grey.shade600,
                ),
              ],
            ),
            const SizedBox(height: 3),
            _buildAddressVerifyBadge(
              hasAddress: hasAddress,
              verifying: _verifyingAddress,
              houseFound: houseFound,
            ),
            if (contactLine.isNotEmpty) ...[
              const SizedBox(height: 3),
              Row(
                children: [
                  Icon(
                    Icons.person_pin_circle_outlined,
                    size: 14,
                    color: AppColors.primaryOnCard,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '${'На месте'.tr}: $contactLine',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.ink,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 3),
            Text(
              hasAddress
                  ? address
                  : 'Нажмите, чтобы указать адрес работы'.tr,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                height: 1.2,
                fontWeight: FontWeight.w800,
                color: hasAddress ? AppColors.ink : Colors.orange.shade800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              ctrl.contactName.toUpperCase(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 20,
                height: 1.05,
                fontWeight: FontWeight.w900,
                color: Color(0xFF1E88E5),
                letterSpacing: 0.4,
              ),
            ),
            if (hasAddress && !_verifyingAddress && !houseFound) ...[
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 14,
                    color: Colors.orange.shade900,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      'Точный дом не найден на карте — проверьте номер дома и улицу'
                          .tr,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.orange.shade900,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (outsideArea) ...[
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.error_outline_rounded,
                    size: 14,
                    color: Colors.red.shade700,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      'Адрес вне зоны обслуживания'.tr,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.red.shade700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: borderColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: houseFound
          ? IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: info),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(0, 6, 6, 6),
                      child: _buildHouseMapPreview(place, height: mapHeight),
                    ),
                  ),
                ],
              ),
            )
          : info,
    );
  }

  Widget _buildHouseMapPreview(MapPlace place, {required double height}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: Material(
        color: Colors.grey.shade200,
        child: InkWell(
          onTap: () => _openHouseMapSheet(place),
          child: SizedBox(
            height: height,
            width: double.infinity,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.network(
                  MapsService.getStaticMapUrlForPoint(
                    place.location!,
                    width: 320,
                    height: 280,
                    zoom: 16,
                  ),
                  fit: BoxFit.cover,
                  cacheWidth: 320,
                  errorBuilder: (context, error, stackTrace) => Container(
                    color: Colors.grey.shade200,
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.map_outlined,
                      size: 28,
                      color: Colors.grey.shade500,
                    ),
                  ),
                ),
                const Positioned(
                  right: 4,
                  top: 4,
                  child: Icon(
                    Icons.open_in_full_rounded,
                    size: 14,
                    color: Colors.white,
                    shadows: [Shadow(blurRadius: 4, color: Colors.black87)],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAddressVerifyBadge({
    required bool hasAddress,
    required bool verifying,
    required bool houseFound,
  }) {
    if (verifying) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.8,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            'Проверка адреса...'.tr,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.grey.shade600,
            ),
          ),
        ],
      );
    }
    if (!hasAddress) {
      return Text(
        'Адрес не указан'.tr,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: Colors.red.shade600,
        ),
      );
    }
    final color = houseFound
        ? const Color(0xFF2E7D32)
        : Colors.orange.shade900;
    final icon = houseFound
        ? Icons.check_circle_rounded
        : Icons.warning_amber_rounded;
    final text = houseFound ? 'Дом найден'.tr : 'Дом не найден'.tr;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRelatedJobs() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: Text(
            'Эта техника раньше'.tr,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5),
          ),
        ),
        for (final job in _relatedJobs.take(5))
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Builder(
              builder: (context) {
                final color = StatusService.colorOf(job.status);
                return Material(
                  color: Color.alphaBlend(
                    color.withValues(alpha: 0.12),
                    AppColors.card,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(color: color.withValues(alpha: 0.42)),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () {
                      AppNav.openCard(
                        context,
                        key: AppNav.jobKey(job.id),
                        builder: (_) => JobDetailsScreen(
                          jobId: job.id,
                          clientId: job.clientId,
                          jobData: job.toMap(),
                        ),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              trAny(job.status),
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                          Text(
                            DateFormat(
                              'd MMM yyyy',
                              AppLocale.instance.dateLocale,
                            ).format(job.scheduledAt ?? job.createdAt),
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: Colors.grey.shade700,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.chevron_right,
                            size: 18,
                            color: Colors.grey.shade600,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  static const List<Color> _historyPalette = [
    Color(0xFF1565C0),
    Color(0xFF00838F),
    Color(0xFF6A1B9A),
    Color(0xFFEF6C00),
    Color(0xFF2E7D32),
    Color(0xFFAD1457),
    Color(0xFF283593),
  ];

  ({Color color, IconData icon}) _changeVisual(
    JobChangeEvent e,
    int index,
    Color? previousColor,
  ) {
    Color color;
    IconData icon;
    switch (e.event) {
      case 'created':
        color = const Color(0xFF1565C0);
        icon = Icons.fiber_new_rounded;
      case 'status_changed':
        color = const Color(0xFF6A1B9A);
        icon = Icons.swap_horiz_rounded;
      case 'client_name_set':
        color = const Color(0xFF283593);
        icon = Icons.person_outline_rounded;
      case 'visit_added':
        color = const Color(0xFF00838F);
        icon = Icons.event_available_rounded;
      case 'visit_moved':
        color = const Color(0xFFEF6C00);
        icon = Icons.edit_calendar_rounded;
      case 'visit_confirmed':
        color = const Color(0xFF2E7D32);
        icon = Icons.verified_rounded;
      case 'visit_cancelled':
        color = const Color(0xFFC62828);
        icon = Icons.event_busy_rounded;
      case 'payment_recorded':
      case 'tip_recorded':
      case 'invoice_fully_paid':
        color = const Color(0xFF008F3B);
        icon = Icons.payments_outlined;
      case 'refund_recorded':
        color = const Color(0xFFD32F2F);
        icon = Icons.replay_rounded;
      case 'merged_duplicate':
      case 'merged_into':
        color = const Color(0xFF5E35B1);
        icon = Icons.merge_rounded;
      default:
        color = _historyPalette[index % _historyPalette.length];
        icon = Icons.history_rounded;
    }
    if (previousColor != null && color.toARGB32() == previousColor.toARGB32()) {
      color = _historyPalette[(index + 1) % _historyPalette.length];
      if (color.toARGB32() == previousColor.toARGB32()) {
        color = _historyPalette[(index + 2) % _historyPalette.length];
      }
    }
    return (color: color, icon: icon);
  }

  void _toggleHistory() {
    final next = !_historyExpanded;
    setState(() => _historyExpanded = next);
    if (next) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        final max = _scrollController.position.maxScrollExtent;
        if (max <= 0) return;
        final target = (_scrollController.offset + 150.0).clamp(0.0, max);
        if (target > _scrollController.offset) {
          _scrollController.animateTo(
            target,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
          );
        }
      });
    }
  }

  Widget _buildChangeHistoryHeader() {
    final borderSide = BorderSide(
      color: AppColors.primary.withValues(alpha: 0.32),
      width: 1.2,
    );
    final radius = BorderRadius.vertical(
      top: const Radius.circular(12),
      bottom: _historyExpanded ? Radius.zero : const Radius.circular(12),
    );
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: radius,
        border: Border(
          top: borderSide,
          left: borderSide,
          right: borderSide,
          bottom: _historyExpanded
              ? BorderSide(
                  color: AppColors.primary.withValues(alpha: 0.18),
                  width: 1.0,
                )
              : borderSide,
        ),
        boxShadow: _historyExpanded
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: AppColors.primary.withValues(alpha: 0.09),
        child: InkWell(
          onTap: _toggleHistory,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Icon(
                  Icons.history_rounded,
                  size: 16,
                  color: AppColors.primaryOnCard,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'История'.tr,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      color: AppColors.primaryOnCard,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 1.5,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${_changes.length}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primaryOnCard,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  _historyExpanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 20,
                  color: AppColors.primaryOnCard,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildChangeHistoryBody() {
    Color? lastColor;
    final rows = <Widget>[];
    for (var i = 0; i < _changes.length; i++) {
      final visual = _changeVisual(_changes[i], i, lastColor);
      lastColor = visual.color;
      rows.add(
        _buildChangeRow(
          _changes[i],
          color: visual.color,
          icon: visual.icon,
          isLast: i == _changes.length - 1,
        ),
      );
    }
    final borderSide = BorderSide(
      color: AppColors.primary.withValues(alpha: 0.32),
      width: 1.2,
    );
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
        border: Border(
          left: borderSide,
          right: borderSide,
          bottom: borderSide,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.all(8),
      child: rows.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                context.tr('Пока нет записей', 'No entries yet'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.inkMuted,
                ),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rows,
            ),
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

  Widget _buildChangeRow(
    JobChangeEvent e, {
    required Color color,
    required IconData icon,
    required bool isLast,
  }) {
    final label = _changeLabel(e);
    final by = _byLabel(e.by);
    final time = DateFormat(
      'd MMM HH:mm',
      AppLocale.instance.dateLocale,
    ).format(e.at);
    return Container(
      margin: EdgeInsets.only(bottom: isLast ? 0 : 5),
      decoration: BoxDecoration(
        color: Color.alphaBlend(color.withValues(alpha: 0.14), AppColors.card),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.45), width: 1.1),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 4, color: color),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Icon(icon, size: 15, color: color),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                          color: AppColors.ink,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        by,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          color: color,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      time,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppColors.inkMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Одна нить переписки по заявке: SMS с номера или письма с адреса.
class _CommsThread {
  final bool email;
  final String address;
  final String name;
  final String label;
  final int count;
  final DateTime? lastAt;
  final String preview;

  const _CommsThread({
    required this.email,
    required this.address,
    required this.name,
    this.label = '',
    required this.count,
    required this.lastAt,
    required this.preview,
  });
}

class _CassetteIcon extends StatelessWidget {
  final double size;

  const _CassetteIcon({this.size = 31});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size * 21 / 31,
      child: const CustomPaint(painter: _CassettePainter()),
    );
  }
}

class _CassettePainter extends CustomPainter {
  const _CassettePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    const ink = Color(0xFF1A1A1A);
    final stroke = w * 0.065;
    final line = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final thin = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke * 0.75;
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(stroke / 2, stroke / 2, w - stroke, h - stroke),
      Radius.circular(w * 0.1),
    );
    canvas.drawRRect(body, Paint()..color = Colors.white);
    canvas.drawRRect(body, line);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(w * 0.2, h * 0.2, w * 0.8, h * 0.62),
        Radius.circular(h * 0.16),
      ),
      thin,
    );
    for (final x in [w * 0.37, w * 0.63]) {
      final center = Offset(x, h * 0.41);
      canvas.drawCircle(center, h * 0.12, Paint()..color = ink);
      canvas.drawCircle(center, h * 0.045, Paint()..color = Colors.white);
    }
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.24, h - stroke / 2)
        ..lineTo(w * 0.31, h * 0.77)
        ..lineTo(w * 0.69, h * 0.77)
        ..lineTo(w * 0.76, h - stroke / 2),
      line,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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

class _HouseMapSheet extends StatefulWidget {
  final MapPlace place;
  final String rawAddress;
  final String contactLine;

  const _HouseMapSheet({
    required this.place,
    required this.rawAddress,
    required this.contactLine,
  });

  @override
  State<_HouseMapSheet> createState() => _HouseMapSheetState();
}

class _HouseMapSheetState extends State<_HouseMapSheet> {
  GoogleMapController? _map;
  MapType _mapType = MapType.normal;

  LatLng get _point => widget.place.location!;

  @override
  void dispose() {
    // Без dispose нативный вид карты остаётся в памяти после закрытия
    // окна. Несколько открытий подряд и есть те зависания, после которых
    // приходится перезапускать приложение.
    _map?.dispose();
    super.dispose();
  }

  void _centerOnHouse() {
    _map?.animateCamera(CameraUpdate.newLatLngZoom(_point, 17));
  }

  @override
  Widget build(BuildContext context) {
    final formatted = widget.place.address.trim();
    final raw = widget.rawAddress.trim();
    final showFormatted =
        formatted.isNotEmpty &&
        formatted.toLowerCase() != raw.toLowerCase();
    final outsideArea = widget.place.insideServiceArea == false;
    final height = MediaQuery.sizeOf(context).height * 0.85;

    return SafeArea(
      top: false,
      child: SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Icon(Icons.home_rounded, color: AppColors.primaryOnCard, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Дом на карте'.tr,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primaryOnCard,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      setState(() {
                        _mapType = _mapType == MapType.normal
                            ? MapType.hybrid
                            : MapType.normal;
                      });
                    },
                    icon: Icon(
                      _mapType == MapType.normal
                          ? Icons.satellite_alt_rounded
                          : Icons.map_outlined,
                      size: 18,
                    ),
                    label: Text(
                      _mapType == MapType.normal ? 'Спутник'.tr : 'Схема'.tr,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Material(
                color: AppColors.cardMuted,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: outsideArea
                        ? Colors.red.shade300
                        : AppColors.border,
                  ),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Navigator.pop(context, 'edit'),
                  onLongPress: () => AppFeedback.copy(
                    context,
                    formatted.isNotEmpty ? formatted : raw,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.place_rounded,
                          color: Colors.red.shade600,
                          size: 22,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                raw.isNotEmpty ? raw : formatted,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.ink,
                                ),
                              ),
                              if (showFormatted) ...[
                                const SizedBox(height: 2),
                                Text(
                                  formatted,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.inkMuted,
                                  ),
                                ),
                              ],
                              if (widget.contactLine.isNotEmpty) ...[
                                const SizedBox(height: 3),
                                Text(
                                  '${'На месте'.tr}: ${widget.contactLine}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.primaryOnCard,
                                  ),
                                ),
                              ],
                              if (outsideArea) ...[
                                const SizedBox(height: 3),
                                Text(
                                  'Адрес вне зоны обслуживания'.tr,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.red.shade700,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        Icon(
                          Icons.edit_outlined,
                          size: 18,
                          color: AppColors.primary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Stack(
                children: [
                  GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: _point,
                      zoom: 17,
                    ),
                    mapType: _mapType,
                    myLocationEnabled: true,
                    myLocationButtonEnabled: true,
                    zoomControlsEnabled: true,
                    markers: {
                      Marker(
                        markerId: const MarkerId('job_site_house'),
                        position: _point,
                        infoWindow: InfoWindow(
                          title: raw.isNotEmpty ? raw : formatted,
                          snippet: showFormatted ? formatted : null,
                        ),
                      ),
                    },
                    onMapCreated: (controller) {
                      _map = controller;
                      controller.showMarkerInfoWindow(
                        const MarkerId('job_site_house'),
                      );
                    },
                  ),
                  Positioned(
                    left: 12,
                    bottom: 16,
                    child: FloatingActionButton.small(
                      heroTag: 'center_house_pin',
                      backgroundColor: Colors.white,
                      foregroundColor: AppColors.primary,
                      tooltip: 'Дом на карте'.tr,
                      onPressed: _centerOnHouse,
                      child: const Icon(Icons.home_rounded),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.pop(context, 'edit'),
                      icon: const Icon(Icons.edit_location_alt_outlined),
                      label: Text('Изменить адрес'.tr),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => Navigator.pop(context, 'navigate'),
                      icon: const Icon(Icons.navigation_rounded),
                      label: Text('Маршрут'.tr),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: Colors.black,
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
