import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/constants.dart';
import '../../core/utils/app_date_picker.dart';
import '../../services/ai_service.dart';
import '../../services/client_service.dart';
import '../../services/job_service.dart';
import '../../services/sms_service.dart';
import '../../services/twilio_service.dart';
import '../../models/client.dart';
import '../../models/job.dart';
import '../../widgets/smart_address_picker.dart';
import '../../services/catalog_service.dart';
import '../../shared/widgets/catalog_picker.dart';
import '../../core/l10n/app_locale.dart';
import '../../shared/widgets/app_bar_save.dart';
import '../../shared/widgets/dirty_leave_scope.dart';

/// Экран предпросмотра извлечённых данных
class JobPreviewScreen extends StatefulWidget {
  final ExtractedJobData extractedData;
  final String originalText;
  final String? fallbackPhone;
  final String? fallbackEmail;
  final String? existingClientId;
  final Client? existingClient;
  final String? sourceMessageId;
  final String sourceEmailFrom;
  final String sourceEmailSubject;
  /// Если задан — после создания заявки звонок будет привязан к ней.
  final String? sourceCallId;
  /// Если задан — после создания заявки SMS будет помечена как принятая.
  final String? sourceSmsId;

  const JobPreviewScreen({
    super.key,
    required this.extractedData,
    required this.originalText,
    this.fallbackPhone,
    this.fallbackEmail,
    this.existingClientId,
    this.existingClient,
    this.sourceMessageId,
    this.sourceEmailFrom = '',
    this.sourceEmailSubject = '',
    this.sourceCallId,
    this.sourceSmsId,
  });

  @override
  State<JobPreviewScreen> createState() => _JobPreviewScreenState();
}

class _JobPreviewScreenState extends State<JobPreviewScreen> {
  late TextEditingController _nameController;
  late TextEditingController _phoneController;
  late TextEditingController _emailController;
  late TextEditingController _addressController;
  late TextEditingController _unitController;
  late TextEditingController _cityController;
  late TextEditingController _postalController;
  late TextEditingController _applianceController;
  late TextEditingController _brandController;
  late TextEditingController _problemController;
  late TextEditingController _contactNameController;
  late TextEditingController _contactPhoneController;

  DateTime? _scheduledDate;
  TimeOfDay? _scheduledTime;
  bool _hasJobSite = false;
  bool _isSaving = false;
  Client? _existingClient;
  bool _editingExistingClient = false;

  List<String> _suggestedParts = [];
  bool _isLoadingParts = false;

  @override
  void initState() {
    super.initState();
    final data = widget.extractedData;

    _nameController = TextEditingController(
      text: Client.stripClientWord(data.clientName),
    );
    _phoneController = TextEditingController(
      text: data.clientPhone ?? widget.fallbackPhone ?? '',
    );
    _emailController = TextEditingController(
      text: data.clientEmail ?? widget.fallbackEmail ?? '',
    );
    final peeled = peelUnit(data.address ?? '');
    final initialUnit = (data.unit ?? '').trim().isNotEmpty
        ? data.unit!.trim()
        : peeled.unit;
    _addressController = TextEditingController(
      text: (data.unit ?? '').trim().isNotEmpty
          ? (data.address ?? '')
          : peeled.street,
    );
    _unitController = TextEditingController(text: initialUnit);
    _cityController = TextEditingController(text: data.city ?? '');
    _postalController = TextEditingController(text: data.postalCode ?? '');
    _applianceController = TextEditingController(text: data.applianceType ?? '');
    _brandController = TextEditingController(text: data.brand ?? '');
    _problemController = TextEditingController(text: data.problemDescription ?? '');
    _contactNameController = TextEditingController(text: data.contactOnSiteName ?? '');
    _contactPhoneController = TextEditingController(text: data.contactOnSitePhone ?? '');
    _hasJobSite = data.hasJobSite;

    if (widget.existingClient != null && !widget.existingClient!.isDeleted) {
      _applyExistingClient(widget.existingClient!);
    } else {
      unawaited(_resolveExistingClient());
    }

    _scheduledDate = _parseDate(data.scheduledDate) ?? DateTime.now();

    if (data.scheduledTime != null) {
      _scheduledTime = _parseTime(data.scheduledTime);
    }
    _scheduledTime ??= const TimeOfDay(hour: 9, minute: 0);

    _loadPartsSuggestions();
  }

  void _applyExistingClient(Client client) {
    _existingClient = client;
    final cleanName = Client.stripClientWord(client.fullName);
    if (cleanName.isNotEmpty) {
      _nameController.text = cleanName;
    } else if (_nameController.text.trim().isEmpty && client.phone.trim().isNotEmpty) {
      _nameController.text = client.phone.trim();
    }
    if (client.phone.trim().isNotEmpty) {
      _phoneController.text = client.phone.trim();
    }
    if ((client.email ?? '').trim().isNotEmpty) {
      _emailController.text = client.email!.trim();
    }
    final loc = client.primaryLocation;
    // Адрес клиента подставляется, только если другого адреса в форме нет:
    // названное в звонке или переписке место работы не затираем.
    final extractedStreet = _addressController.text.trim();
    final hasClientAddr = client.address.trim().isNotEmpty &&
        extractedStreet.isEmpty;
    if (hasClientAddr) {
      if (loc != null &&
          (loc.street.trim().isNotEmpty ||
              loc.city.trim().isNotEmpty ||
              loc.postalCode.trim().isNotEmpty)) {
        final peeled = peelUnit(loc.street);
        _addressController.text =
            (loc.unit ?? '').trim().isNotEmpty ? loc.street : peeled.street;
        _unitController.text =
            (loc.unit ?? '').trim().isNotEmpty ? loc.unit!.trim() : peeled.unit;
        _cityController.text = loc.city;
        _postalController.text = loc.postalCode;
      } else {
        final parts = splitAddress(client.address);
        final peeled = peelUnit(parts[0]);
        _addressController.text = peeled.street;
        _unitController.text = peeled.unit;
        _cityController.text = parts[1];
        _postalController.text = parts[2];
      }
    } else if (client.address.trim().isNotEmpty &&
        extractedStreet.isNotEmpty &&
        !client.address.toLowerCase().contains(extractedStreet.toLowerCase())) {
      // У существующего клиента уже есть свой адрес, а в сообщении назван
      // другой объект (арендатор / второй дом) — ставим «Другой адрес работы».
      _hasJobSite = true;
    }
  }

  Future<void> _resolveExistingClient() async {
    Client? found;
    final id = (widget.existingClientId ?? '').trim();
    if (id.isNotEmpty) {
      found = await ClientService.getById(id);
      if (found != null && found.isDeleted) found = null;
    }
    final phone = _phoneController.text.trim();
    if (found == null && phone.isNotEmpty) {
      found = await ClientService.findByPhone(phone);
    }
    final email = _emailController.text.trim();
    if (found == null && email.contains('@')) {
      found = await ClientService.findByEmail(email);
    }
    if (found == null || !mounted) return;
    setState(() {
      _applyExistingClient(found!);
    });
  }

  DateTime? _parseDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final value = raw.trim();
    try {
      return DateTime.parse(value);
    } catch (_) {}
    final dotted = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})$').firstMatch(value);
    if (dotted != null) {
      return DateTime(
        int.parse(dotted.group(3)!),
        int.parse(dotted.group(2)!),
        int.parse(dotted.group(1)!),
      );
    }
    return null;
  }

  TimeOfDay? _parseTime(String? raw) {
    if (raw == null) return null;
    try {
      final parts = raw.split(':');
      if (parts.length >= 2) {
        return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
      }
    } catch (_) {}
    return null;
  }

  Future<void> _loadPartsSuggestions() async {
    if (_applianceController.text.isEmpty || _problemController.text.isEmpty) {
      return;
    }

    setState(() => _isLoadingParts = true);

    try {
      final parts = await AiService.suggestParts(
        applianceType: _applianceController.text,
        brand: _brandController.text,
        problemDescription: _problemController.text,
      );
      if (mounted) {
        setState(() {
          _suggestedParts = parts;
          _isLoadingParts = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoadingParts = false);
      }
    }
  }

  /// Дата и время в одном окне — и плитка даты, и плитка времени открывают его.
  Future<void> _pickDateTime() async {
    final now = DateTime.now();
    final day = _scheduledDate ?? now;
    final time = _scheduledTime ?? TimeOfDay.fromDateTime(now);
    final picked = await showAppDateTimeSheet(
      context: context,
      initial: DateTime(day.year, day.month, day.day, time.hour, time.minute),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      title: 'Дата и время визита'.tr,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _scheduledDate = DateTime(picked.year, picked.month, picked.day);
      _scheduledTime = TimeOfDay.fromDateTime(picked);
    });
  }

  bool get _isEmailOffer => (widget.sourceMessageId ?? '').trim().isNotEmpty;

  Future<bool> _saveJob() async {
    final email = _emailController.text.trim();
    final phone = _phoneController.text.trim();
    var name = Client.stripClientWord(_nameController.text.trim());
    if (name.isEmpty && phone.isNotEmpty) {
      name = phone;
      _nameController.text = name;
    } else if (name.isEmpty && email.contains('@')) {
      name = email.split('@').first;
      _nameController.text = name;
    }
    if (name.isEmpty) {
      _showError('Укажите имя клиента'.tr);
      return false;
    }
    if (phone.isEmpty && !email.contains('@')) {
      _showError(
        _isEmailOffer
            ? 'Укажите телефон или email'.tr
            : 'Укажите телефон клиента'.tr,
      );
      return false;
    }
    if (_applianceController.text.trim().isEmpty) {
      _showError('Укажите тип техники'.tr);
      return false;
    }

    setState(() => _isSaving = true);

    try {
      final fullAddress = joinAddress(
        _addressController.text,
        _cityController.text,
        _postalController.text,
        _unitController.text,
      );

      Client? existing = _existingClient;
      final existingId = (widget.existingClientId ?? '').trim();
      if (existing == null && existingId.isNotEmpty) {
        existing = await ClientService.getById(existingId);
        if (existing != null && existing.isDeleted) existing = null;
      }
      existing ??= email.contains('@') ? await ClientService.findByEmail(email) : null;
      if (existing == null && phone.isNotEmpty) {
        existing = await ClientService.findByPhone(phone);
      }

      final String clientId;
      final String resolvedAddress;
      if (existing != null && !_editingExistingClient) {
        clientId = existing.id;
        resolvedAddress = fullAddress.trim().isNotEmpty
            ? fullAddress
            : existing.address;
        if (existing.address.trim().isEmpty && fullAddress.trim().isNotEmpty) {
          await ClientService.updateAddress(
            clientId,
            street: _addressController.text.trim(),
            city: _cityController.text.trim(),
            postal: _postalController.text.trim(),
            unit: _unitController.text.trim(),
          );
        }
      } else {
        resolvedAddress = fullAddress;
        clientId = await ClientService.createOrUpdate(
          existingId: existing?.id,
          fullName: _nameController.text.trim(),
          phone: phone,
          address: fullAddress,
          email: email.contains('@') ? email : existing?.email,
          companyName: existing?.companyName,
          notes: existing?.notes,
          source: existing?.source ?? (_isEmailOffer ? 'email' : null),
        );
        await ClientService.updateAddress(
          clientId,
          street: _addressController.text.trim(),
          city: _cityController.text.trim(),
          postal: _postalController.text.trim(),
          unit: _unitController.text.trim(),
        );
      }

      // Создаём дату-время визита
      final scheduledAt = _scheduledDate != null && _scheduledTime != null
          ? DateTime(
              _scheduledDate!.year,
              _scheduledDate!.month,
              _scheduledDate!.day,
              _scheduledTime!.hour,
              _scheduledTime!.minute,
            )
          : null;

      // Создаём заявку
      final ownerAddress = existing != null &&
              !_editingExistingClient &&
              _hasJobSite &&
              existing.address.trim().isNotEmpty
          ? existing.address.trim()
          : resolvedAddress;
      final job = Job(
        id: '',
        clientId: clientId,
        clientName: _nameController.text.trim(),
        clientPhone: phone,
        clientAddress: ownerAddress,
        hasJobSite: _hasJobSite,
        // Номер телефона в имя на месте не пишем — оно берётся из карточки.
        jobSiteName: _hasJobSite &&
                !Client.isPlaceholderName(_contactNameController.text.trim())
            ? _contactNameController.text.trim()
            : null,
        jobSitePhone: _hasJobSite ? _contactPhoneController.text.trim() : null,
        jobSiteAddress: _hasJobSite ? resolvedAddress : null,
        appliances: [
          JobAppliance(
            type: _applianceController.text.trim(),
            brand: _brandController.text.trim(),
            issue: _problemController.text.trim(),
          ),
        ],
        description: _problemController.text.trim(),
        status: JobStatuses.call,
        priority: JobPriorities.low,
        scheduledAt: scheduledAt,
        createdAt: DateTime.now(),
        city: _cityController.text.trim(),
        needsReview: false,
        source: _isEmailOffer
            ? 'email'
            : (widget.sourceCallId ?? '').isNotEmpty
                ? 'phone'
                : (widget.sourceSmsId ?? '').isNotEmpty
                    ? 'sms'
                    : '',
        sourceCallId: (widget.sourceCallId ?? '').trim().isNotEmpty
            ? widget.sourceCallId
            : null,
        sourceEmailId: widget.sourceMessageId,
        sourceEmailFrom: widget.sourceEmailFrom,
        sourceEmailSubject: widget.sourceEmailSubject,
        sourceEmailPreview: widget.originalText,
        durationMinutes: kDefaultVisitMinutes,
      );

      final jobId = await JobService.create(job);
      if (_isEmailOffer) {
        await SmsService.acceptEmailOffer(
          widget.sourceMessageId!,
          jobId: jobId,
          clientId: clientId,
        );
      }
      final callId = (widget.sourceCallId ?? '').trim();
      if (callId.isNotEmpty) {
        unawaited(TwilioService.attachJob(
          callId: callId,
          jobId: jobId,
          clientId: clientId,
        ));
      }
      final smsId = (widget.sourceSmsId ?? '').trim();
      if (smsId.isNotEmpty) {
        unawaited(SmsService.acceptSmsOffer(
          smsId,
          jobId: jobId,
          clientId: clientId,
        ));
      }

      if (!mounted) return false;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Заявка создана!'.tr),
          backgroundColor: Colors.green,
        ),
      );

      Navigator.pop(context, true);
      return true;
    } catch (e) {
      _showError('${'Ошибка сохранения'.tr}: $e');
      setState(() => _isSaving = false);
      return false;
    }
  }

  Future<void> _dismissOffer() async {
    final id = (widget.sourceMessageId ?? '').trim();
    if (id.isEmpty) {
      Navigator.pop(context, false);
      return;
    }
    setState(() => _isSaving = true);
    try {
      await SmsService.dismissEmailOffer(id);
      if (!mounted) return;
      Navigator.pop(context, false);
    } catch (e) {
      _showError('${'Ошибка сохранения'.tr}: $e');
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _addressController.dispose();
    _unitController.dispose();
    _cityController.dispose();
    _postalController.dispose();
    _applianceController.dispose();
    _brandController.dispose();
    _problemController.dispose();
    _contactNameController.dispose();
    _contactPhoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DirtyLeaveScope(
      dirty: !_isSaving,
      onSave: _saveJob,
      child: Scaffold(
      appBar: AppBar(
        title: Text(
          _isEmailOffer
              ? 'Письмо о ремонте'.tr
              : (_existingClient != null
                  ? 'Новая заявка'.tr
                  : 'Проверьте данные'.tr),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        actions: [
          if (_isEmailOffer)
            TextButton(
              onPressed: _isSaving ? null : _dismissOffer,
              child: Text(
                'Пропустить'.tr,
                style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700),
              ),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_isEmailOffer) ...[
              _buildSection(
                title: 'Письмо'.tr,
                icon: Icons.email_outlined,
                children: [
                  if (widget.sourceEmailFrom.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        '${'От'.tr}: ${widget.sourceEmailFrom}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  if (widget.sourceEmailSubject.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        widget.sourceEmailSubject,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  Text(
                    widget.originalText.trim().isEmpty
                        ? 'Нет текста письма'.tr
                        : widget.originalText.trim(),
                    style: const TextStyle(color: Colors.black87, height: 1.35),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
            if (_existingClient != null && !_editingExistingClient) ...[
              _buildExistingClientCard(),
              const SizedBox(height: 16),
            ] else ...[
              // Информация о клиенте
              _buildSection(
                title: 'Клиент'.tr,
                icon: Icons.person,
                children: [
                  _buildTextField(
                    controller: _nameController,
                    label: 'Имя'.tr,
                    icon: Icons.person_outline,
                  ),
                  _buildTextField(
                    controller: _phoneController,
                    label: 'Телефон'.tr,
                    icon: Icons.phone,
                    keyboardType: TextInputType.phone,
                  ),
                  if (_isEmailOffer)
                    _buildTextField(
                      controller: _emailController,
                      label: 'Email'.tr,
                      icon: Icons.email_outlined,
                      keyboardType: TextInputType.emailAddress,
                    ),
                ],
              ),
              const SizedBox(height: 16),

              // Адрес
              _buildSection(
                title: 'Адрес'.tr,
                icon: Icons.location_on,
                children: [
                  // Кнопка умного поиска адреса
                  GestureDetector(
                    onTap: () {
                      showSmartAddressPicker(
                        context: context,
                        initialStreet: _addressController.text,
                        initialCity: _cityController.text,
                        initialPostal: _postalController.text,
                        initialUnit: _unitController.text,
                        onSaved: (street, city, postal, unit) {
                          setState(() {
                            _addressController.text = street;
                            _cityController.text = city;
                            _postalController.text = postal;
                            _unitController.text = unit;
                          });
                        },
                      );
                    },
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: AppColors.cardMuted,
                        border: Border.all(color: AppColors.border),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.search, color: AppColors.primaryOnCard, size: 24),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _addressController.text.isEmpty && _cityController.text.isEmpty
                                  ? 'Нажмите для поиска адреса...'.tr
                                  : joinAddress(
                                      _addressController.text,
                                      _cityController.text,
                                      _postalController.text,
                                      _unitController.text,
                                    ),
                              style: TextStyle(
                                color: _addressController.text.isEmpty &&
                                        _cityController.text.isEmpty
                                    ? Colors.grey
                                    : AppColors.ink,
                                fontSize: 16,
                              ),
                            ),
                          ),
                          Icon(Icons.edit, color: Colors.grey.shade400, size: 20),
                        ],
                      ),
                    ),
                  ),
                  _buildTextField(
                    controller: _addressController,
                    label: 'Улица и дом'.tr,
                    icon: Icons.home,
                  ),
                  _buildTextField(
                    controller: _unitController,
                    label: 'Unit',
                    icon: Icons.meeting_room_outlined,
                  ),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: _buildTextField(
                          controller: _cityController,
                          label: 'Город'.tr,
                          icon: Icons.location_city,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildTextField(
                          controller: _postalController,
                          label: 'Индекс'.tr,
                          icon: Icons.markunread_mailbox,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],

            // Job Site
            Container(
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SwitchListTile(
                title: Text(
                  'Другой адрес работы (арендатор)'.tr,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text('Техника находится по другому адресу'.tr),
                value: _hasJobSite,
                onChanged: (val) => setState(() => _hasJobSite = val),
                activeThumbColor: AppColors.primary,
              ),
            ),

            if (_hasJobSite) ...[
              const SizedBox(height: 16),
              _buildSection(
                title: 'Контакт на месте'.tr,
                icon: Icons.contact_phone,
                color: Colors.orange,
                children: [
                  _buildTextField(
                    controller: _contactNameController,
                    label: 'Имя на месте'.tr,
                    icon: Icons.person_outline,
                  ),
                  _buildTextField(
                    controller: _contactPhoneController,
                    label: 'Телефон на месте'.tr,
                    icon: Icons.phone,
                    keyboardType: TextInputType.phone,
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),

            // Техника
            _buildSection(
              title: 'Техника'.tr,
              icon: Icons.kitchen,
              children: [
                _buildTextField(
                  controller: _applianceController,
                  label: 'Тип техники'.tr,
                  icon: Icons.category,
                  readOnly: true,
                  onTap: _pickApplianceType,
                ),
                _buildTextField(
                  controller: _brandController,
                  label: 'Бренд'.tr,
                  icon: Icons.branding_watermark,
                  readOnly: true,
                  onTap: _pickBrand,
                ),
                _buildTextField(
                  controller: _problemController,
                  label: 'Описание проблемы'.tr,
                  icon: Icons.report_problem,
                  maxLines: 3,
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Дата и время
            _buildSection(
              title: 'Дата визита'.tr,
              icon: Icons.calendar_today,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: _pickDateTime,
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade300),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.calendar_month, color: AppColors.primary),
                              const SizedBox(width: 12),
                              Text(
                                _scheduledDate != null
                                    ? DateFormat('dd.MM.yyyy').format(_scheduledDate!)
                                    : 'Выберите дату'.tr,
                                style: TextStyle(
                                  color: _scheduledDate != null
                                      ? Colors.black
                                      : Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: GestureDetector(
                        onTap: _pickDateTime,
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade300),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.access_time, color: AppColors.primary),
                              const SizedBox(width: 12),
                              Text(
                                _scheduledTime != null
                                    ? _scheduledTime!.format(context)
                                    : 'Выберите время'.tr,
                                style: TextStyle(
                                  color: _scheduledTime != null
                                      ? Colors.black
                                      : Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                if (_scheduledDate != null)
                  TextButton(
                    onPressed: () => setState(() {
                      _scheduledDate = null;
                      _scheduledTime = null;
                    }),
                    child: Text(context.tr('Без даты и времени', 'No date or time')),
                  ),
              ],
            ),

            // Подсказка по запчастям
            if (_suggestedParts.isNotEmpty || _isLoadingParts) ...[
              const SizedBox(height: 16),
              _buildSection(
                title: 'Возможные запчасти'.tr,
                icon: Icons.build,
                color: Colors.green,
                children: [
                  if (_isLoadingParts)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _suggestedParts.map((part) {
                        return Chip(
                          label: Text(part),
                          backgroundColor: Colors.green.shade50,
                          side: BorderSide(color: Colors.green.shade200),
                        );
                      }).toList(),
                    ),
                ],
              ),
            ],

            const SizedBox(height: 24),

            // Исходный текст
            ExpansionTile(
              title: Text(
                'Исходный текст'.tr,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              leading: const Icon(Icons.text_snippet),
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    widget.originalText,
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),
          ],
        ),
      ),
      bottomNavigationBar: BottomConfirmButton(
        dirty: !_isSaving,
        saving: _isSaving,
        onPressed: () { _saveJob(); },
      ),
    ),
    );
  }

  Widget _buildExistingClientCard() {
    final address = joinAddress(
      _addressController.text,
      _cityController.text,
      _postalController.text,
      _unitController.text,
    );
    final name = _nameController.text.trim().isNotEmpty
        ? _nameController.text.trim()
        : (_existingClient?.fullName ?? 'Клиент'.tr);
    final phone = _phoneController.text.trim();
    final email = _emailController.text.trim();

    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _editingExistingClient = true),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: AppColors.primary,
                child: const Icon(Icons.person, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    if (phone.isNotEmpty)
                      Text(
                        phone,
                        style: TextStyle(color: AppColors.inkMuted),
                      ),
                    if (email.isNotEmpty)
                      Text(
                        email,
                        style: TextStyle(color: AppColors.inkMuted),
                      ),
                    if (address.isNotEmpty)
                      Text(
                        address,
                        style: TextStyle(
                          color: AppColors.inkMuted,
                          fontSize: 13,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Изменить'.tr,
                onPressed: () => setState(() => _editingExistingClient = true),
                icon: Icon(Icons.edit, color: AppColors.primaryOnCard),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required IconData icon,
    required List<Widget> children,
    Color? color,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: color ?? AppColors.primary, size: 20),
            const SizedBox(width: 8),
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: color ?? AppColors.primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ...children,
      ],
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType? keyboardType,
    int maxLines = 1,
    bool readOnly = false,
    VoidCallback? onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        maxLines: maxLines,
        readOnly: readOnly,
        onTap: onTap,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, color: Colors.grey),
          suffixIcon: readOnly
              ? const Icon(Icons.arrow_drop_down, color: Colors.grey)
              : null,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          filled: true,
          fillColor: AppColors.cardMuted,
        ),
      ),
    );
  }

  Future<void> _pickApplianceType() async {
    final result = await showCatalogPicker(
      context: context,
      title: 'Тип техники'.tr,
      itemsStream: CatalogService.streamApplianceTypes(),
      onAdd: CatalogService.addApplianceType,
    );
    if (result != null) {
      setState(() => _applianceController.text = result);
    }
  }

  Future<void> _pickBrand() async {
    final result = await showCatalogPicker(
      context: context,
      title: 'Бренд'.tr,
      itemsStream: CatalogService.streamBrands(),
      onAdd: CatalogService.addBrand,
    );
    if (result != null) {
      setState(() => _brandController.text = result);
    }
  }
}
