import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../../core/constants.dart';
import '../../services/services.dart';
import '../../shared/widgets/keyboard_safe.dart';
import '../../widgets/smart_address_picker.dart';
import '../jobs/job_details/job_details_screen.dart';
import '../jobs/create_job_screen.dart';
import '../calls/call_screen.dart';
import '../messages/conversation_screen.dart';
import '../../core/l10n/app_locale.dart';
import '../../models/job.dart';
import '../../shared/widgets/email_field.dart';

class ClientDetailsScreen extends StatefulWidget {
  final String clientId;
  final Map<String, dynamic> clientData;

  const ClientDetailsScreen({
    super.key,
    required this.clientId,
    required this.clientData,
  });

  @override
  State<ClientDetailsScreen> createState() => _ClientDetailsScreenState();
}

class _ClientDetailsScreenState extends State<ClientDetailsScreen> {
  void _makeCall(String phone, String name) {
    if (phone.isEmpty) return;
    CallScreen.open(context, phoneNumber: phone, contactName: name);
  }

  void _sendSms(String phone, String name, {String? email}) {
    if (phone.isEmpty && !(email ?? '').contains('@')) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ConversationScreen(
          phoneNumber: phone,
          email: email,
          contactName: name,
          clientId: widget.clientId,
        ),
      ),
    );
  }

  String _extractClientName(Map<String, dynamic> data) {
    for (final key in ['fullName', 'name', 'clientName']) {
      final value = data[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return 'Без имени'.tr;
  }

  void _openNewJob(String name, String phone, String address, {String? email, String? company}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CreateJobScreen(
          existingClientId: widget.clientId,
          initialName: name,
          initialPhone: phone,
          initialAddress: address,
          initialEmail: email,
          initialCompany: company,
        ),
      ),
    );
  }

  Future<void> _deleteClient(String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (context) => AlertDialog(
        title: Text('Удалить клиента?'.tr),
        content: Text('$name\n\n${'Карточка будет удалена. Заявки в календаре останутся.'.tr}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Отмена'.tr),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: Text('Удалить'.tr),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final messenger = ScaffoldMessenger.of(context);
    await ClientService.delete(widget.clientId);
    if (!mounted) return;
    Navigator.pop(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text('Клиент удалён'.tr),
        backgroundColor: Colors.red,
      ),
    );
  }

  void _editClientDialog(Map<String, dynamic> currentData) {
    final nameController = TextEditingController(
      text: _extractClientName(currentData),
    );
    final phoneController = TextEditingController(
      text: currentData['phone'] ?? '',
    );
    final emailController = TextEditingController(
      text: currentData['email'] ?? '',
    );
    final companyController = TextEditingController(
      text: currentData['companyName'] ?? currentData['company'] ?? '',
    );
    final notesController = TextEditingController(
      text: currentData['notes'] ?? currentData['description'] ?? '',
    );
    var source = (currentData['source'] ?? '').toString();

    final addressParts = splitAddress((currentData['address'] ?? '').toString());
    final streetController = TextEditingController(text: addressParts[0]);
    final cityController = TextEditingController(text: addressParts[1]);
    final postalController = TextEditingController(text: addressParts[2]);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (builderContext, setSheetState) {
            return KeyboardAvoidingSheet(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Заголовок
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
                          onPressed: () => Navigator.pop(sheetContext),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Форма
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            TextField(
                              controller: nameController,
                              decoration: InputDecoration(
                                labelText: 'Имя'.tr,
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.person),
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: phoneController,
                              keyboardType: TextInputType.phone,
                              decoration: InputDecoration(
                                labelText: 'Телефон'.tr,
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.phone),
                              ),
                            ),
                            const SizedBox(height: 16),

                            // --- КНОПКА ПОИСКА АДРЕСА (как в create_job_screen) ---
                            GestureDetector(
                              onTap: () {
                                showSmartAddressPicker(
                                  context: context,
                                  initialStreet: streetController.text,
                                  initialCity: cityController.text,
                                  initialPostal: postalController.text,
                                  onSaved: (street, city, postal) {
                                    setSheetState(() {
                                      streetController.text = street;
                                      cityController.text = city;
                                      postalController.text = postal;
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
                                    const Icon(Icons.search, color: AppColors.primary),
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
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.business),
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: notesController,
                              maxLines: 3,
                              decoration: InputDecoration(
                                labelText: 'Описание'.tr,
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.notes),
                              ),
                            ),
                            const SizedBox(height: 12),
                            StreamBuilder<List<String>>(
                              stream: CatalogService.streamLeadSources(),
                              builder: (context, snap) {
                                final sources = snap.data ?? CatalogService.defaultLeadSources;
                                return DropdownButtonFormField<String>(
                                  value: sources.contains(source) ? source : null,
                                  decoration: InputDecoration(
                                    labelText: 'Откуда узнали'.tr,
                                    border: OutlineInputBorder(),
                                    prefixIcon: Icon(Icons.campaign_outlined),
                                  ),
                                  items: [
                                    DropdownMenuItem(
                                      value: null,
                                      child: Text('Не указано'.tr),
                                    ),
                                    for (final item in sources)
                                      DropdownMenuItem(value: item, child: Text(trAny(item))),
                                  ],
                                  onChanged: (value) {
                                    setSheetState(() => source = value ?? '');
                                  },
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),

                    // Кнопка сохранения
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () async {
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
                              currentData: currentData,
                            ),
                          });
                          if (sheetContext.mounted) Navigator.pop(sheetContext);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          'СОХРАНИТЬ'.tr,
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirestoreService.clientsRef.doc(widget.clientId).snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data() as Map<String, dynamic>? ?? widget.clientData;
        final name = _extractClientName(data);
        final phone = data['phone'] ?? '';
        final address = data['address'] ?? '';
        final company = data['companyName'] ?? data['company'] ?? '';
        final email = (data['email'] ?? '').toString();
        final notes = (data['notes'] ?? data['description'] ?? '').toString();
        final source = (data['source'] ?? '').toString();

        return Scaffold(
          appBar: AppBar(
            title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            actions: [
              IconButton(
                icon: const Icon(Icons.edit),
                onPressed: () => _editClientDialog(data),
              ),
              IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                tooltip: 'Удалить клиента'.tr,
                onPressed: () => _deleteClient(name),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _openNewJob(name, phone, address, email: email, company: company),
            backgroundColor: AppColors.accent,
            foregroundColor: Colors.black,
            icon: const Icon(Icons.add),
            label: Text('Новый ремонт'.tr),
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 88),
            child: Column(
              children: [
                // Шапка с контактами
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: const BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.only(
                      bottomLeft: Radius.circular(24),
                      bottomRight: Radius.circular(24),
                    ),
                  ),
                  child: Column(
                    children: [
                      CircleAvatar(
                        radius: 40,
                        backgroundColor: Colors.white,
                        child: Text(
                          name.isNotEmpty ? name[0].toUpperCase() : '?',
                          style: const TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        name,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      if (company.isNotEmpty)
                        Text(
                          company,
                          style: const TextStyle(color: Colors.white70),
                        ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _buildActionButton(
                            icon: Icons.phone,
                            label: 'Позвонить'.tr,
                            color: Colors.green,
                            onTap: () => _makeCall(phone, name),
                          ),
                          const SizedBox(width: 16),
                          _buildActionButton(
                            icon: Icons.forum,
                            label: 'Написать'.tr,
                            color: Colors.blue,
                            onTap: () => _sendSms(phone, name, email: email),
                          ),
                          const SizedBox(width: 16),
                          _buildActionButton(
                            icon: Icons.navigation,
                            label: 'Маршрут'.tr,
                            color: Colors.orange,
                            onTap: () => MapsService.openNavigator(address),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Информация
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildInfoCard(
                        icon: Icons.phone,
                        title: 'Телефон'.tr,
                        value: phone.isEmpty ? 'Не указан'.tr : phone,
                      ),
                      _buildInfoCard(
                        icon: Icons.email_outlined,
                        title: 'Электронный адрес'.tr,
                        value: email.isEmpty ? 'Не указан'.tr : email,
                      ),
                      _buildInfoCard(
                        icon: Icons.location_on,
                        title: 'Адрес'.tr,
                        value: address.isEmpty ? 'Не указан'.tr : address,
                        onTap: () => _editAddress(data),
                      ),
                      _buildInfoCard(
                        icon: Icons.campaign_outlined,
                        title: 'Откуда узнали'.tr,
                        value: source.isEmpty ? 'Не указано'.tr : trAny(source),
                      ),
                      if (notes.isNotEmpty)
                        _buildInfoCard(
                          icon: Icons.notes,
                          title: 'Описание'.tr,
                          value: notes,
                        ),

                      const SizedBox(height: 24),
                      Text(
                        'Техника'.tr,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildEquipmentHistory(),
                      const SizedBox(height: 24),

                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'История заявок'.tr,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 18,
                              ),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: () => _openNewJob(name, phone, address, email: email, company: company),
                            icon: const Icon(Icons.add_circle),
                            label: Text('Новая работа'.tr),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _buildJobsHistory(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _editAddress(Map<String, dynamic> data) {
    final parts = splitAddress((data['address'] ?? '').toString());
    showSmartAddressPicker(
      context: context,
      initialStreet: parts[0],
      initialCity: parts[1],
      initialPostal: parts[2],
      onSaved: (street, city, postal) {
        ClientService.updateAddress(
          widget.clientId,
          street: street,
          city: city,
          postal: postal,
          currentData: data,
        );
      },
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: color.withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard({
    required IconData icon,
    required String title,
    required String value,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Row(
          children: [
            Icon(icon, color: AppColors.primary),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  Text(
                    value,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
            if (onTap != null)
              Icon(Icons.edit, color: Colors.grey.shade400, size: 18),
          ],
        ),
      ),
    );
  }

  String _ago(DateTime date) {
    final days = DateTime.now().difference(date).inDays;
    if (days <= 0) return 'сегодня'.tr;
    if (days == 1) return 'вчера'.tr;
    if (days < 21) return '$days ${'дн. назад'.tr}';
    if (days < 60) return '${(days / 7).floor()} ${'нед. назад'.tr}';
    return '${(days / 30).floor()} ${'мес. назад'.tr}';
  }

  Widget _buildEquipmentHistory() {
    return StreamBuilder<List<Job>>(
      stream: JobService.streamByClient(widget.clientId),
      builder: (context, snapshot) {
        final jobs = snapshot.data ?? const <Job>[];
        final groups = <String, List<Job>>{};
        for (final job in jobs) {
          for (final appliance in job.appliances) {
            final serial = appliance.serialNumber.trim();
            final model = appliance.model.trim();
            final key = serial.isNotEmpty
                ? 'sn:$serial'
                : [
                    appliance.type,
                    appliance.brand,
                    model,
                  ].where((part) => part.trim().isNotEmpty).join(' · ');
            if (key.isEmpty) continue;
            groups.putIfAbsent(key, () => []).add(job);
          }
        }
        if (groups.isEmpty) {
          return Text(
            'Серийник и модель появятся после заявок'.tr,
            style: const TextStyle(color: Colors.grey),
          );
        }
        return Column(
          children: groups.entries.map((entry) {
            final jobsForUnit = [...entry.value]
              ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
            final latest = jobsForUnit.first;
            final appliance = latest.appliances.firstWhere(
              (item) {
                final serial = item.serialNumber.trim();
                if (entry.key.startsWith('sn:')) {
                  return 'sn:$serial' == entry.key;
                }
                return [
                      item.type,
                      item.brand,
                      item.model.trim(),
                    ].where((part) => part.trim().isNotEmpty).join(' · ') ==
                    entry.key;
              },
              orElse: () => latest.primaryAppliance ??
                  JobAppliance(type: latest.applianceType),
            );
            final title = [
              appliance.type,
              appliance.brand,
              appliance.model,
            ].where((part) => part.trim().isNotEmpty).join(' · ');
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: Icon(
                  ApplianceCategories.getIcon(appliance.type),
                  color: AppColors.primary,
                ),
                title: Text(title.isEmpty ? 'Техника'.tr : trAny(title)),
                subtitle: Text(
                  [
                    if (appliance.serialNumber.trim().isNotEmpty)
                      '${'S/N'.tr} ${appliance.serialNumber}',
                    '${jobsForUnit.length} ${'визитов'.tr}',
                    trAny(latest.status),
                  ].join(' · '),
                ),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => JobDetailsScreen(
                        jobId: latest.id,
                        clientId: widget.clientId,
                        jobData: latest.toMap(),
                      ),
                    ),
                  );
                },
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildJobsHistory() {
    return StreamBuilder<List<Job>>(
      stream: JobService.streamByClient(widget.clientId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final jobs = snapshot.data ?? [];

        if (jobs.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(
                'Нет заявок'.tr,
                style: TextStyle(color: Colors.grey),
              ),
            ),
          );
        }

        return Column(
          children: jobs.map((job) {
            final status = job.status;
            final applianceType = job.applianceType;
            final visits = job.coalescedVisits;
            final nextVisit = job.scheduledAt ??
                (visits.isNotEmpty ? visits.last.startAt : null);

            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: StatusService.colorOf(status).withOpacity(0.3)),
              ),
              child: ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: StatusService.colorOf(status).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    ApplianceCategories.getIcon(applianceType),
                    color: StatusService.colorOf(status),
                  ),
                ),
                title: Text(
                  trAny(applianceType),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  [
                    if (visits.length > 1)
                      '${visits.length} ${'визитов'.tr} · ${DateFormat('dd.MM.yyyy HH:mm').format(nextVisit!)}'
                    else if (nextVisit != null)
                      DateFormat('dd.MM.yyyy HH:mm').format(nextVisit)
                    else
                      'Дата не указана'.tr,
                    if (nextVisit != null) _ago(nextVisit),
                    if (job.isUnpaid) 'Неоплачено'.tr,
                    if (job.status == JobStatuses.completed) 'Прошлый визит'.tr,
                  ].join(' · '),
                ),
                trailing: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: StatusService.colorOf(status).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    trAny(status),
                    style: TextStyle(
                      color: StatusService.colorOf(status),
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => JobDetailsScreen(
                        jobId: job.id,
                        clientId: widget.clientId,
                        jobData: job.toMap(),
                      ),
                    ),
                  );
                },
              ),
            );
          }).toList(),
        );
      },
    );
  }
}
