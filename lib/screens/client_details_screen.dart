import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart'; // Добавлен импорт для барабана времени
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import '../core/haptics.dart';
import '../services/client_job_sync.dart';
import '../shared/widgets/ai_head.dart';
import 'job_details_screen.dart';

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
  Future<void> _makeCall(String phone) async {
    if (phone.isEmpty) return;
    final Uri uri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<void> _sendSms(String phone) async {
    if (phone.isEmpty) return;
    final Uri uri = Uri(scheme: 'sms', path: phone);
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  void _editClientDialog(Map<String, dynamic> currentData) {
    final nameController = TextEditingController(
      text: currentData['name'] ?? currentData['fullName'] ?? '',
    );
    final phoneController = TextEditingController(
      text: currentData['phone'] ?? '',
    );
    final addressController = TextEditingController(
      text: currentData['address'] ?? '',
    );

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text(
            'Редактировать профиль',
            style: TextStyle(
              color: Color(0xFF14557F),
              fontWeight: FontWeight.bold,
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Имя',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Телефон',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: addressController,
                  decoration: const InputDecoration(
                    labelText: 'Адрес',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () async {
                AppHaptics.button();
                final name = nameController.text.trim();
                final phone = phoneController.text.trim();
                final address = addressController.text.trim();
                await FirebaseFirestore.instance
                    .collection('companies')
                    .doc('fix_appliance_ca')
                    .collection('clients')
                    .doc(widget.clientId)
                    .update({
                      'name': name,
                      'fullName': name,
                      'clientName': name,
                      'phone': phone,
                      'address': address,
                    });
                await ClientJobSync.apply(
                  clientId: widget.clientId,
                  name: name,
                  phone: phone,
                  address: address,
                );
                if (context.mounted) Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFCC520),
                foregroundColor: Colors.black,
              ),
              child: const Text(
                'Сохранить',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
  }

  void _deleteClient() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить клиента?'),
        content: const Text('Вы уверены? Это действие нельзя отменить.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () async {
              await FirebaseFirestore.instance
                  .collection('companies')
                  .doc('fix_appliance_ca')
                  .collection('clients')
                  .doc(widget.clientId)
                  .delete();
              if (context.mounted) {
                Navigator.pop(context);
                Navigator.pop(context);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
  }

  void _showCreateJobForClientDialog(
    String clientName,
    String clientPhone,
    String clientAddress,
  ) {
    String type = 'Стиральная машина';
    final brandController = TextEditingController();
    final descController = TextEditingController();

    DateTime? selectedDate;
    TimeOfDay? selectedTime;

    List<Map<String, dynamic>> newAttachments = [];

    bool isDifferentAddress = false;
    final tenantNameCtrl = TextEditingController();
    final tenantPhoneCtrl = TextEditingController();
    final tenantAddressCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            // --- ЛОГИКА ВЫБОРА ДАТЫ, А ЗАТЕМ ВРЕМЕНИ В ВИДЕ БАРАБАНА ---
            Future<void> pickDateTime() async {
              // 1. Выбор даты (стандартный календарь)
              final pickedDate = await showDatePicker(
                context: context,
                initialDate: selectedDate ?? DateTime.now(),
                firstDate: DateTime.now(),
                lastDate: DateTime(2030),
                builder: (context, child) => Theme(
                  data: ThemeData.light().copyWith(
                    colorScheme: const ColorScheme.light(
                      primary: Color(0xFF14557F),
                    ),
                  ),
                  child: child!,
                ),
              );

              if (pickedDate != null) {
                if (!context.mounted) return;

                // 2. Выбор времени (Кастомный диалог с Cupertino барабаном как на фото)
                final TimeOfDay? pickedTime = await showDialog<TimeOfDay>(
                  context: context,
                  builder: (BuildContext context) {
                    DateTime tempTime = DateTime(
                      DateTime.now().year,
                      DateTime.now().month,
                      DateTime.now().day,
                      selectedTime?.hour ?? DateTime.now().hour,
                      selectedTime?.minute ?? DateTime.now().minute,
                    );

                    return Dialog(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Container(
                        padding: const EdgeInsets.all(20),
                        height: 350,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'Выберите время',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Expanded(
                              child: CupertinoDatePicker(
                                mode: CupertinoDatePickerMode.time,
                                use24hFormat:
                                    true, // 24-часовой формат (без AM/PM)
                                initialDateTime: tempTime,
                                onDateTimeChanged: (DateTime newTime) {
                                  tempTime = newTime;
                                },
                              ),
                            ),
                            const SizedBox(height: 16),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text(
                                    'Отмена',
                                    style: TextStyle(
                                      color: Colors.grey,
                                      fontSize: 16,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors
                                        .black, // Черная кнопка как на фото
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 24,
                                      vertical: 12,
                                    ),
                                  ),
                                  onPressed: () => Navigator.pop(
                                    context,
                                    TimeOfDay.fromDateTime(tempTime),
                                  ),
                                  child: const Text(
                                    'OK',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );

                if (pickedTime != null) {
                  setDialogState(() {
                    selectedDate = pickedDate;
                    selectedTime = pickedTime;
                  });
                }
              }
            }

            return AlertDialog(
              title: const Text(
                'Новая заявка',
                style: TextStyle(
                  color: Color(0xFF14557F),
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        value: type,
                        items:
                            [
                                  'Стиральная машина',
                                  'Сушильная машина',
                                  'Холодильник',
                                  'Посудомойка',
                                  'Плита / Духовка',
                                  'Микроволновка',
                                  'Другое',
                                ]
                                .map(
                                  (t) => DropdownMenuItem(
                                    value: t,
                                    child: Text(t),
                                  ),
                                )
                                .toList(),
                        onChanged: (val) => setDialogState(() {
                          type = val!;
                        }),
                        decoration: const InputDecoration(
                          labelText: 'Тип техники',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: brandController,
                        decoration: const InputDecoration(
                          labelText: 'Бренд (например: LG)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: descController,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Описание поломки',
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                      ),
                      const SizedBox(height: 16),

                      GestureDetector(
                        onTap: pickDateTime,
                        child: AbsorbPointer(
                          child: TextField(
                            controller: TextEditingController(
                              text:
                                  (selectedDate != null && selectedTime != null)
                                  ? '${DateFormat('dd MMM yyyy').format(selectedDate!)} в ${selectedTime!.format(context)}'
                                  : '',
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Дата и время визита',
                              hintText: 'Выберите...',
                              border: OutlineInputBorder(),
                              suffixIcon: Icon(
                                Icons.calendar_month,
                                color: Color(0xFF14557F),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      const Text(
                        'Медиа:',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 60,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: newAttachments.length + 1,
                          itemBuilder: (context, index) {
                            if (index == 0) {
                              return GestureDetector(
                                onTap: () {
                                  setDialogState(() {
                                    newAttachments.add({
                                      'url':
                                          'https://picsum.photos/600/600?random=${DateTime.now().millisecond}',
                                      'type': 'image',
                                    });
                                  });
                                },
                                child: Container(
                                  width: 60,
                                  margin: const EdgeInsets.only(right: 8),
                                  decoration: BoxDecoration(
                                    color: Colors.blue.shade50,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: Colors.blue.shade200,
                                    ),
                                  ),
                                  child: const Icon(
                                    Icons.add_a_photo,
                                    color: Color(0xFF14557F),
                                  ),
                                ),
                              );
                            }
                            final file = newAttachments[index - 1];
                            return Container(
                              width: 60,
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.grey.shade300),
                                image: DecorationImage(
                                  image: NetworkImage(file['url']),
                                  fit: BoxFit.cover,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 16),

                      CheckboxListTile(
                        title: const Text(
                          'Другой адрес (Арендатор)',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        contentPadding: EdgeInsets.zero,
                        value: isDifferentAddress,
                        activeColor: const Color(0xFF14557F),
                        onChanged: (bool? value) {
                          setDialogState(() {
                            isDifferentAddress = value ?? false;
                          });
                        },
                      ),
                      if (isDifferentAddress) ...[
                        const SizedBox(height: 8),
                        TextField(
                          controller: tenantAddressCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Адрес работы',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: tenantNameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Имя на месте',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: tenantPhoneCtrl,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(
                            labelText: 'Телефон на месте',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    'Отмена',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                ElevatedButton(
                  onPressed: () async {
                    if (brandController.text.isNotEmpty) {
                      String finalDateTime = '';
                      if (selectedDate != null) {
                        finalDateTime = DateFormat(
                          'dd MMM yyyy',
                        ).format(selectedDate!);
                        if (selectedTime != null)
                          finalDateTime +=
                              ' в ${selectedTime!.format(context)}';
                      }

                      final docRef = await FirebaseFirestore.instance
                          .collection('companies')
                          .doc('fix_appliance_ca')
                          .collection('jobs')
                          .add({
                            'clientId': widget.clientId,
                            'clientName': clientName,
                            'clientPhone': clientPhone,
                            'clientAddress': clientAddress,
                            'applianceType': type,
                            'brand': brandController.text.trim(),
                            'description': descController.text.trim(),
                            'dateTime': finalDateTime,
                            'attachments': newAttachments,
                            'status': 'Новая',
                            'priority': '🟢 Обычный',
                            'hasJobSite': isDifferentAddress,
                            'jobSiteName': isDifferentAddress
                                ? tenantNameCtrl.text.trim()
                                : '',
                            'jobSitePhone': isDifferentAddress
                                ? tenantPhoneCtrl.text.trim()
                                : '',
                            'jobSiteAddress': isDifferentAddress
                                ? tenantAddressCtrl.text.trim()
                                : '',
                            'createdAt': FieldValue.serverTimestamp(),
                          });

                      final newJobData = await docRef.get();
                      if (context.mounted) {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => JobDetailsScreen(
                              jobId: docRef.id,
                              clientId: widget.clientId,
                              jobData:
                                  newJobData.data() as Map<String, dynamic>,
                            ),
                          ),
                        );
                      }
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFCC520),
                    foregroundColor: Colors.black,
                  ),
                  child: const Text('Создать'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        backgroundColor: const Color(0xFF14557F),
        foregroundColor: Colors.white,
        toolbarHeight: 48,
        titleSpacing: 4,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            AppHaptics.button();
            Navigator.pop(context);
          },
        ),
        title: const Row(
          children: [
            AiHead(size: 28),
            SizedBox(width: 8),
            Text(
              'Клиент',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            tooltip: 'Удалить клиента',
            onPressed: () {
              AppHaptics.button();
              _deleteClient();
            },
          ),
        ],
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('companies')
            .doc('fix_appliance_ca')
            .collection('clients')
            .doc(widget.clientId)
            .snapshots(),
        builder: (context, clientSnapshot) {
          if (clientSnapshot.connectionState == ConnectionState.waiting)
            return const Center(
              child: CircularProgressIndicator(color: Color(0xFFFCC520)),
            );
          if (!clientSnapshot.hasData || !clientSnapshot.data!.exists)
            return const Center(child: Text('Клиент не найден'));

          final clientData =
              clientSnapshot.data!.data() as Map<String, dynamic>;
          final name =
              clientData['name'] ?? clientData['fullName'] ?? 'Без имени';
          final phone = clientData['phone'] ?? '';
          final address = clientData['address'] ?? 'Адрес не указан';

          return StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('companies')
                .doc('fix_appliance_ca')
                .collection('jobs')
                .where('clientId', isEqualTo: widget.clientId)
                .snapshots(),
            builder: (context, jobsSnapshot) {
              final jobs = jobsSnapshot.data?.docs ?? [];
              double totalMoneyPaid = 0.0;
              for (var doc in jobs) {
                final jobMap = doc.data() as Map<String, dynamic>;
                if (jobMap['documents'] != null) {
                  for (var invoiceDoc in jobMap['documents']) {
                    if (invoiceDoc['status'] != 'cancelled' &&
                        invoiceDoc['payments'] != null) {
                      for (var p in invoiceDoc['payments']) {
                        totalMoneyPaid +=
                            double.tryParse(p['amount'].toString()) ?? 0.0;
                      }
                    }
                  }
                }
              }

              return CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
              SliverToBoxAdapter(
                child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                decoration: const BoxDecoration(
                  color: Color(0xFF14557F),
                  borderRadius: BorderRadius.only(
                    bottomLeft: Radius.circular(24),
                    bottomRight: Radius.circular(24),
                  ),
                ),
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: Colors.white,
                      child: Text(
                        name.isNotEmpty ? name[0].toUpperCase() : '?',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF14557F),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      phone,
                      style: const TextStyle(
                        fontSize: 16,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      address,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ElevatedButton.icon(
                          onPressed: () => _makeCall(phone),
                          icon: const Icon(Icons.phone),
                          label: const Text('Позвонить'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: () => _sendSms(phone),
                          icon: const Icon(Icons.sms),
                          label: const Text('СМС'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFCC520),
                            foregroundColor: Colors.black,
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: () => _editClientDialog(clientData),
                          icon: const Icon(Icons.edit, color: Colors.white),
                          tooltip: 'Редактировать',
                        ),
                      ],
                    ),
                  ],
                ),
                ),
              ),
              SliverToBoxAdapter(
                child: Column(
                  children: [
                    Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Row(
                            children: [
                              Expanded(
                                child: Card(
                                  elevation: 2,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Column(
                                      children: [
                                        const Text(
                                          'Всего заявок',
                                          style: TextStyle(color: Colors.grey),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '${jobs.length}',
                                          style: const TextStyle(
                                            fontSize: 24,
                                            fontWeight: FontWeight.bold,
                                            color: Color(0xFF14557F),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Card(
                                  elevation: 2,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Column(
                                      children: [
                                        const Text(
                                          'Оплачено (LTV)',
                                          style: TextStyle(
                                            color: Colors.grey,
                                            fontSize: 13,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '\$${totalMoneyPaid.toStringAsFixed(2)}',
                                          style: const TextStyle(
                                            fontSize: 20,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.green,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'История ремонтов',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              TextButton.icon(
                                onPressed: () => _showCreateJobForClientDialog(
                                  name,
                                  phone,
                                  address,
                                ),
                                icon: const Icon(
                                  Icons.add_circle,
                                  color: Color(0xFF14557F),
                                ),
                                label: const Text(
                                  'Новая работа',
                                  style: TextStyle(
                                    color: Color(0xFF14557F),
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                  ],
                ),
              ),
              if (jobs.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Text(
                      'У клиента еще нет заявок',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                                final jobDoc = jobs[index];
                                final jobData =
                                    jobDoc.data() as Map<String, dynamic>;

                                bool hasInvoice = false;
                                bool hasEstimate = false;
                                double invoiceTotal = 0.0;
                                double paidTotal = 0.0;
                                if (jobData['documents'] != null) {
                                  for (var d in jobData['documents']) {
                                    if (d['status'] != 'cancelled') {
                                      if (d['type'] == 'Estimate') {
                                        hasEstimate = true;
                                      } else if (d['type'] == 'Invoice') {
                                        hasInvoice = true;
                                        double sub = 0.0;
                                        if (d['items'] != null) {
                                          for (var i in d['items'])
                                            sub +=
                                                double.tryParse(
                                                  i['price'].toString(),
                                                ) ??
                                                0.0;
                                        }
                                        invoiceTotal +=
                                            sub +
                                            (sub *
                                                (double.tryParse(
                                                      d['taxRate'].toString(),
                                                    ) ??
                                                    0.0));
                                        if (d['payments'] != null) {
                                          for (var p in d['payments'])
                                            paidTotal +=
                                                double.tryParse(
                                                  p['amount'].toString(),
                                                ) ??
                                                0.0;
                                        }
                                      }
                                    }
                                  }
                                }

                                String status = jobData['status'] ?? 'Новая';
                                bool isJobCancelled =
                                    status == 'Отменена' || status == 'Отменен';

                                IconData leadIcon = Icons.build;
                                Color leadColor = const Color(0xFF14557F);
                                Color leadBg = Colors.blue.shade50;

                                if (isJobCancelled) {
                                  leadIcon = Icons.cancel;
                                  leadColor = Colors.red;
                                  leadBg = Colors.red.shade100;
                                } else if (hasInvoice &&
                                    paidTotal >= invoiceTotal &&
                                    invoiceTotal > 0) {
                                  leadIcon = Icons.check_circle;
                                  leadColor = Colors.green.shade800;
                                  leadBg = Colors.green.shade200;
                                } else if (hasInvoice &&
                                    paidTotal > 0 &&
                                    paidTotal < invoiceTotal) {
                                  leadIcon = Icons.timelapse;
                                  leadColor = Colors.amber.shade800;
                                  leadBg = Colors.amber.shade200;
                                } else if (!hasInvoice && hasEstimate) {
                                  leadIcon = Icons.description;
                                  leadColor = Colors.lightBlue;
                                  leadBg = Colors.lightBlue.shade50;
                                } else if (hasInvoice && paidTotal == 0) {
                                  leadIcon = Icons.circle_outlined;
                                  leadColor = Colors.blue;
                                  leadBg = Colors.blue.shade100;
                                }

                                return Card(
                                  margin: const EdgeInsets.only(bottom: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    ),
                                    leading: Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: leadBg,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Icon(
                                        leadIcon,
                                        color: leadColor,
                                        size: 28,
                                      ),
                                    ),
                                    title: Text(
                                      '${jobData['applianceType']} ${jobData['brand']}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    subtitle: Text(
                                      'Статус: ${jobData['status'] ?? 'Неизвестно'}\n${jobData['description'] ?? ''}',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: const Icon(Icons.chevron_right),
                                    onTap: () {
                                      AppHaptics.button();
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) =>
                                              JobDetailsScreen(
                                                jobId: jobDoc.id,
                                                clientId: widget.clientId,
                                                jobData: jobData,
                                              ),
                                        ),
                                      );
                                    },
                                  ),
                                );
                              },
                              childCount: jobs.length,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              );
            },
          ),
        );
  }
}
