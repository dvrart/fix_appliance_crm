import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/utils/app_time_picker.dart';
import '../../widgets/smart_address_picker.dart';
import '../../shared/widgets/catalog_picker.dart';
import '../../services/catalog_service.dart';
import '../../services/client_service.dart';
import '../../services/job_service.dart';
import '../../services/settings_service.dart';
import '../../models/client.dart';
import '../../models/job.dart';
import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../shared/widgets/keyboard_safe.dart';
import '../../shared/unsaved_navigation_gate.dart';
import '../../shared/widgets/app_bar_save.dart';
import '../../shared/widgets/email_field.dart';
import '../../shared/widgets/phone_client_matches.dart';
import '../../shared/widgets/unsaved_changes_dialog.dart';

class ApplianceFormItem {
  final TextEditingController typeController = TextEditingController();
  final TextEditingController brandController = TextEditingController();
  final TextEditingController modelController = TextEditingController();
  final TextEditingController serialController = TextEditingController();
  final TextEditingController issueController = TextEditingController();
}

class CreateJobScreen extends StatefulWidget {
  final DateTime? preselectedDate;
  final String? existingClientId;
  final String? initialName;
  final String? initialPhone;
  final String? initialAddress;

  final String? initialEmail;
  final String? initialCompany;

  const CreateJobScreen({
    super.key,
    this.preselectedDate,
    this.existingClientId,
    this.initialName,
    this.initialPhone,
    this.initialAddress,
    this.initialEmail,
    this.initialCompany,
  });

  @override
  State<CreateJobScreen> createState() => _CreateJobScreenState();
}

class _CreateJobScreenState extends State<CreateJobScreen> {
  final _formKey = GlobalKey<FormState>();

  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _companyController = TextEditingController();

  final _clientStreetCtrl = TextEditingController();
  final _clientCityCtrl = TextEditingController();
  final _clientPostalCtrl = TextEditingController();
  final _clientUnitCtrl = TextEditingController();

  bool _hasDifferentJobSite = false;
  final _siteNameController = TextEditingController();
  final _sitePhoneController = TextEditingController();
  final _siteEmailController = TextEditingController();

  final _siteStreetCtrl = TextEditingController();
  final _siteCityCtrl = TextEditingController();
  final _sitePostalCtrl = TextEditingController();
  final _siteUnitCtrl = TextEditingController();

  final List<ApplianceFormItem> _appliances = [ApplianceFormItem()];

  DateTime? _selectedDate;
  TimeOfDay? _selectedTime;
  int _workStartMinutes = SettingsService.defaultWorkStartMinutes;
  int _durationMinutes = kDefaultVisitMinutes;
  bool _calendarDefaultsLoaded = false;
  final _packingCtrl = TextEditingController();
  bool _isSaving = false;

  String? _existingClientId;
  Timer? _debounce;
  final _scrollController = ScrollController();
  bool _dirty = false;

  void _markDirty() {
    if (_dirty || !mounted) return;
    setState(() => _dirty = true);
  }

  TimeOfDay get _defaultStartTime {
    final hour = (_workStartMinutes ~/ 60).clamp(0, 23);
    return TimeOfDay(hour: hour, minute: _workStartMinutes % 60);
  }

  Future<void> _loadCalendarDefaults() async {
    final config = await SettingsService.loadConfig();
    if (!mounted) return;
    final minutes = SettingsService.readJobDurationMinutes(config);
    final workStart = SettingsService.readWorkStartMinutes(config);
    setState(() {
      _durationMinutes = minutes;
      _workStartMinutes = workStart;
      if (widget.preselectedDate == null && !_dirty) {
        _selectedTime = _defaultStartTime;
      }
      _calendarDefaultsLoaded = true;
    });
  }

  @override
  void initState() {
    super.initState();
    UnsavedNavigationGate.push(_allowLeave);
    final pre = widget.preselectedDate;
    if (pre != null) {
      _selectedDate = DateTime(pre.year, pre.month, pre.day);
      _selectedTime = TimeOfDay(hour: pre.hour, minute: pre.minute);
    } else {
      _selectedDate = DateTime.now();
      _selectedTime = _defaultStartTime;
    }
    _existingClientId = widget.existingClientId;
    unawaited(_loadCalendarDefaults());
    if (widget.initialName != null) {
      _nameController.text = widget.initialName!;
    }
    if (widget.initialPhone != null) {
      _phoneController.text = widget.initialPhone!;
    }
    if (widget.initialEmail != null) {
      _emailController.text = widget.initialEmail!;
    }
    if (widget.initialCompany != null) {
      _companyController.text = widget.initialCompany!;
    }
    final address = widget.initialAddress?.trim() ?? '';
    if (address.isNotEmpty) {
      final parts = splitAddress(address);
      final peeled = peelUnit(parts[0]);
      _clientStreetCtrl.text = peeled.street;
      _clientUnitCtrl.text = peeled.unit;
      _clientCityCtrl.text = parts[1];
      _clientPostalCtrl.text = parts[2];
    }
    for (final controller in [
      _nameController,
      _phoneController,
      _emailController,
      _companyController,
      _clientStreetCtrl,
      _clientCityCtrl,
      _clientPostalCtrl,
      _clientUnitCtrl,
      _siteNameController,
      _sitePhoneController,
      _siteEmailController,
      _siteStreetCtrl,
      _siteCityCtrl,
      _sitePostalCtrl,
      _siteUnitCtrl,
      _packingCtrl,
    ]) {
      controller.addListener(_markDirty);
    }
    for (final app in _appliances) {
      app.typeController.addListener(_markDirty);
      app.brandController.addListener(_markDirty);
      app.modelController.addListener(_markDirty);
      app.serialController.addListener(_markDirty);
      app.issueController.addListener(_markDirty);
    }
  }

  @override
  void dispose() {
    UnsavedNavigationGate.pop(_allowLeave);
    _debounce?.cancel();
    for (var app in _appliances) {
      app.typeController.dispose();
      app.brandController.dispose();
      app.modelController.dispose();
      app.serialController.dispose();
      app.issueController.dispose();
    }
    _clientStreetCtrl.dispose();
    _clientCityCtrl.dispose();
    _clientPostalCtrl.dispose();
    _clientUnitCtrl.dispose();
    _siteNameController.dispose();
    _sitePhoneController.dispose();
    _siteEmailController.dispose();
    _siteStreetCtrl.dispose();
    _siteCityCtrl.dispose();
    _sitePostalCtrl.dispose();
    _siteUnitCtrl.dispose();
    _scrollController.dispose();
    _packingCtrl.dispose();
    _emailController.dispose();
    _companyController.dispose();
    super.dispose();
  }

  void _addAppliance() {
    final item = ApplianceFormItem();
    item.typeController.addListener(_markDirty);
    item.brandController.addListener(_markDirty);
    item.modelController.addListener(_markDirty);
    item.serialController.addListener(_markDirty);
    item.issueController.addListener(_markDirty);
    setState(() => _appliances.add(item));
    _markDirty();
  }

  void _removeAppliance(int index) {
    setState(() => _appliances.removeAt(index));
    _markDirty();
  }

  Future<bool> _allowLeave() async {
    if (!_dirty || _isSaving) return true;
    if (!mounted) return true;
    final action = await showUnsavedChangesDialog(context);
    if (!mounted) return false;
    if (action == UnsavedChangesAction.cancel) return false;
    if (action == UnsavedChangesAction.save) {
      return await _saveJob();
    }
    return true;
  }

  Future<void> _onBack() async {
    if (!_dirty) {
      if (mounted) Navigator.maybePop(context);
      return;
    }
    final action = await showUnsavedChangesDialog(context);
    if (!mounted) return;
    if (action == UnsavedChangesAction.cancel) return;
    if (action == UnsavedChangesAction.save) {
      await _saveJob();
      return;
    }
    Navigator.pop(context);
  }

  void _onPhoneChanged(String value) {
    if (_existingClientId != null && widget.existingClientId == null) {
      setState(() => _existingClientId = null);
    }
  }

  Future<void> _pickDateTime() async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? DateTime.now(),
      firstDate: DateTime(2023),
      lastDate: DateTime(2030),
    );
    if (pickedDate == null || !mounted) return;

    final pickedTime = await showAppTimePicker(
      context: context,
      initialTime: _selectedTime ?? _defaultStartTime,
      helpText: 'Выберите время'.tr,
    );

    if (pickedTime != null) {
      setState(() {
        _selectedDate = pickedDate;
        _selectedTime = pickedTime;
      });
    } else {
      setState(() {
        _selectedDate = pickedDate;
        _selectedTime ??= _defaultStartTime;
      });
    }
    _markDirty();
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<bool> _saveJob() async {
    if (_nameController.text.trim().isEmpty || _phoneController.text.trim().isEmpty) {
      _showError('Добавьте владельца'.tr);
      return false;
    }
    if (!_formKey.currentState!.validate()) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
      _showError('Заполните обязательные поля'.tr);
      return false;
    }
    _selectedDate ??= DateTime.now();
    _selectedTime ??= _defaultStartTime;

    if (_clientStreetCtrl.text.trim().isEmpty && _clientCityCtrl.text.trim().isEmpty) {
      _showError('Укажите адрес клиента'.tr);
      return false;
    }

    setState(() => _isSaving = true);

    try {
      String fullClientAddress = joinAddress(
        _clientStreetCtrl.text,
        _clientCityCtrl.text,
        _clientPostalCtrl.text,
        _clientUnitCtrl.text,
      );

      final clientId = await ClientService.createOrUpdate(
        existingId: _existingClientId,
        fullName: _nameController.text.trim(),
        phone: _phoneController.text.trim(),
        address: fullClientAddress,
        email: _emailController.text.trim().isEmpty ? null : _emailController.text.trim(),
        companyName: _companyController.text.trim().isEmpty ? null : _companyController.text.trim(),
      );
      await ClientService.updateAddress(
        clientId,
        street: _clientStreetCtrl.text.trim(),
        city: _clientCityCtrl.text.trim(),
        postal: _clientPostalCtrl.text.trim(),
        unit: _clientUnitCtrl.text.trim(),
      );

      final jobDateTime = DateTime(
        _selectedDate!.year,
        _selectedDate!.month,
        _selectedDate!.day,
        _selectedTime!.hour,
        _selectedTime!.minute,
      );

      final appliances = _appliances
          .map(
            (app) => JobAppliance(
              type: app.typeController.text.trim(),
              brand: app.brandController.text.trim(),
              model: app.modelController.text.trim(),
              serialNumber: app.serialController.text.trim(),
              issue: app.issueController.text.trim(),
            ),
          )
          .where((app) => app.type.isNotEmpty || app.brand.isNotEmpty || app.model.isNotEmpty)
          .toList();

      final targetCity = _hasDifferentJobSite && _siteCityCtrl.text.trim().isNotEmpty
          ? _siteCityCtrl.text.trim()
          : _clientCityCtrl.text.trim();
      final fullJobSiteAddress = joinAddress(
        _siteStreetCtrl.text,
        _siteCityCtrl.text,
        _sitePostalCtrl.text,
        _siteUnitCtrl.text,
      );
      // No separate job-site address → use the client address for the visit.
      final useJobSite =
          _hasDifferentJobSite && fullJobSiteAddress.trim().isNotEmpty;
      final resolvedClientAddress = fullClientAddress.trim().isNotEmpty
          ? fullClientAddress
          : (useJobSite ? fullJobSiteAddress : '');

      final job = Job(
        id: '',
        clientId: clientId,
        clientName: _nameController.text.trim(),
        clientPhone: _phoneController.text.trim(),
        clientAddress: resolvedClientAddress,
        hasJobSite: useJobSite,
        jobSiteName: useJobSite ? _siteNameController.text.trim() : null,
        jobSitePhone: useJobSite ? _sitePhoneController.text.trim() : null,
        jobSiteEmail: useJobSite && _siteEmailController.text.trim().isNotEmpty
            ? _siteEmailController.text.trim()
            : null,
        jobSiteAddress: useJobSite ? fullJobSiteAddress : null,
        appliances: appliances.isNotEmpty
            ? appliances
            : [
                JobAppliance(
                  type: _appliances[0].typeController.text.trim(),
                  brand: _appliances[0].brandController.text.trim(),
                  model: _appliances[0].modelController.text.trim(),
                  serialNumber: _appliances[0].serialController.text.trim(),
                  issue: _appliances[0].issueController.text.trim(),
                ),
              ],
        description: _appliances[0].issueController.text.trim(),
        status: JobStatuses.call,
        durationMinutes: _durationMinutes,
        packingNotes: _packingCtrl.text.trim(),
        priority: JobPriorities.low,
        scheduledAt: jobDateTime,
        createdAt: DateTime.now(),
        city: targetCity,
      );

      await JobService.create(job);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Заявка успешно создана!'.tr),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
          ),
        );
        _dirty = false;
        Navigator.pop(context, true);
        return true;
      }
      return false;
    } catch (e) {
      _showError('${'Не удалось создать заявку'.tr}: $e');
      return false;
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  bool get _hasOwner =>
      _nameController.text.trim().isNotEmpty ||
      _phoneController.text.trim().isNotEmpty;

  Widget _buildOwnerBlock() {
    if (!_hasOwner) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: SizedBox(
          width: double.infinity,
          height: 52,
          child: OutlinedButton.icon(
            onPressed: _editOwner,
            icon: const Icon(Icons.person_add_alt_1),
            label: Text(
              'Добавить владельца'.tr,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primary,
              side: BorderSide(color: AppColors.primary, width: 1.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      );
    }

    final address = [
      _clientStreetCtrl.text.trim(),
      _clientCityCtrl.text.trim(),
      _clientPostalCtrl.text.trim(),
    ].where((p) => p.isNotEmpty).join(', ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _editOwner,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.primary.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: AppColors.primary,
                  child: Icon(Icons.person, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _nameController.text.trim().isEmpty
                            ? 'Владелец'.tr
                            : _nameController.text.trim(),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      Text(_phoneController.text.trim(), style: const TextStyle(color: Colors.black54)),
                      if (_emailController.text.trim().isNotEmpty)
                        Text(_emailController.text.trim(), style: const TextStyle(color: Colors.black54)),
                      if (_companyController.text.trim().isNotEmpty)
                        Text(_companyController.text.trim(), style: const TextStyle(color: Colors.black54)),
                      if (address.isNotEmpty)
                        Text(address, style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Изменить'.tr,
                  onPressed: _editOwner,
                  icon: Icon(Icons.edit, color: AppColors.primary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _editOwner() async {
    List<Client> suggestions = [];
    var searching = false;

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
              Future<void> searchPhone(String value) async {
                _onPhoneChanged(value);
                _debounce?.cancel();
                final digits = ClientService.normalizePhone(value);
                if (digits.length < 7) {
                  setSheet(() {
                    suggestions = [];
                    searching = false;
                  });
                  return;
                }
                setSheet(() => searching = true);
                _debounce = Timer(const Duration(milliseconds: 350), () async {
                  try {
                    final found = await ClientService.searchByPhone(value);
                    if (!sheetContext.mounted) return;
                    setSheet(() {
                      suggestions = found;
                      searching = false;
                    });
                  } catch (_) {
                    if (sheetContext.mounted) {
                      setSheet(() => searching = false);
                    }
                  }
                });
              }

              void applyClient(Client client) {
                _existingClientId = client.id;
                _phoneController.text = client.phone;
                _nameController.text = client.fullName;
                _emailController.text = client.email ?? '';
                _companyController.text = client.companyName ?? '';
                final addrParts = client.address.split(',');
                _clientStreetCtrl.text =
                    addrParts.isNotEmpty ? addrParts[0].trim() : '';
                _clientCityCtrl.text =
                    addrParts.length > 1 ? addrParts[1].trim() : '';
                _clientPostalCtrl.text = addrParts.length > 2
                    ? addrParts.sublist(2).join(',').trim()
                    : '';
                suggestions = [];
                setSheet(() {});
                FocusScope.of(sheetContext).unfocus();
              }

              return Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Владелец'.tr,
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
                  TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    onChanged: searchPhone,
                    decoration: InputDecoration(
                      labelText: 'Номер телефона'.tr,
                      prefixIcon: const Icon(Icons.phone),
                      suffixIcon: searching
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            )
                          : null,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  if (suggestions.isNotEmpty)
                    Expanded(
                      child: ListView(
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        children: [
                          PhoneClientMatches(
                            clients: suggestions,
                            onSelect: applyClient,
                          ),
                        ],
                      ),
                    )
                  else
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                          const SizedBox(height: 12),
                          TextField(
                            controller: _nameController,
                            textCapitalization: TextCapitalization.words,
                            decoration: InputDecoration(
                              labelText: 'Имя'.tr,
                              helperText: 'Имя на английском'.tr,
                              prefixIcon: const Icon(Icons.person),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          GestureDetector(
                            onTap: () {
                              showSmartAddressPicker(
                                context: context,
                                initialStreet: _clientStreetCtrl.text,
                                initialCity: _clientCityCtrl.text,
                                initialPostal: _clientPostalCtrl.text,
                                initialUnit: _clientUnitCtrl.text,
                                onSaved: (street, city, postal, unit) {
                                  _clientStreetCtrl.text = street;
                                  _clientCityCtrl.text = city;
                                  _clientPostalCtrl.text = postal;
                                  _clientUnitCtrl.text = unit;
                                  setSheet(() {});
                                },
                              );
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade50,
                                border: Border.all(color: Colors.grey.shade300),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.location_on, color: Colors.grey),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      _clientCityCtrl.text.isEmpty
                                          ? 'Нажмите, чтобы ввести адрес...'.tr
                                          : '${_clientStreetCtrl.text}, ${_clientCityCtrl.text}',
                                    ),
                                  ),
                                  Icon(Icons.search, color: AppColors.primary),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          EmailAutocompleteField(
                            controller: _emailController,
                            decoration: InputDecoration(
                              labelText: 'Электронный адрес'.tr,
                              prefixIcon: const Icon(Icons.email_outlined),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _companyController,
                            textCapitalization: TextCapitalization.words,
                            decoration: InputDecoration(
                              labelText: 'Название компании'.tr,
                              prefixIcon: const Icon(Icons.business),
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
                      onPressed: () async {
                        if (_phoneController.text.trim().isEmpty ||
                            _nameController.text.trim().isEmpty) {
                          ScaffoldMessenger.of(sheetContext).showSnackBar(
                            SnackBar(content: Text('Укажите имя и телефон'.tr)),
                          );
                          return;
                        }
                        final found = await ClientService.findExisting(
                          phone: _phoneController.text,
                          email: _emailController.text,
                        );
                        if (found != null) {
                          _existingClientId = found.id;
                        } else if (widget.existingClientId == null) {
                          _existingClientId = null;
                        }
                        if (sheetContext.mounted) Navigator.pop(sheetContext);
                        if (mounted) setState(() {});
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
    if (mounted) setState(() {});
  }

  bool get _hasJobSiteCard =>
      _hasDifferentJobSite &&
      (_siteNameController.text.trim().isNotEmpty ||
          _sitePhoneController.text.trim().isNotEmpty ||
          _siteStreetCtrl.text.trim().isNotEmpty ||
          _siteCityCtrl.text.trim().isNotEmpty ||
          _siteEmailController.text.trim().isNotEmpty);

  Widget _buildJobSiteBlock() {
    if (!_hasJobSiteCard) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: SizedBox(
          width: double.infinity,
          height: 52,
          child: OutlinedButton.icon(
            onPressed: _editJobSite,
            icon: const Icon(Icons.add_home_work_outlined),
            label: Text(
              'Добавить другое место работы'.tr,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primary,
              side: BorderSide(color: AppColors.primary, width: 1.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      );
    }

    final address = [
      _siteStreetCtrl.text.trim(),
      _siteCityCtrl.text.trim(),
      _sitePostalCtrl.text.trim(),
    ].where((p) => p.isNotEmpty).join(', ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _editJobSite,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.45)),
            ),
            child: Row(
              children: [
                const CircleAvatar(
                  backgroundColor: Colors.orange,
                  child: Icon(Icons.home_work_outlined, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _siteNameController.text.trim().isEmpty
                            ? 'Другое место работы'.tr
                            : _siteNameController.text.trim(),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      if (_sitePhoneController.text.trim().isNotEmpty)
                        Text(
                          _sitePhoneController.text.trim(),
                          style: const TextStyle(color: Colors.black54),
                        ),
                      if (_siteEmailController.text.trim().isNotEmpty)
                        Text(
                          _siteEmailController.text.trim(),
                          style: const TextStyle(color: Colors.black54),
                        ),
                      if (address.isNotEmpty)
                        Text(address, style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Изменить'.tr,
                  onPressed: _editJobSite,
                  icon: Icon(Icons.edit, color: AppColors.primary),
                ),
                IconButton(
                  tooltip: 'Удалить'.tr,
                  onPressed: () {
                    setState(() {
                      _hasDifferentJobSite = false;
                      _siteNameController.clear();
                      _sitePhoneController.clear();
                      _siteEmailController.clear();
                      _siteStreetCtrl.clear();
                      _siteCityCtrl.clear();
                      _sitePostalCtrl.clear();
                    });
                  },
                  icon: const Icon(Icons.close, color: Colors.redAccent),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _prefillJobSiteFromClient() {
    if (_siteNameController.text.trim().isEmpty) {
      _siteNameController.text = _nameController.text.trim();
    }
    if (_sitePhoneController.text.trim().isEmpty) {
      _sitePhoneController.text = _phoneController.text.trim();
    }
    if (_siteEmailController.text.trim().isEmpty) {
      _siteEmailController.text = _emailController.text.trim();
    }
    if (_siteStreetCtrl.text.trim().isEmpty &&
        _siteCityCtrl.text.trim().isEmpty) {
      _siteStreetCtrl.text = _clientStreetCtrl.text.trim();
      _siteCityCtrl.text = _clientCityCtrl.text.trim();
      _sitePostalCtrl.text = _clientPostalCtrl.text.trim();
      _siteUnitCtrl.text = _clientUnitCtrl.text.trim();
    }
  }

  Future<void> _editJobSite() async {
    _prefillJobSiteFromClient();
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
                          'Другое место работы'.tr,
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
                            controller: _sitePhoneController,
                            keyboardType: TextInputType.phone,
                            decoration: InputDecoration(
                              labelText: 'Телефон на месте'.tr,
                              prefixIcon: const Icon(Icons.phone_android),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _siteNameController,
                            textCapitalization: TextCapitalization.words,
                            decoration: InputDecoration(
                              labelText: 'Имя на месте (Арендатор)'.tr,
                              prefixIcon: const Icon(Icons.person_outline),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          GestureDetector(
                            onTap: () {
                              showSmartAddressPicker(
                                context: context,
                                initialStreet: _siteStreetCtrl.text,
                                initialCity: _siteCityCtrl.text,
                                initialPostal: _sitePostalCtrl.text,
                                initialUnit: _siteUnitCtrl.text,
                                onSaved: (street, city, postal, unit) {
                                  _siteStreetCtrl.text = street;
                                  _siteCityCtrl.text = city;
                                  _sitePostalCtrl.text = postal;
                                  _siteUnitCtrl.text = unit;
                                  setSheet(() {});
                                },
                              );
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade50,
                                border: Border.all(color: Colors.grey.shade300),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.location_on, color: Colors.grey),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      _siteCityCtrl.text.isEmpty
                                          ? 'Адрес работы (Куда ехать)...'.tr
                                          : '${_siteStreetCtrl.text}, ${_siteCityCtrl.text}',
                                    ),
                                  ),
                                  Icon(Icons.search, color: AppColors.primary),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          EmailAutocompleteField(
                            controller: _siteEmailController,
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
                        if (_siteNameController.text.trim().isEmpty ||
                            _sitePhoneController.text.trim().isEmpty) {
                          ScaffoldMessenger.of(sheetContext).showSnackBar(
                            SnackBar(content: Text('Укажите имя и телефон'.tr)),
                          );
                          return;
                        }
                        _hasDifferentJobSite = true;
                        Navigator.pop(sheetContext);
                        setState(() {});
                        _markDirty();
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
    if (mounted) setState(() {});
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    int maxLines = 1,
    TextInputType keyboardType = TextInputType.text,
    bool isRequired = false,
    bool readOnly = false,
    VoidCallback? onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        maxLines: maxLines,
        keyboardType: keyboardType,
        readOnly: readOnly,
        onTap: onTap,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, color: Colors.grey, size: 20),
          suffixIcon: readOnly
              ? const Icon(Icons.arrow_drop_down, color: Colors.grey)
              : null,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFFCC520), width: 2),
          ),
          filled: true,
          fillColor: Colors.grey.shade50,
        ),
        validator: isRequired
            ? (v) => v == null || v.isEmpty ? 'Обязательное поле'.tr : null
            : null,
      ),
    );
  }

  Future<void> _pickApplianceType(ApplianceFormItem item) async {
    final result = await showCatalogPicker(
      context: context,
      title: 'Тип техники'.tr,
      itemsStream: CatalogService.streamApplianceTypes(),
      onAdd: CatalogService.addApplianceType,
    );
    if (result != null) {
      setState(() => item.typeController.text = result);
    }
  }

  Future<void> _pickBrand(ApplianceFormItem item) async {
    final result = await showCatalogPicker(
      context: context,
      title: 'Бренд'.tr,
      itemsStream: CatalogService.streamBrands(),
      onAdd: CatalogService.addBrand,
    );
    if (result != null) {
      setState(() => item.brandController.text = result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
      appBar: AppBar(
        title: Text(
          'Новая заявка'.tr,
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFF14557F),
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'ДАННЫЕ ВЛАДЕЛЬЦА (BILL TO)'.tr,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 12),
            _buildOwnerBlock(),
            _buildJobSiteBlock(),
            const Divider(height: 32),

            Text(
              'ТЕХНИКА И ПРОБЛЕМА'.tr,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 12),
            ..._appliances.asMap().entries.map((entry) {
              int idx = entry.key;
              ApplianceFormItem item = entry.value;
              return Card(
                margin: const EdgeInsets.only(bottom: 16),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: Colors.grey.shade300),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${'Аппарат'.tr} ${idx + 1}',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF14557F),
                            ),
                          ),
                          if (_appliances.length > 1)
                            IconButton(
                              icon: const Icon(
                                Icons.delete_outline,
                                color: Colors.red,
                              ),
                              onPressed: () => _removeAppliance(idx),
                              constraints: const BoxConstraints(),
                              padding: EdgeInsets.zero,
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _buildTextField(
                              controller: item.typeController,
                              label: 'Тип (Холодильник и т.д.)'.tr,
                              icon: Icons.kitchen,
                              isRequired: true,
                              readOnly: true,
                              onTap: () => _pickApplianceType(item),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildTextField(
                              controller: item.brandController,
                              label: 'Бренд'.tr,
                              icon: Icons.branding_watermark,
                              readOnly: true,
                              onTap: () => _pickBrand(item),
                            ),
                          ),
                        ],
                      ),
                      _buildTextField(
                        controller: item.modelController,
                        label: 'Модель'.tr,
                        icon: Icons.qr_code,
                      ),
                      _buildTextField(
                        controller: item.serialController,
                        label: 'Серийный номер'.tr,
                        icon: Icons.pin,
                      ),
                      _buildTextField(
                        controller: item.issueController,
                        label: 'Описание'.tr,
                        icon: Icons.build,
                        maxLines: 2,
                      ),
                    ],
                  ),
                ),
              );
            }),

            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _addAppliance,
                icon: const Icon(Icons.add),
                label: Text('Добавить еще технику'.tr),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF14557F),
                  side: const BorderSide(color: Color(0xFF14557F)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const Divider(height: 32),

            Text(
              'ДАТА И ВРЕМЯ'.tr,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _pickDateTime,
                icon: const Icon(
                  Icons.calendar_month,
                  color: Color(0xFF14557F),
                  size: 28,
                ),
                label: Text(
                  _selectedDate == null || _selectedTime == null
                      ? 'Нажмите, чтобы выбрать'.tr
                      : '${DateFormat('dd MMMM yyyy', AppLocale.instance.dateLocale).format(_selectedDate!)}  ${'в'.tr}  ${_selectedTime!.format(context)}',
                  style: const TextStyle(color: Colors.black87, fontSize: 16),
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  backgroundColor: Colors.grey.shade50,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  side: BorderSide(color: Colors.grey.shade300, width: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              key: ValueKey('visit-duration-$_calendarDefaultsLoaded'),
              initialValue: _durationMinutes,
              decoration: InputDecoration(
                labelText: 'Длительность визита'.tr,
                helperText: 'По умолчанию из настроек календаря'.tr,
                prefixIcon: const Icon(Icons.timer_outlined, color: Colors.grey),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: Colors.grey.shade50,
              ),
              items: [
                DropdownMenuItem(value: 30, child: Text('30 минут'.tr)),
                DropdownMenuItem(value: 45, child: Text('45 минут'.tr)),
                DropdownMenuItem(value: 60, child: Text('1 час'.tr)),
                DropdownMenuItem(value: 90, child: Text('1.5 часа'.tr)),
                DropdownMenuItem(value: 120, child: Text('2 часа'.tr)),
                DropdownMenuItem(value: 180, child: Text('3 часа'.tr)),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _durationMinutes = value);
                  _markDirty();
                }
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _packingCtrl,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: 'Что взять с собой'.tr,
                hintText: 'Фильтр, плата, ключи…'.tr,
                prefixIcon: const Icon(Icons.inventory_2_outlined, color: Colors.grey),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: Colors.grey.shade50,
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
      bottomNavigationBar: BottomConfirmButton(
        dirty: _dirty,
        saving: _isSaving,
        onPressed: _saveJob,
      ),
    ),
    );
  }
}
