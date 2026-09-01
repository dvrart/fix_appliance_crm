import 'package:flutter/material.dart';

import '../../core/app_commands.dart';
import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../services/catalog_service.dart';
import '../../services/client_service.dart';
import '../../shared/widgets/confirm_action_sheet.dart';
import '../../shared/widgets/dirty_leave_scope.dart';
import '../../shared/widgets/email_field.dart';
import '../../shared/widgets/keyboard_safe.dart';
import '../../widgets/smart_address_picker.dart';

class EditClientSheet extends StatefulWidget {
  final String clientId;
  final Map<String, dynamic> currentData;
  final String Function(Map<String, dynamic>) extractName;

  const EditClientSheet({
    super.key,
    required this.clientId,
    required this.currentData,
    required this.extractName,
  });

  @override
  State<EditClientSheet> createState() => _EditClientSheetState();
}

class _EditClientSheetState extends State<EditClientSheet> {
  late final TextEditingController nameController;
  late final TextEditingController phoneController;
  late final TextEditingController emailController;
  late final TextEditingController companyController;
  late final TextEditingController notesController;
  late final TextEditingController streetController;
  late final TextEditingController cityController;
  late final TextEditingController postalController;
  late String source;
  late String unit;
  late final String _initialName;
  late final String _initialPhone;
  late final String _initialEmail;
  late final String _initialCompany;
  late final String _initialNotes;
  late final String _initialSource;
  late final String _initialStreet;
  late final String _initialCity;
  late final String _initialPostal;
  late final String _initialUnit;

  @override
  void initState() {
    super.initState();
    final currentData = widget.currentData;
    _initialName = widget.extractName(currentData);
    _initialPhone = (currentData['phone'] ?? '').toString();
    _initialEmail = (currentData['email'] ?? '').toString();
    _initialCompany =
        (currentData['companyName'] ?? currentData['company'] ?? '').toString();
    _initialNotes =
        (currentData['notes'] ?? currentData['description'] ?? '').toString();
    _initialSource = (currentData['source'] ?? '').toString();
    final addressParts = splitAddress((currentData['address'] ?? '').toString());
    final peeled = peelUnit(addressParts[0]);
    _initialStreet = peeled.street;
    _initialCity = addressParts[1];
    _initialPostal = addressParts[2];
    final storedUnit = unitFromLocations(currentData);
    _initialUnit = storedUnit.isNotEmpty ? storedUnit : peeled.unit;
    nameController = TextEditingController(text: _initialName);
    phoneController = TextEditingController(text: _initialPhone);
    emailController = TextEditingController(text: _initialEmail);
    companyController = TextEditingController(text: _initialCompany);
    notesController = TextEditingController(text: _initialNotes);
    streetController = TextEditingController(text: _initialStreet);
    cityController = TextEditingController(text: _initialCity);
    postalController = TextEditingController(text: _initialPostal);
    source = _initialSource;
    unit = _initialUnit;
    for (final controller in [
      nameController,
      phoneController,
      emailController,
      companyController,
      notesController,
      streetController,
      cityController,
      postalController,
    ]) {
      controller.addListener(_onEdit);
    }
  }

  void _onEdit() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final controller in [
      nameController,
      phoneController,
      emailController,
      companyController,
      notesController,
      streetController,
      cityController,
      postalController,
    ]) {
      controller.removeListener(_onEdit);
      controller.dispose();
    }
    super.dispose();
  }

  bool get _dirty {
    return nameController.text.trim() != _initialName.trim() ||
        phoneController.text.trim() != _initialPhone.trim() ||
        emailController.text.trim() != _initialEmail.trim() ||
        companyController.text.trim() != _initialCompany.trim() ||
        notesController.text.trim() != _initialNotes.trim() ||
        source.trim() != _initialSource.trim() ||
        streetController.text.trim() != _initialStreet.trim() ||
        cityController.text.trim() != _initialCity.trim() ||
        postalController.text.trim() != _initialPostal.trim() ||
        unit.trim() != _initialUnit.trim();
  }

  Future<bool> _persist() async {
    await ClientService.update(widget.clientId, {
      'fullName': nameController.text.trim(),
      'phone': phoneController.text.trim(),
      'email': emailController.text.trim(),
      'companyName': companyController.text.trim(),
      'notes': notesController.text.trim(),
      'source': source,
      ...ClientService.addressFields(
        street: streetController.text.trim(),
        city: cityController.text.trim(),
        postal: postalController.text.trim(),
        unit: unit,
        currentData: widget.currentData,
      ),
    });
    AppCommands.reactHappy();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return DirtyLeaveScope(
      dirty: _dirty,
      onSave: _persist,
      child: Builder(
        builder: (context) {
          return KeyboardAvoidingSheet(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Редактировать клиента'.tr,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primary,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () =>
                          DirtyLeaveScope.of(context)?.requestLeave(),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        TextField(
                          controller: nameController,
                          textCapitalization: TextCapitalization.words,
                          decoration: InputDecoration(
                            labelText: 'Имя'.tr,
                            helperText: 'Имя на английском'.tr,
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.person),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: phoneController,
                          keyboardType: TextInputType.phone,
                          decoration: InputDecoration(
                            labelText: 'Телефон'.tr,
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.phone),
                          ),
                        ),
                        const SizedBox(height: 16),
                        GestureDetector(
                          onTap: () {
                            showSmartAddressPicker(
                              context: context,
                              initialStreet: streetController.text,
                              initialCity: cityController.text,
                              initialPostal: postalController.text,
                              initialUnit: unit,
                              onSaved: (street, city, postal, pickedUnit) {
                                setState(() {
                                  streetController.text = street;
                                  cityController.text = city;
                                  postalController.text = postal;
                                  unit = pickedUnit;
                                });
                              },
                            );
                          },
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 12),
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
                                  size: 20,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    cityController.text.isEmpty
                                        ? 'Нажмите, чтобы ввести адрес...'.tr
                                        : '${streetController.text}, ${cityController.text}',
                                    style: TextStyle(
                                      color: cityController.text.isEmpty
                                          ? Colors.black54
                                          : Colors.black87,
                                      fontSize: 16,
                                    ),
                                  ),
                                ),
                                Icon(Icons.search, color: AppColors.primary),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        EmailAutocompleteField(
                          controller: emailController,
                          decoration: InputDecoration(
                            labelText: 'Электронный адрес'.tr,
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.email_outlined),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: companyController,
                          decoration: InputDecoration(
                            labelText: 'Название компании'.tr,
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.business),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: notesController,
                          maxLines: 3,
                          decoration: InputDecoration(
                            labelText: 'Описание'.tr,
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.notes),
                          ),
                        ),
                        const SizedBox(height: 12),
                        StreamBuilder<List<String>>(
                          stream: CatalogService.streamLeadSources(),
                          builder: (context, snap) {
                            final sources = snap.data ??
                                CatalogService.defaultLeadSources;
                            return DropdownButtonFormField<String>(
                              value: sources.contains(source) ? source : null,
                              decoration: InputDecoration(
                                labelText: 'Откуда узнали'.tr,
                                border: const OutlineInputBorder(),
                                prefixIcon: const Icon(Icons.campaign_outlined),
                              ),
                              items: [
                                DropdownMenuItem(
                                  value: null,
                                  child: Text('Не указано'.tr),
                                ),
                                for (final item in sources)
                                  DropdownMenuItem(
                                    value: item,
                                    child: Text(trAny(item)),
                                  ),
                              ],
                              onChanged: (value) {
                                setState(() => source = value ?? '');
                              },
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      RoundActionButton(
                        color: const Color(0xFF22C55E),
                        icon: Icons.check_rounded,
                        tooltip: 'Сохранить'.tr,
                        size: 72,
                        onTap: () async {
                          if (await _persist() && context.mounted) {
                            Navigator.pop(context);
                          }
                        },
                      ),
                      RoundActionButton(
                        color: const Color(0xFFE53935),
                        icon: Icons.close_rounded,
                        tooltip: 'Удалить'.tr,
                        size: 72,
                        onTap: () =>
                            DirtyLeaveScope.of(context)?.requestLeave(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
