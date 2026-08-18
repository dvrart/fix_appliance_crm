import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path/path.dart' as path;
import 'package:intl/intl.dart';
import 'package:signature/signature.dart';
import '../../../../core/constants.dart';
import '../../../../core/utils/app_time_picker.dart';
import '../../../../models/job.dart';
import '../../../../services/services.dart';
import '../../../clients/client_details_screen.dart';
import '../../../calls/call_screen.dart';
import '../../../messages/conversation_screen.dart';
import '../job_details_controller.dart';
import '../job_details_screen.dart';
import '../widgets/full_screen_gallery.dart';
import '../../../../core/l10n/app_locale.dart';
import '../../../../shared/widgets/keyboard_safe.dart';
import '../../../../widgets/smart_address_picker.dart';

class DetailsTab extends StatefulWidget {
  final JobDetailsController controller;

  const DetailsTab({super.key, required this.controller});

  @override
  State<DetailsTab> createState() => _DetailsTabState();
}

class _DetailsTabState extends State<DetailsTab> {
  JobDetailsController get ctrl => widget.controller;
  List<Job> _relatedJobs = const [];

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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Нет телефона'.tr)),
      );
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
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
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
          contactName: contact.displayName,
        ),
      ),
    );
  }

  void _showStatusMenu() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return StreamBuilder<List<String>>(
          stream: StatusService.streamAll(),
          builder: (context, snapshot) {
            final statuses = snapshot.data ?? JobStatuses.all;
            final maxHeight = MediaQuery.of(context).size.height * 0.7;
            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Выберите статус'.tr,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
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
                              isSelected ? Icons.check_circle : Icons.circle_outlined,
                              color: StatusService.colorOf(status),
                            ),
                            title: Text(trAny(StatusService.labelOf(status))),
                            selected: isSelected,
                            onTap: () async {
                              Navigator.pop(context);
                              if (status == JobStatuses.completed &&
                                  ctrl.currentStatus != JobStatuses.completed) {
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
    var startAt = existing?.startAt ??
        DateTime(last.year, last.month, last.day, last.hour, last.minute)
            .add(existing == null ? const Duration(days: 7) : Duration.zero);
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
                        leading: const Icon(Icons.calendar_month, color: AppColors.primary),
                        title: Text(DateFormat('d MMMM yyyy', AppLocale.instance.dateLocale).format(startAt)),
                        trailing: const Icon(Icons.edit, size: 18, color: Colors.grey),
                        onTap: pickDate,
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.schedule, color: AppColors.primary),
                        title: Text(DateFormat('HH:mm').format(startAt)),
                        trailing: const Icon(Icons.edit, size: 18, color: Colors.grey),
                        onTap: pickTime,
                      ),
                      Row(
                        children: [
                          const Icon(Icons.timer_outlined, color: AppColors.primary),
                          const SizedBox(width: 12),
                          Expanded(child: Text('Длительность визита'.tr)),
                          DropdownButton<int>(
                            value: const [30, 45, 60, 90, 120, 180].contains(duration)
                                ? duration
                                : 60,
                            underline: const SizedBox.shrink(),
                            items: [
                              DropdownMenuItem(value: 30, child: Text('30 мин'.tr)),
                              DropdownMenuItem(value: 45, child: Text('45 мин'.tr)),
                              DropdownMenuItem(value: 60, child: Text('1 час'.tr)),
                              DropdownMenuItem(value: 90, child: Text('1.5 часа'.tr)),
                              DropdownMenuItem(value: 120, child: Text('2 часа'.tr)),
                              DropdownMenuItem(value: 180, child: Text('3 часа'.tr)),
                            ],
                            onChanged: (value) {
                              if (value != null) setSheet(() => duration = value);
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
                        children: [
                          for (final preset in presets)
                            ChoiceChip(
                              label: Text(trAny(preset)),
                              selected: note.trim() == preset,
                              onSelected: (_) {
                                noteCtrl.text = preset;
                                setSheet(() => note = preset);
                              },
                            ),
                        ],
                      ),
                      if (existing != null) ...[
                        const SizedBox(height: 8),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('Выполнен'.tr),
                          value: outcome == JobVisit.done,
                          onChanged: (value) {
                            setSheet(() {
                              outcome = value ? JobVisit.done : JobVisit.scheduled;
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

  Widget _buildDurationAndPacking() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Row(
            children: [
              const Icon(Icons.timer_outlined, color: AppColors.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Длительность нового визита'.tr,
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              DropdownButton<int>(
                value: const [30, 45, 60, 90, 120, 180].contains(ctrl.durationMinutes)
                    ? ctrl.durationMinutes
                    : 60,
                underline: const SizedBox.shrink(),
                items: [
                  DropdownMenuItem(value: 30, child: Text('30 мин'.tr)),
                  DropdownMenuItem(value: 45, child: Text('45 мин'.tr)),
                  DropdownMenuItem(value: 60, child: Text('1 час'.tr)),
                  DropdownMenuItem(value: 90, child: Text('1.5 часа'.tr)),
                  DropdownMenuItem(value: 120, child: Text('2 часа'.tr)),
                  DropdownMenuItem(value: 180, child: Text('3 часа'.tr)),
                ],
                onChanged: (value) {
                  if (value != null) ctrl.updateDurationMinutes(value);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: _editPackingNotes,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Row(
              children: [
                const Icon(Icons.inventory_2_outlined, color: AppColors.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Что взять с собой'.tr,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        ctrl.packingNotes.trim().isEmpty
                            ? 'Нажмите, чтобы добавить'.tr
                            : ctrl.packingNotes,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.edit, color: Colors.grey, size: 18),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: _editTracking,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Row(
              children: [
                const Icon(Icons.local_shipping_outlined, color: AppColors.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Отслеживание'.tr,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        ctrl.trackingNumber.isEmpty
                            ? 'Номер Amazon / трек — нажмите'.tr
                            : [
                                ctrl.trackingNumber,
                                if (ctrl.trackingStatus.isNotEmpty)
                                  _trackingLabel(ctrl.trackingStatus),
                              ].join(' · '),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.edit, color: Colors.grey, size: 18),
              ],
            ),
          ),
        ),
      ],
    );
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
    final numberCtrl = TextEditingController(text: ctrl.trackingNumber);
    final amazonCtrl = TextEditingController(text: ctrl.amazonOrderId);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Отслеживание'.tr),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: numberCtrl,
              decoration: InputDecoration(
                labelText: 'Трек-номер'.tr,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: amazonCtrl,
              decoration: InputDecoration(
                labelText: 'Номер заказа Amazon'.tr,
                hintText: '123-1234567-1234567',
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Отмена'.tr),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Сохранить'.tr),
          ),
        ],
      ),
    );
    if (saved == true) {
      await ctrl.updateTracking(
        number: numberCtrl.text,
        amazonId: amazonCtrl.text,
      );
    }
    numberCtrl.dispose();
    amazonCtrl.dispose();
  }

  Future<void> _editPackingNotes() async {
    final controller = TextEditingController(text: ctrl.packingNotes);
    final saved = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Что взять с собой'.tr),
        scrollable: true,
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: InputDecoration(
            hintText: 'Фильтр, плата, ключи…'.tr,
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Отмена'.tr),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text('Сохранить'.tr),
          ),
        ],
      ),
    );
    if (saved != null) await ctrl.updatePackingNotes(saved);
  }

  void _editWorkAddress() {
    final raw = ctrl.hasJobSite
        ? ctrl.jobSiteAddress
        : (ctrl.jobData['clientAddress'] ?? '').toString();
    final parts = splitAddress(raw);
    showSmartAddressPicker(
      context: context,
      initialStreet: parts[0],
      initialCity: parts[1],
      initialPostal: parts[2],
      onSaved: (street, city, postal) {
        ctrl.updateWorkAddress(street: street, city: city, postal: postal);
      },
    );
  }

  Map<String, String> _applianceFields() {
    final appliances = ctrl.jobData['appliances'];
    Map<String, dynamic>? primary;
    if (appliances is List && appliances.isNotEmpty && appliances.first is Map) {
      primary = Map<String, dynamic>.from(appliances.first as Map);
    }
    return {
      'type': (ctrl.jobData['applianceType'] ?? primary?['type'] ?? '').toString(),
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
    if (!mounted) return;
    setState(() => _relatedJobs = jobs);
  }

  Future<void> _completeJobFlow() async {
    final config = await SettingsService.loadConfig();
    if (!mounted) return;
    final askSignature = SettingsService.boolFlag(config, 'useSignature');
    var sendReview = SettingsService.readAutoReviewSmsEnabled(config);
    var sendInvoice = ctrl.documents.any(Job.isInvoice);
    final signatureCtrl = askSignature
        ? SignatureController(penStrokeWidth: 2.2, penColor: Colors.black)
        : null;

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
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
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                    ),
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      value: sendReview,
                      contentPadding: EdgeInsets.zero,
                      title: Text('Отправить SMS с просьбой об отзыве'.tr),
                      onChanged: (value) =>
                          setSheet(() => sendReview = value ?? false),
                    ),
                    CheckboxListTile(
                      value: sendInvoice,
                      contentPadding: EdgeInsets.zero,
                      title: Text('Отправить счёт'.tr),
                      subtitle: ctrl.documents.any(Job.isInvoice)
                          ? null
                          : Text('Сначала создайте Invoice на вкладке Финансы'.tr),
                      onChanged: ctrl.documents.any(Job.isInvoice)
                          ? (value) => setSheet(() => sendInvoice = value ?? false)
                          : null,
                    ),
                    if (askSignature) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Подпись клиента'.tr,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        height: 160,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Signature(
                          controller: signatureCtrl!,
                          backgroundColor: Colors.grey.shade50,
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => setSheet(() => signatureCtrl.clear()),
                          child: Text('Очистить подпись'.tr),
                        ),
                      ),
                    ],
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
    final bytes = askSignature ? await signatureCtrl?.toPngBytes() : null;
    signatureCtrl?.dispose();
    if (confirmed != true || !mounted) return;

    if (askSignature && (bytes == null || bytes.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Нужна подпись клиента'.tr)),
      );
      return;
    }

    if (bytes != null && bytes.isNotEmpty) {
      try {
        final fileName = 'signature_${DateTime.now().millisecondsSinceEpoch}.png';
        final storageRef = FirebaseStorage.instance
            .ref()
            .child('jobs/${ctrl.jobId}/attachments/$fileName');
        await storageRef.putData(bytes, SettableMetadata(contentType: 'image/png'));
        final url = await storageRef.getDownloadURL();
        final attachment = {
          'url': url,
          'name': fileName,
          'kind': 'signature',
          'uploadedAt': DateTime.now().toIso8601String(),
        };
        ctrl.addAttachment(attachment);
        await JobService.addAttachment(ctrl.jobId, attachment);
      } catch (_) {}
    }

    await ctrl.updateStatus(
      JobStatuses.completed,
      extra: sendReview
          ? null
          : {'reviewSmsSentAt': FieldValue.serverTimestamp()},
    );
    if (!mounted) return;

    if (sendInvoice && mounted) {
      final index = ctrl.documents.lastIndexWhere(Job.isInvoice);
      if (index >= 0) {
        final doc = ctrl.documents[index];
        final items = doc['items'] as List? ?? [];
        final subtotal = ctrl.calcSubtotal(items);
        final tax = ctrl.calcTax(subtotal, doc['taxRate'] ?? 0.0);
        final total = ctrl.calcTotal(subtotal, tax);
        final paid = ctrl.calcPaid(doc['payments'] ?? []);
        await DocumentTemplateService.showSendSheet(
          context: context,
          data: DocumentSendData(
            kind: 'invoice',
            jobId: ctrl.jobId,
            clientId: ctrl.clientId,
            clientName: (ctrl.jobData['clientName'] ?? ctrl.contactName).toString(),
            clientPhone: (ctrl.jobData['clientPhone'] ?? ctrl.contactPhone).toString(),
            clientAddress: (ctrl.jobData['clientAddress'] ?? ctrl.workAddress).toString(),
            documentNumber: index + 1,
            items: items,
            subtotal: subtotal,
            tax: tax,
            taxRate: (doc['taxRate'] as num?)?.toDouble() ?? 0,
            total: total,
            paid: paid,
            due: ctrl.calcDue(total, paid),
          ),
        );
      }
    }
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
          if (visits.isEmpty)
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
            )
          else
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
                    DateFormat('d MMMM yyyy, HH:mm', AppLocale.instance.dateLocale)
                        .format(visit.startAt),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      decoration: done ? TextDecoration.lineThrough : null,
                      color: done ? Colors.black54 : Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      done ? 'Выполнен'.tr : 'Запланирован'.tr,
                      _visitDurationLabel(visit.durationMinutes),
                      if (visit.smsConfirmStatus == JobVisit.confirmConfirmed)
                        'Клиент подтвердил'.tr,
                      if (visit.smsConfirmStatus == JobVisit.confirmReschedule)
                        'Просит перенос'.tr,
                      if (visit.smsConfirmStatus == JobVisit.confirmPending)
                        'Ждём SMS'.tr,
                      if (visit.note.trim().isNotEmpty) visit.note.trim(),
                    ].join(' · '),
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade700,
                    ),
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

  void _editDescription() {
    final textController = TextEditingController(text: ctrl.currentDescription);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Описание проблемы'.tr),
          scrollable: true,
          content: TextField(
            controller: textController,
            maxLines: 5,
            decoration: InputDecoration(
              hintText: 'Опишите проблему...'.tr,
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Отмена'.tr),
            ),
            ElevatedButton(
              onPressed: () {
                ctrl.updateDescription(textController.text.trim());
                Navigator.pop(context);
              },
              child: Text('Сохранить'.tr),
            ),
          ],
        );
      },
    );
  }

  Future<void> _pickAndUploadImage(ImageSource source) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(
      source: source,
      maxWidth: 1200,
      imageQuality: 85,
    );

    if (pickedFile == null) return;

    ctrl.setUploadingImage(true);
    final fileName =
        '${DateTime.now().millisecondsSinceEpoch}_${path.basename(pickedFile.path)}';

    try {
      final file = File(pickedFile.path);
      final storageRef = FirebaseStorage.instance
          .ref()
          .child('jobs/${ctrl.jobId}/attachments/$fileName');

      await storageRef.putFile(file);
      final downloadUrl = await storageRef.getDownloadURL();

      final attachment = {
        'url': downloadUrl,
        'name': fileName,
        'uploadedAt': DateTime.now().toIso8601String(),
      };

      ctrl.addAttachment(attachment);
      await JobService.addAttachment(ctrl.jobId, attachment);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Фото загружено'.tr),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      final attachment = {
        'url': '',
        'localPath': pickedFile.path,
        'name': fileName,
        'pendingUpload': true,
        'uploadedAt': DateTime.now().toIso8601String(),
      };
      ctrl.addAttachment(attachment);
      await OfflineQueueService.enqueuePhoto(
        jobId: ctrl.jobId,
        localPath: pickedFile.path,
        fileName: fileName,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Нет сети — фото сохранится и загрузится позже'.tr),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } finally {
      ctrl.setUploadingImage(false);
    }
  }

  void _showAddPhotoMenu() {
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
              ListTile(
                leading: const Icon(Icons.camera_alt, color: AppColors.primary),
                title: Text('Сделать фото'.tr),
                onTap: () {
                  Navigator.pop(context);
                  _pickAndUploadImage(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library, color: AppColors.primary),
                title: Text('Выбрать из галереи'.tr),
                onTap: () {
                  Navigator.pop(context);
                  _pickAndUploadImage(ImageSource.gallery);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _openGallery(int initialIndex) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => FullScreenGallery(
          images: ctrl.attachments,
          initialIndex: initialIndex,
        ),
      ),
    );
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
                    'ИИ создал эту заявку после звонка. Проверьте данные и подтвердите.'.tr,
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
          // Статус и клиент
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Статус
              Expanded(
                flex: 5,
                child: GestureDetector(
                  onTap: _showStatusMenu,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: ctrl.getStatusColor().withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: ctrl.getStatusColor().withOpacity(0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Статус'.tr,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                trAny(StatusService.labelOf(ctrl.currentStatus)),
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: ctrl.getStatusColor(),
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            Icon(Icons.arrow_drop_down, color: ctrl.getStatusColor()),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Клиент
              Expanded(
                flex: 4,
                child: GestureDetector(
                  onTap: () {
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
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 16,
                          backgroundColor: Colors.blue.shade50,
                          child: const Icon(Icons.person, size: 18, color: AppColors.primary),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            ctrl.jobData['clientName'] ?? 'Клиент'.tr,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Приоритет
          GestureDetector(
            onTap: _showPriorityMenu,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: ctrl.getPriorityColor().withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: ctrl.getPriorityColor().withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.flag, color: ctrl.getPriorityColor()),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      trAny(ctrl.currentPriority),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: ctrl.getPriorityColor(),
                      ),
                    ),
                  ),
                  Icon(Icons.arrow_drop_down, color: ctrl.getPriorityColor()),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Контакт и навигация
          _buildContactCard(),
          const SizedBox(height: 16),

          // История визитов
          _buildVisitsCard(),
          const SizedBox(height: 12),
          _buildDurationAndPacking(),
          const SizedBox(height: 16),

          // Описание
          _buildDescriptionCard(),
          const SizedBox(height: 16),

          // Техника
          _buildApplianceCard(),
          const SizedBox(height: 16),

          // Фото
          _buildPhotosSection(),
        ],
      ),
    );
  }

  Widget _buildContactCard() {
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
          Row(
            children: [
              Icon(
                ctrl.hasJobSite ? Icons.location_city : Icons.home,
                color: AppColors.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  ctrl.hasJobSite ? 'Место работы (Job Site)'.tr : 'Адрес клиента'.tr,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: AppColors.primary,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Изменить адрес'.tr,
                icon: Icon(Icons.edit, color: Colors.grey.shade600, size: 20),
                onPressed: _editWorkAddress,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            ctrl.contactName,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 4),
          GestureDetector(
            onTap: _editWorkAddress,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    ctrl.workAddress,
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                ),
                Icon(Icons.chevron_right, color: Colors.grey.shade400),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              // Время в пути / GO
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
              // Позвонить (через Twilio, прямо в приложении)
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

  Widget _buildDescriptionCard() {
    return GestureDetector(
      onTap: _editDescription,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.description, color: AppColors.primary, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Описание проблемы'.tr,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: AppColors.primary,
                  ),
                ),
                const Spacer(),
                Icon(Icons.edit, color: Colors.grey.shade400, size: 18),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              ctrl.currentDescription.isEmpty
                  ? 'Нажмите, чтобы добавить описание...'.tr
                  : ctrl.currentDescription,
              style: TextStyle(
                color: ctrl.currentDescription.isEmpty
                    ? Colors.grey
                    : Colors.black87,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildApplianceCard() {
    final appliances = ctrl.jobData['appliances'];
    Map<String, dynamic>? primary;
    if (appliances is List && appliances.isNotEmpty && appliances.first is Map) {
      primary = Map<String, dynamic>.from(appliances.first as Map);
    }
    final applianceType =
        ctrl.jobData['applianceType'] ?? primary?['type'] ?? 'Техника'.tr;
    final brand = (ctrl.jobData['brand'] ?? primary?['brand'] ?? '').toString();
    final model = (ctrl.jobData['model'] ?? primary?['model'] ?? '').toString();
    final serial =
        (ctrl.jobData['serialNumber'] ?? primary?['serialNumber'] ?? '').toString();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.accent.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  ApplianceCategories.getIcon(applianceType),
                  color: AppColors.primary,
                  size: 32,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      trAny(applianceType),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    if (brand.isNotEmpty || model.isNotEmpty)
                      Text(
                        [brand, model].where((s) => s.isNotEmpty).join(' • '),
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    if (serial.isNotEmpty)
                      Text(
                        '${'S/N'.tr} $serial',
                        style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_relatedJobs.isNotEmpty) ...[
          const SizedBox(height: 8),
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
                    ? DateFormat('d MMM yyyy', AppLocale.instance.dateLocale)
                        .format(job.scheduledAt!)
                    : DateFormat('d MMM yyyy', AppLocale.instance.dateLocale)
                        .format(job.createdAt),
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
      ],
    );
  }

  Widget _buildPhotosSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Фото'.tr,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            TextButton.icon(
              onPressed: ctrl.isUploadingImage ? null : _showAddPhotoMenu,
              icon: ctrl.isUploadingImage
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_a_photo),
              label: Text(ctrl.isUploadingImage ? 'Загрузка...'.tr : 'Добавить'.tr),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (ctrl.attachments.isEmpty)
          Container(
            height: 100,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade300, style: BorderStyle.solid),
            ),
            child: Center(
              child: Text(
                'Нет фотографий'.tr,
                style: TextStyle(color: Colors.grey),
              ),
            ),
          )
        else
          SizedBox(
            height: 100,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: ctrl.attachments.length,
              itemBuilder: (context, index) {
                final attachment = ctrl.attachments[index];
                return GestureDetector(
                  onTap: () => _openGallery(index),
                  child: Container(
                    width: 100,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      image: DecorationImage(
                        image: (attachment['localPath'] != null &&
                                (attachment['url'] == null ||
                                    attachment['url'].toString().isEmpty))
                            ? FileImage(File(attachment['localPath']))
                            : NetworkImage(attachment['url'] ?? '')
                                as ImageProvider,
                        fit: BoxFit.cover,
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
}
