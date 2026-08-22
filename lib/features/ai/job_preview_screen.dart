import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/constants.dart';
import '../../core/utils/app_time_picker.dart';
import '../../services/ai_service.dart';
import '../../services/client_service.dart';
import '../../services/job_service.dart';
import '../../services/sms_service.dart';
import '../../models/client.dart';
import '../../models/job.dart';
import '../../widgets/smart_address_picker.dart';
import '../../services/catalog_service.dart';
import '../../shared/widgets/catalog_picker.dart';
import '../../core/l10n/app_locale.dart';
import '../../shared/widgets/app_bar_save.dart';

/// Экран предпросмотра извлечённых данных
class JobPreviewScreen extends StatefulWidget {
  final ExtractedJobData extractedData;
  final String originalText;
  final String? fallbackPhone;
  final String? fallbackEmail;
  final String? existingClientId;
  final String? sourceMessageId;
  final String sourceEmailFrom;
  final String sourceEmailSubject;

  const JobPreviewScreen({
    super.key,
    required this.extractedData,
    required this.originalText,
    this.fallbackPhone,
    this.fallbackEmail,
    this.existingClientId,
    this.sourceMessageId,
    this.sourceEmailFrom = '',
    this.sourceEmailSubject = '',
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

  List<String> _suggestedParts = [];
  bool _isLoadingParts = false;

  @override
  void initState() {
    super.initState();
    final data = widget.extractedData;

    _nameController = TextEditingController(text: data.clientName ?? '');
    _phoneController = TextEditingController(
      text: data.clientPhone ?? widget.fallbackPhone ?? '',
    );
    _emailController = TextEditingController(
      text: data.clientEmail ?? widget.fallbackEmail ?? '',
    );
    _addressController = TextEditingController(text: data.address ?? '');
    _unitController = TextEditingController();
    _cityController = TextEditingController(text: data.city ?? '');
    _postalController = TextEditingController(text: data.postalCode ?? '');
    _applianceController = TextEditingController(text: data.applianceType ?? '');
    _brandController = TextEditingController(text: data.brand ?? '');
    _problemController = TextEditingController(text: data.problemDescription ?? '');
    _contactNameController = TextEditingController(text: data.contactOnSiteName ?? '');
    _contactPhoneController = TextEditingController(text: data.contactOnSitePhone ?? '');
    _hasJobSite = data.hasJobSite;

    _scheduledDate = _parseDate(data.scheduledDate) ?? DateTime.now();

    if (data.scheduledTime != null) {
      _scheduledTime = _parseTime(data.scheduledTime);
    }
    _scheduledTime ??= const TimeOfDay(hour: 9, minute: 0);

    _loadPartsSuggestions();
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

  Future<void> _pickDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _scheduledDate ?? DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date != null) {
      setState(() => _scheduledDate = date);
    }
  }

  Future<void> _pickTime() async {
    final time = await showAppTimePicker(
      context: context,
      initialTime: _scheduledTime ?? TimeOfDay.now(),
      helpText: 'Выберите время'.tr,
    );
    if (time != null) {
      setState(() => _scheduledTime = time);
    }
  }

  bool get _isEmailOffer => (widget.sourceMessageId ?? '').trim().isNotEmpty;

  Future<void> _saveJob() async {
    final email = _emailController.text.trim();
    final phone = _phoneController.text.trim();
    var name = _nameController.text.trim();
    if (name.isEmpty && email.contains('@')) {
      name = email.split('@').first;
      _nameController.text = name;
    }
    if (name.isEmpty) {
      _showError('Укажите имя клиента'.tr);
      return;
    }
    if (phone.isEmpty && !email.contains('@')) {
      _showError(
        _isEmailOffer
            ? 'Укажите телефон или email'.tr
            : 'Укажите телефон клиента'.tr,
      );
      return;
    }
    if (_applianceController.text.trim().isEmpty) {
      _showError('Укажите тип техники'.tr);
      return;
    }
    if (_scheduledDate == null || _scheduledTime == null) {
      _showError('Укажите дату и время визита'.tr);
      return;
    }

    setState(() => _isSaving = true);

    try {
      final fullAddress = joinAddress(
        _addressController.text,
        _cityController.text,
        _postalController.text,
        _unitController.text,
      );

      Client? existing;
      final existingId = (widget.existingClientId ?? '').trim();
      if (existingId.isNotEmpty) {
        existing = await ClientService.getById(existingId);
      }
      existing ??= email.contains('@') ? await ClientService.findByEmail(email) : null;
      if (existing == null && phone.isNotEmpty) {
        existing = await ClientService.findByPhone(phone);
      }

      final clientId = await ClientService.createOrUpdate(
        existingId: existing?.id,
        fullName: _nameController.text.trim(),
        phone: phone,
        address: fullAddress,
        email: email.contains('@') ? email : existing?.email,
        source: _isEmailOffer ? 'email' : null,
      );
      await ClientService.updateAddress(
        clientId,
        street: _addressController.text.trim(),
        city: _cityController.text.trim(),
        postal: _postalController.text.trim(),
        unit: _unitController.text.trim(),
      );

      // Создаём дату-время визита
      final scheduledAt = DateTime(
        _scheduledDate!.year,
        _scheduledDate!.month,
        _scheduledDate!.day,
        _scheduledTime!.hour,
        _scheduledTime!.minute,
      );

      // Создаём заявку
      final job = Job(
        id: '',
        clientId: clientId,
        clientName: _nameController.text.trim(),
        clientPhone: phone,
        clientAddress: fullAddress,
        hasJobSite: _hasJobSite,
        jobSiteName: _hasJobSite ? _contactNameController.text.trim() : null,
        jobSitePhone: _hasJobSite ? _contactPhoneController.text.trim() : null,
        jobSiteAddress: _hasJobSite ? fullAddress : null,
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
        source: _isEmailOffer ? 'email' : '',
        sourceEmailId: widget.sourceMessageId,
        sourceEmailFrom: widget.sourceEmailFrom,
        sourceEmailSubject: widget.sourceEmailSubject,
        sourceEmailPreview: widget.originalText,
        durationMinutes: _isEmailOffer ? 120 : 60,
      );

      final jobId = await JobService.create(job);
      if (_isEmailOffer) {
        await SmsService.acceptEmailOffer(
          widget.sourceMessageId!,
          jobId: jobId,
          clientId: clientId,
        );
      }

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Заявка создана!'.tr),
          backgroundColor: Colors.green,
        ),
      );

      Navigator.pop(context, true);
    } catch (e) {
      _showError('${'Ошибка сохранения'.tr}: $e');
      setState(() => _isSaving = false);
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
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isEmailOffer ? 'Письмо о ремонте'.tr : 'Проверьте данные'.tr,
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        actions: [
          if (_isEmailOffer)
            TextButton(
              onPressed: _isSaving ? null : _dismissOffer,
              child: Text(
                'Пропустить'.tr,
                style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700),
              ),
            ),
          AppBarSaveButton(
            dirty: true,
            saving: _isSaving,
            label: 'Создать'.tr,
            onPressed: _saveJob,
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
                      color: Colors.grey.shade50,
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.search, color: AppColors.primary, size: 24),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _addressController.text.isEmpty && _cityController.text.isEmpty
                                ? 'Нажмите для поиска адреса...'.tr
                                : [
                                    _addressController.text,
                                    _cityController.text,
                                    _postalController.text,
                                  ].where((s) => s.isNotEmpty).join(', '),
                            style: TextStyle(
                              color: _addressController.text.isEmpty &&
                                      _cityController.text.isEmpty
                                  ? Colors.grey
                                  : Colors.black87,
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

            // Job Site
            Container(
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SwitchListTile(
                title: Text(
                  'Другой адрес работы (арендатор)'.tr,
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text('Техника находится по другому адресу'.tr),
                value: _hasJobSite,
                onChanged: (val) => setState(() => _hasJobSite = val),
                activeColor: AppColors.primary,
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
                        onTap: _pickDate,
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
                        onTap: _pickTime,
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
                style: TextStyle(fontWeight: FontWeight.bold),
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
          fillColor: Colors.grey.shade50,
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
