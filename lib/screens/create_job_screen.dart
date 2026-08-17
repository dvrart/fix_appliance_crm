import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:flutter/cupertino.dart';

class ApplianceFormItem {
  final TextEditingController typeController = TextEditingController();
  final TextEditingController brandController = TextEditingController();
  final TextEditingController modelController = TextEditingController();
  final TextEditingController issueController = TextEditingController();
}

class CreateJobScreen extends StatefulWidget {
  final DateTime? preselectedDate;
  const CreateJobScreen({super.key, this.preselectedDate});

  @override
  State<CreateJobScreen> createState() => _CreateJobScreenState();
}

class _CreateJobScreenState extends State<CreateJobScreen> {
  final _formKey = GlobalKey<FormState>();

  // Контроллеры для Владельца
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();

  // Разделенные контроллеры для адреса Владельца
  final _clientStreetCtrl = TextEditingController();
  final _clientCityCtrl = TextEditingController();
  final _clientPostalCtrl = TextEditingController();

  // Контроллеры для Арендатора
  bool _hasDifferentJobSite = false;
  final _siteNameController = TextEditingController();
  final _sitePhoneController = TextEditingController();

  // Разделенные контроллеры для адреса Арендатора
  final _siteStreetCtrl = TextEditingController();
  final _siteCityCtrl = TextEditingController();
  final _sitePostalCtrl = TextEditingController();

  final List<ApplianceFormItem> _appliances = [ApplianceFormItem()];

  DateTime? _selectedDate;
  TimeOfDay? _selectedTime;
  bool _isSaving = false;

  bool _isSearchingLive = false;
  String? _existingClientId;
  Timer? _debounce;
  List<DocumentSnapshot> _clientSuggestions = [];

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.preselectedDate ?? DateTime.now();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (var app in _appliances) {
      app.typeController.dispose();
      app.brandController.dispose();
      app.modelController.dispose();
      app.issueController.dispose();
    }
    _clientStreetCtrl.dispose();
    _clientCityCtrl.dispose();
    _clientPostalCtrl.dispose();
    _siteNameController.dispose();
    _sitePhoneController.dispose();
    _siteStreetCtrl.dispose();
    _siteCityCtrl.dispose();
    _sitePostalCtrl.dispose();
    super.dispose();
  }

  void _addAppliance() => setState(() => _appliances.add(ApplianceFormItem()));
  void _removeAppliance(int index) =>
      setState(() => _appliances.removeAt(index));

  void _onPhoneChanged(String value) {
    if (_existingClientId != null) setState(() => _existingClientId = null);
    if (_debounce?.isActive ?? false) _debounce!.cancel();

    if (value.length < 4) {
      setState(() {
        _clientSuggestions = [];
        _isSearchingLive = false;
      });
      return;
    }

    setState(() => _isSearchingLive = true);
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      try {
        final snapshot = await FirebaseFirestore.instance
            .collection('companies')
            .doc('fix_appliance_ca')
            .collection('clients')
            .where('phone', isGreaterThanOrEqualTo: value)
            .where('phone', isLessThanOrEqualTo: '$value\uf8ff')
            .limit(5)
            .get();
        if (mounted)
          setState(() {
            _clientSuggestions = snapshot.docs;
            _isSearchingLive = false;
          });
      } catch (e) {
        if (mounted) setState(() => _isSearchingLive = false);
      }
    });
  }

  // --- УМНЫЙ ЭКРАН ПОИСКА И РАЗДЕЛЕНИЯ АДРЕСА ---
  void _showAddressPicker(BuildContext context, {required bool isJobSite}) {
    final streetCtrl = TextEditingController(
      text: isJobSite ? _siteStreetCtrl.text : _clientStreetCtrl.text,
    );
    final cityCtrl = TextEditingController(
      text: isJobSite ? _siteCityCtrl.text : _clientCityCtrl.text,
    );
    final postalCtrl = TextEditingController(
      text: isJobSite ? _sitePostalCtrl.text : _clientPostalCtrl.text,
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Поиск адреса',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF14557F),
                ),
              ),
              const SizedBox(height: 16),

              // 1. Строка автозаполнения (В будущем тут будет Google Places API)
              TextField(
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Начните вводить адрес...',
                  prefixIcon: const Icon(
                    Icons.search,
                    color: Color(0xFF14557F),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                      color: Color(0xFFFCC520),
                      width: 2,
                    ),
                  ),
                  filled: true,
                  fillColor: Colors.grey.shade50,
                ),
                onChanged: (val) {
                  // --- ИМИТАЦИЯ GOOGLE API ДЛЯ ТЕСТА ---
                  // Если напечатать "123", поля заполнятся автоматически
                  if (val.contains('123')) {
                    streetCtrl.text = '123 Main St';
                    cityCtrl.text = 'Waterford';
                    postalCtrl.text = 'N0E 1Y0';
                  }
                },
              ),
              const SizedBox(height: 16),

              // 2. Интеграция Карты
              Container(
                height: 120,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.map, size: 40, color: Colors.grey),
                      SizedBox(height: 4),
                      Text(
                        'Google Maps Картинка',
                        style: TextStyle(color: Colors.black54),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // 3. Разделенные поля (Заполняются автоматически или вручную)
              TextField(
                controller: streetCtrl,
                decoration: const InputDecoration(
                  labelText: 'Улица и дом',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: cityCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Город',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: postalCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Индекс',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // 4. Кнопка сохранения
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFCC520),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () {
                    setState(() {
                      if (isJobSite) {
                        _siteStreetCtrl.text = streetCtrl.text;
                        _siteCityCtrl.text = cityCtrl.text;
                        _sitePostalCtrl.text = postalCtrl.text;
                      } else {
                        _clientStreetCtrl.text = streetCtrl.text;
                        _clientCityCtrl.text = cityCtrl.text;
                        _clientPostalCtrl.text = postalCtrl.text;
                      }
                    });
                    Navigator.pop(context);
                  },
                  child: const Text(
                    'ПОДТВЕРДИТЬ АДРЕС',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickDateTime() async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? DateTime.now(),
      firstDate: DateTime(2023),
      lastDate: DateTime(2030),
    );
    if (pickedDate == null) return;

    TimeOfDay? pickedTime = await showDialog<TimeOfDay>(
      context: context,
      builder: (context) {
        TimeOfDay tempTime = _selectedTime ?? TimeOfDay.now();
        return AlertDialog(
          title: const Text(
            'Выберите время',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          content: SizedBox(
            height: 200,
            width: 300,
            child: CupertinoDatePicker(
              mode: CupertinoDatePickerMode.time,
              use24hFormat: true,
              initialDateTime: DateTime(
                pickedDate.year,
                pickedDate.month,
                pickedDate.day,
                tempTime.hour,
                tempTime.minute,
              ),
              onDateTimeChanged: (dt) =>
                  tempTime = TimeOfDay(hour: dt.hour, minute: dt.minute),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Отмена', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(tempTime),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
              ),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );

    if (pickedTime != null)
      setState(() {
        _selectedDate = pickedDate;
        _selectedTime = pickedTime;
      });
  }

  Future<void> _saveJob() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedDate == null || _selectedTime == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Пожалуйста, выберите дату и время')),
      );
      return;
    }

    // Проверка, что адрес заполнен
    if (_clientCityCtrl.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Пожалуйста, укажите адрес (Город)'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final db = FirebaseFirestore.instance;
      final clientsRef = db
          .collection('companies')
          .doc('fix_appliance_ca')
          .collection('clients');
      String clientId;

      // Склеиваем полный адрес для карточки клиента
      String fullClientAddress =
          "${_clientStreetCtrl.text}, ${_clientCityCtrl.text}, ${_clientPostalCtrl.text}";

      if (_existingClientId != null) {
        clientId = _existingClientId!;
        await clientsRef.doc(clientId).update({
          'fullName': _nameController.text.trim(),
          'address': fullClientAddress,
        });
      } else {
        final newClientRef = clientsRef.doc();
        clientId = newClientRef.id;
        await newClientRef.set({
          'fullName': _nameController.text.trim(),
          'phone': _phoneController.text.trim(),
          'address': fullClientAddress,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      DateTime jobDateTime = DateTime(
        _selectedDate!.year,
        _selectedDate!.month,
        _selectedDate!.day,
        _selectedTime!.hour,
        _selectedTime!.minute,
      );

      List<Map<String, String>> appliancesList = _appliances
          .map(
            (app) => {
              'type': app.typeController.text.trim(),
              'brand': app.brandController.text.trim(),
              'model': app.modelController.text.trim(),
              'issue': app.issueController.text.trim(),
            },
          )
          .toList();

      // Определяем город, куда мы реально едем (для календаря)
      String targetCity = _hasDifferentJobSite && _siteCityCtrl.text.isNotEmpty
          ? _siteCityCtrl.text.trim()
          : _clientCityCtrl.text.trim();
      String fullJobSiteAddress =
          "${_siteStreetCtrl.text}, ${_siteCityCtrl.text}, ${_sitePostalCtrl.text}";

      final jobData = {
        'clientId': clientId,
        'clientName': _nameController.text.trim(),
        'clientPhone': _phoneController.text.trim(),
        'clientAddress': fullClientAddress,

        'hasJobSite': _hasDifferentJobSite,
        'jobSiteName': _hasDifferentJobSite
            ? _siteNameController.text.trim()
            : '',
        'jobSitePhone': _hasDifferentJobSite
            ? _sitePhoneController.text.trim()
            : '',
        'jobSiteAddress': _hasDifferentJobSite ? fullJobSiteAddress : '',

        // ВАЖНО: Чистый город для календаря!
        'displayCity': targetCity,

        'applianceType': _appliances[0].typeController.text.trim(),
        'brand': _appliances[0].brandController.text.trim(),
        'model': _appliances[0].modelController.text.trim(),
        'description': _appliances[0].issueController.text.trim(),
        'appliancesList': appliancesList,

        'status': 'Новая',
        'priority': '🟢 Обычный',
        'date': DateFormat('yyyy-MM-dd').format(jobDateTime),
        'time': _selectedTime!.format(context),
        'scheduledDate': Timestamp.fromDate(jobDateTime),
        'scheduledAt': Timestamp.fromDate(jobDateTime),
        'createdAt': FieldValue.serverTimestamp(),
      };

      await db
          .collection('companies')
          .doc('fix_appliance_ca')
          .collection('jobs')
          .add(jobData);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Заявка успешно создана!'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
        );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    int maxLines = 1,
    TextInputType keyboardType = TextInputType.text,
    bool isRequired = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        maxLines: maxLines,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, color: Colors.grey, size: 20),
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
            ? (v) => v == null || v.isEmpty ? 'Обязательное поле' : null
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Новая заявка',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFF14557F),
        foregroundColor: Colors.white,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'ДАННЫЕ ВЛАДЕЛЬЦА (BILL TO)',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 12),

            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  onChanged: _onPhoneChanged,
                  decoration: InputDecoration(
                    labelText: 'Номер телефона',
                    prefixIcon: const Icon(Icons.phone, color: Colors.grey),
                    suffixIcon: _isSearchingLive
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : (_existingClientId != null
                              ? const Icon(
                                  Icons.check_circle,
                                  color: Colors.green,
                                )
                              : null),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(
                        color: Color(0xFFFCC520),
                        width: 2,
                      ),
                    ),
                    filled: true,
                    fillColor: Colors.grey.shade50,
                  ),
                  validator: (v) =>
                      v == null || v.isEmpty ? 'Обязательное поле' : null,
                ),
                if (_clientSuggestions.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 4, bottom: 12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black12,
                          blurRadius: 8,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      children: _clientSuggestions.map((doc) {
                        final data = doc.data() as Map<String, dynamic>;
                        return ListTile(
                          leading: const CircleAvatar(
                            backgroundColor: Color(0xFF14557F),
                            child: Icon(Icons.person, color: Colors.white),
                          ),
                          title: Text(
                            data['phone'] ?? '',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            data['fullName'] ?? data['name'] ?? '',
                          ),
                          onTap: () {
                            setState(() {
                              _existingClientId = doc.id;
                              _phoneController.text = data['phone'] ?? '';
                              _nameController.text =
                                  data['fullName'] ?? data['name'] ?? '';

                              // Разбиваем адрес, если он был склеен старым методом
                              final addrParts = (data['address'] ?? '')
                                  .toString()
                                  .split(',');
                              if (addrParts.isNotEmpty)
                                _clientStreetCtrl.text = addrParts[0].trim();
                              if (addrParts.length > 1)
                                _clientCityCtrl.text = addrParts[1].trim();
                              if (addrParts.length > 2)
                                _clientPostalCtrl.text = addrParts[2].trim();

                              _clientSuggestions = [];
                            });
                            FocusScope.of(context).unfocus();
                          },
                        );
                      }).toList(),
                    ),
                  ),
                if (_clientSuggestions.isEmpty) const SizedBox(height: 12),
              ],
            ),

            _buildTextField(
              controller: _nameController,
              label: 'Имя владельца',
              icon: Icons.person,
              isRequired: true,
            ),

            // --- НОВАЯ КНОПКА ВВОДА АДРЕСА ---
            GestureDetector(
              onTap: () => _showAddressPicker(context, isJobSite: false),
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
                      Icons.receipt_long,
                      color: Colors.grey,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _clientCityCtrl.text.isEmpty
                            ? 'Нажмите, чтобы ввести адрес...'
                            : '${_clientStreetCtrl.text}, ${_clientCityCtrl.text}',
                        style: TextStyle(
                          color: _clientCityCtrl.text.isEmpty
                              ? Colors.black54
                              : Colors.black87,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    const Icon(Icons.search, color: Color(0xFF14557F)),
                  ],
                ),
              ),
            ),

            Container(
              margin: const EdgeInsets.only(bottom: 12, top: 4),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SwitchListTile(
                title: const Text(
                  'Другое место работы (Арендатор)',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF14557F),
                  ),
                ),
                subtitle: const Text('Техника находится по другому адресу'),
                activeColor: const Color(0xFF14557F),
                value: _hasDifferentJobSite,
                onChanged: (val) => setState(() => _hasDifferentJobSite = val),
              ),
            ),

            if (_hasDifferentJobSite) ...[
              const Text(
                'КОНТАКТ НА МЕСТЕ (JOB SITE)',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.orange,
                ),
              ),
              const SizedBox(height: 12),
              _buildTextField(
                controller: _siteNameController,
                label: 'Имя на месте (Арендатор)',
                icon: Icons.person_outline,
                isRequired: true,
              ),
              _buildTextField(
                controller: _sitePhoneController,
                label: 'Телефон на месте',
                icon: Icons.phone_android,
                keyboardType: TextInputType.phone,
                isRequired: true,
              ),

              // --- КНОПКА ВВОДА АДРЕСА АРЕНДАТОРА ---
              GestureDetector(
                onTap: () => _showAddressPicker(context, isJobSite: true),
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
                          _siteCityCtrl.text.isEmpty
                              ? 'Адрес работы (Куда ехать)...'
                              : '${_siteStreetCtrl.text}, ${_siteCityCtrl.text}',
                          style: TextStyle(
                            color: _siteCityCtrl.text.isEmpty
                                ? Colors.black54
                                : Colors.black87,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      const Icon(Icons.search, color: Color(0xFF14557F)),
                    ],
                  ),
                ),
              ),
            ],
            const Divider(height: 32),

            const Text(
              'ТЕХНИКА И ПРОБЛЕМА',
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
                            'Аппарат ${idx + 1}',
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
                              label: 'Тип (Холодильник и т.д.)',
                              icon: Icons.kitchen,
                              isRequired: true,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildTextField(
                              controller: item.brandController,
                              label: 'Бренд',
                              icon: Icons.branding_watermark,
                            ),
                          ),
                        ],
                      ),
                      _buildTextField(
                        controller: item.modelController,
                        label: 'Модель / S/N',
                        icon: Icons.qr_code,
                      ),
                      _buildTextField(
                        controller: item.issueController,
                        label: 'Описание',
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
                label: const Text('Добавить еще технику'),
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

            const Text(
              'ДАТА И ВРЕМЯ',
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
                      ? 'Нажмите, чтобы выбрать'
                      : '${DateFormat('dd MMMM yyyy').format(_selectedDate!)}  в  ${_selectedTime!.format(context)}',
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
            const SizedBox(height: 40),

            SizedBox(
              height: 54,
              child: ElevatedButton(
                onPressed: _isSaving ? null : _saveJob,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFCC520),
                  foregroundColor: Colors.black,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isSaving
                    ? const CircularProgressIndicator(color: Colors.black)
                    : const Text(
                        'Создать заявку',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}
