import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'client_details_screen.dart';

class JobDetailsScreen extends StatefulWidget {
  final String jobId;
  final String clientId;
  final Map<String, dynamic> jobData;

  const JobDetailsScreen({
    super.key,
    required this.jobId,
    required this.clientId,
    required this.jobData,
  });

  @override
  State<JobDetailsScreen> createState() => _JobDetailsScreenState();
}

class _JobDetailsScreenState extends State<JobDetailsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late String _currentStatus;
  late String _currentPriority;
  late String _currentDescription;
  late bool _hasJobSite;
  late String _jobSiteName;
  late String _jobSitePhone;
  late String _jobSiteAddress;

  String _financeMode = 'main';
  List<Map<String, dynamic>> _documents = [];
  List<Map<String, dynamic>> _builderItems = [];
  double _builderTaxRate = 0.13;
  int? _viewingDocumentIndex;

  final TextEditingController _chatController = TextEditingController();
  String _activeChatRole = 'Владелец';
  String _chatSendMethod = 'SMS';

  // --- ПЕРЕМЕННЫЕ ДЛЯ КАРТЫ И ВРЕМЕНИ ---
  String _travelTime = '';
  bool _isLoadingTime = true;
  // ВСТАВЬ СЮДА СВОЙ КЛЮЧ API ОТ GOOGLE CLOUD
  final String _googleApiKey = 'AIzaSyC6hXV0m2BbnqFOf4vf_9tqZgMrRDgd58I';

  List<Map<String, dynamic>> _attachments = [
    {'url': 'https://picsum.photos/id/237/600/600', 'type': 'image'},
    {'url': 'https://picsum.photos/id/238/600/600', 'type': 'image'},
    {'url': 'https://picsum.photos/id/239/600/600', 'type': 'image'},
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (_tabController.index != 1 && _financeMode != 'main')
        setState(() => _financeMode = 'main');
    });

    _currentStatus = widget.jobData['status'] ?? 'Новая';
    _currentPriority = widget.jobData['priority'] ?? '🟢 Обычный';
    _currentDescription = widget.jobData['description'] ?? 'Нет описания';

    _hasJobSite = widget.jobData['hasJobSite'] == true;
    _jobSiteName = widget.jobData['jobSiteName'] ?? '';
    _jobSitePhone = widget.jobData['jobSitePhone'] ?? '';
    _jobSiteAddress = widget.jobData['jobSiteAddress'] ?? '';

    if (widget.jobData['documents'] != null)
      _documents = List<Map<String, dynamic>>.from(widget.jobData['documents']);

    // Запускаем расчет времени при открытии экрана
    _calculateTravelTime();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _chatController.dispose();
    super.dispose();
  }

  // Универсальный геттер для текущего адреса (Владелец или Арендатор)
  String get _computedAddress => _hasJobSite
      ? _jobSiteAddress
      : (widget.jobData['clientAddress'] ?? 'Не указан');

  // --- ЛОГИКА РАСЧЕТА ВРЕМЕНИ ЧЕРЕЗ GOOGLE API ---
  // --- ЛОГИКА РАСЧЕТА ВРЕМЕНИ ЧЕРЕЗ GOOGLE API ---
  Future<void> _calculateTravelTime() async {
    final destinationAddress = _computedAddress;

    // Оставили проверку только на пустоту адреса и ключа
    if (destinationAddress.isEmpty ||
        destinationAddress == 'Не указан' ||
        _googleApiKey.isEmpty) {
      print('ОШИБКА: Адрес пуст!');
      setState(() {
        _travelTime = 'GO';
        _isLoadingTime = false;
      });
      return;
    }

    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          print('ОШИБКА: Пользователь запретил доступ к GPS');
          setState(() {
            _travelTime = 'Нет GPS';
            _isLoadingTime = false;
          });
          return;
        }
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      final origin = '${position.latitude},${position.longitude}';
      final destination = Uri.encodeComponent(destinationAddress);

      final url =
          'https://maps.googleapis.com/maps/api/distancematrix/json?origins=$origin&destinations=$destination&language=ru&key=$_googleApiKey';

      print('--- ОТПРАВЛЯЮ ЗАПРОС К GOOGLE API ---');

      final response = await http.get(Uri.parse(url));

      print('--- ОТВЕТ ОТ GOOGLE: ---');
      print(response.body); // ВЫВОДИМ ОТВЕТ В КОНСОЛЬ

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'OK' &&
            data['rows'][0]['elements'][0]['status'] == 'OK') {
          // Получаем время
          final durationText =
              data['rows'][0]['elements'][0]['duration']['text'];
          setState(() {
            _travelTime = durationText;
            _isLoadingTime = false;
          });
        } else {
          print(
            'GOOGLE ВЕРНУЛ ОШИБКУ: Статус: ${data['status']}, Элемент: ${data['rows'][0]['elements'][0]['status']}',
          );
          setState(() {
            _travelTime = 'GO';
            _isLoadingTime = false;
          });
        }
      } else {
        print('ОШИБКА СЕРВЕРА GOOGLE: Код ${response.statusCode}');
        setState(() {
          _travelTime = 'GO';
          _isLoadingTime = false;
        });
      }
    } catch (e) {
      print('ВНУТРЕННЯЯ ОШИБКА ПРИЛОЖЕНИЯ: $e');
      setState(() {
        _travelTime = 'GO';
        _isLoadingTime = false;
      });
    }
  }

  Color _getPriorityColor() {
    if (_currentPriority.contains('Срочно')) return Colors.red;
    if (_currentPriority.contains('Средний')) return Colors.orange;
    return Colors.blue;
  }

  void _showPriorityMenu(BuildContext context) {
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
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text(
                  'Изменить приоритет',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.circle, color: Colors.red),
                title: const Text('Срочно (Горит)'),
                onTap: () {
                  _updatePriority('🔴 Срочно');
                  Navigator.pop(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.circle, color: Colors.orange),
                title: const Text('Средний (Затянул)'),
                onTap: () {
                  _updatePriority('🟡 Средний');
                  Navigator.pop(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.circle, color: Colors.blue),
                title: const Text('Обычный (В норме)'),
                onTap: () {
                  _updatePriority('🟢 Обычный');
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _updatePriority(String newPriority) {
    setState(() => _currentPriority = newPriority);
    FirebaseFirestore.instance
        .collection('companies')
        .doc('fix_appliance_ca')
        .collection('jobs')
        .doc(widget.jobId)
        .update({'priority': newPriority});
  }

  void _showStatusMenu() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        final statuses = [
          'Новая',
          'В ожидании',
          'Вызов',
          'В пути',
          'В работе',
          'Ожидание запчасти',
          'Депозит внесен',
          'Завершено',
          'Отменена',
        ];
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text(
                  'Изменить статус',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF14557F),
                  ),
                ),
              ),
              ...statuses
                  .map(
                    (s) => ListTile(
                      title: Text(
                        s,
                        style: TextStyle(
                          fontWeight: _currentStatus == s
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: _currentStatus == s
                              ? Colors.green
                              : (s == 'Отменена' ? Colors.red : Colors.black),
                        ),
                      ),
                      trailing: _currentStatus == s
                          ? const Icon(Icons.check, color: Colors.green)
                          : null,
                      onTap: () {
                        setState(() => _currentStatus = s);
                        FirebaseFirestore.instance
                            .collection('companies')
                            .doc('fix_appliance_ca')
                            .collection('jobs')
                            .doc(widget.jobId)
                            .update({'status': s});
                        Navigator.pop(context);
                      },
                    ),
                  )
                  .toList(),
            ],
          ),
        );
      },
    );
  }

  void _editDescription() {
    final descController = TextEditingController(text: _currentDescription);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Описание поломки'),
          content: TextField(
            controller: descController,
            maxLines: 4,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            ElevatedButton(
              onPressed: () {
                setState(
                  () => _currentDescription = descController.text.trim(),
                );
                FirebaseFirestore.instance
                    .collection('companies')
                    .doc('fix_appliance_ca')
                    .collection('jobs')
                    .doc(widget.jobId)
                    .update({'description': _currentDescription});
                Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFCC520),
                foregroundColor: Colors.black,
              ),
              child: const Text('Сохранить'),
            ),
          ],
        );
      },
    );
  }

  void _editContactDetails() {
    final nameCtrl = TextEditingController(
      text: _hasJobSite ? _jobSiteName : widget.jobData['clientName'],
    );
    final phoneCtrl = TextEditingController(
      text: _hasJobSite ? _jobSitePhone : widget.jobData['clientPhone'],
    );
    final addressCtrl = TextEditingController(
      text: _hasJobSite ? _jobSiteAddress : widget.jobData['clientAddress'],
    );
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text(
            'Связь на месте',
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
                  controller: addressCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Адрес',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Имя на месте',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Телефон',
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
                setState(() {
                  _hasJobSite = true;
                  _jobSiteName = nameCtrl.text.trim();
                  _jobSitePhone = phoneCtrl.text.trim();
                  _jobSiteAddress = addressCtrl.text.trim();
                  _isLoadingTime = true;
                });
                await FirebaseFirestore.instance
                    .collection('companies')
                    .doc('fix_appliance_ca')
                    .collection('jobs')
                    .doc(widget.jobId)
                    .update({
                      'hasJobSite': true,
                      'jobSiteName': _jobSiteName,
                      'jobSitePhone': _jobSitePhone,
                      'jobSiteAddress': _jobSiteAddress,
                    });
                _calculateTravelTime();
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

  void _showAddPhotoMenu() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Добавить медиа',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF14557F),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.camera_alt, color: Color(0xFF14557F)),
                title: const Text('Сделать снимок'),
                onTap: () {
                  Navigator.pop(context);
                  setState(
                    () => _attachments.add({
                      'url':
                          'https://picsum.photos/600/600?random=${DateTime.now().second}',
                      'type': 'image',
                    }),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library, color: Colors.green),
                title: const Text('Выбрать из галереи'),
                onTap: () {
                  Navigator.pop(context);
                  setState(
                    () => _attachments.add({
                      'url':
                          'https://picsum.photos/600/600?random=${DateTime.now().millisecond}',
                      'type': 'image',
                    }),
                  );
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
        builder: (context) =>
            FullScreenGallery(images: _attachments, initialIndex: initialIndex),
      ),
    );
  }

  Future<void> _saveDocumentsToFirestore() async {
    try {
      await FirebaseFirestore.instance
          .collection('companies')
          .doc('fix_appliance_ca')
          .collection('jobs')
          .doc(widget.jobId)
          .update({'documents': _documents});
    } catch (e) {}
  }

  double _calcSubtotal(List<dynamic> items) => items.fold(
    0.0,
    (sum, item) => sum + num.parse(item['price'].toString()).toDouble(),
  );
  double _calcTax(double subtotal, double rate) => subtotal * rate;
  double _calcTotal(double subtotal, double tax) => subtotal + tax;
  double _calcPaid(List<dynamic> payments) => payments.fold(
    0.0,
    (sum, item) => sum + num.parse(item['amount'].toString()).toDouble(),
  );
  double _calcDue(double total, double paid) =>
      (total - paid) < 0 ? 0 : (total - paid);

  Future<void> _makeCall(String phone) async {
    if (phone.isNotEmpty) {
      final Uri uri = Uri(scheme: 'tel', path: phone);
      if (await canLaunchUrl(uri)) await launchUrl(uri);
    }
  }

  // ФУНКЦИЯ: ОТКРЫТИЕ КАРТЫ (Запуск навигатора)
  Future<void> _openMap(String address) async {
    if (address.isEmpty || address == 'Не указан') return;
    final encodedAddress = Uri.encodeComponent(address);
    final Uri googleMapsUri = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=$encodedAddress',
    );
    if (await canLaunchUrl(googleMapsUri)) {
      await launchUrl(googleMapsUri, mode: LaunchMode.externalApplication);
    } else {
      final Uri appleMapsUri = Uri.parse(
        'https://maps.apple.com/?q=$encodedAddress',
      );
      if (await canLaunchUrl(appleMapsUri)) {
        await launchUrl(appleMapsUri, mode: LaunchMode.externalApplication);
      }
    }
  }

  Future<void> _sendQuickSms(
    String templateKey,
    String phone,
    String role,
  ) async {
    if (phone.isEmpty) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('companies')
          .doc('fix_appliance_ca')
          .collection('settings')
          .doc('sms_templates')
          .get();
      String message = (doc.exists && doc.data() != null)
          ? doc.data()![templateKey] ?? ''
          : '';
      if (message.isEmpty) return;
      final Uri smsUri = Uri.parse(
        'sms:$phone?body=${Uri.encodeComponent(message)}',
      );
      if (await canLaunchUrl(smsUri)) {
        await launchUrl(smsUri);
        _sendMessageToChat(message, 'SMS', role: role);
      }
    } catch (e) {}
  }

  void _showSmsTemplates(String phone, String role) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  'Отправить SMS ($role)',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(
                  Icons.directions_car,
                  color: Color(0xFF14557F),
                ),
                title: const Text('Я в пути'),
                onTap: () {
                  Navigator.pop(context);
                  _sendQuickSms('on_way', phone, role);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _sendMessageToChat(
    String text,
    String method, {
    String? attachmentUrl,
    required String role,
  }) async {
    if (text.trim().isEmpty && attachmentUrl == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('companies')
          .doc('fix_appliance_ca')
          .collection('jobs')
          .doc(widget.jobId)
          .collection('messages')
          .add({
            'text': text.trim(),
            'method': method,
            'sender': 'company',
            'targetRole': role,
            'attachmentUrl': attachmentUrl,
            'timestamp': FieldValue.serverTimestamp(),
          });
      _chatController.clear();
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Сохранено в чат ($role)'),
            backgroundColor: Colors.green,
          ),
        );
    } catch (e) {}
  }

  void _showSendOptionsSheet(
    String documentType,
    String targetName,
    String targetRole,
    int documentIndex,
  ) {
    final textController = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Отправка $documentType для $targetName ($targetRole)',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF14557F),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: textController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Дополнительный текст',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        _sendDocumentDirectly(
                          documentType,
                          targetName,
                          textController.text,
                          'SMS',
                          targetRole,
                          documentIndex,
                        );
                      },
                      icon: const Icon(Icons.sms),
                      label: const Text('SMS'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        _sendDocumentDirectly(
                          documentType,
                          targetName,
                          textController.text,
                          'Email',
                          targetRole,
                          documentIndex,
                        );
                      },
                      icon: const Icon(Icons.email),
                      label: const Text('Email'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 30),
            ],
          ),
        );
      },
    );
  }

  Future<void> _sendDocumentDirectly(
    String docType,
    String targetName,
    String additionalText,
    String method,
    String targetRole,
    int docIndex,
  ) async {
    final doc = _documents[docIndex];
    final total = _calcTotal(
      _calcSubtotal(doc['items']),
      _calcTax(_calcSubtotal(doc['items']), doc['taxRate']),
    );
    final paid = _calcPaid(doc['payments'] ?? []);
    final due = _calcDue(total, paid);
    String messageBody = "Здравствуйте, $targetName.\nВаш $docType готов.\n";
    if (docType == 'Invoice' || docType == 'Receipt') {
      messageBody +=
          "Итого: \$${total.toStringAsFixed(2)}\nОплачено: \$${paid.toStringAsFixed(2)}\n";
      if (due > 0)
        messageBody += "Остаток к оплате: \$${due.toStringAsFixed(2)}\n";
    } else {
      messageBody += "Оценочная стоимость: \$${total.toStringAsFixed(2)}\n";
    }
    if (additionalText.isNotEmpty) messageBody += "\n$additionalText\n";
    messageBody +=
        "\nСсылка на документ: https://fix-appliance.ca/doc/${widget.jobId}";
    await _sendMessageToChat(
      messageBody,
      method,
      attachmentUrl: "https://fix-appliance.ca/doc/${widget.jobId}",
      role: targetRole,
    );
    setState(() => _activeChatRole = targetRole);
    _tabController.animateTo(2);
  }

  void _askBillingDetailsAndProceed(String documentType, int documentIndex) {
    if (_hasJobSite) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('На кого выписать $documentType?'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _showSendOptionsSheet(
                  documentType,
                  _jobSiteName,
                  'Арендатор',
                  documentIndex,
                );
              },
              child: const Text(
                'На Арендатора',
                style: TextStyle(color: Colors.orange),
              ),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _showSendOptionsSheet(
                  documentType,
                  widget.jobData['clientName'],
                  'Владелец',
                  documentIndex,
                );
              },
              child: const Text('На Владельца'),
            ),
          ],
        ),
      );
    } else {
      _showSendOptionsSheet(
        documentType,
        widget.jobData['clientName'],
        'Владелец',
        documentIndex,
      );
    }
  }

  void _showPaymentSheet(int documentIndex) {
    final doc = _documents[documentIndex];
    final total = _calcTotal(
      _calcSubtotal(doc['items']),
      _calcTax(_calcSubtotal(doc['items']), doc['taxRate']),
    );
    final amountController = TextEditingController(
      text: _calcDue(
        total,
        _calcPaid(doc['payments'] ?? []),
      ).toStringAsFixed(2),
    );
    String localPaymentMethod = 'Наличные';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                left: 16,
                right: 16,
                top: 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Прием платежа',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF14557F),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: amountController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Сумма (\$)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton(
                        onPressed: () => setSheetState(
                          () => amountController.text = (total * 0.5)
                              .toStringAsFixed(2),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFCC520),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(
                            vertical: 20,
                            horizontal: 16,
                          ),
                        ),
                        child: const Text(
                          '50%',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    value: localPaymentMethod,
                    items: ['Наличные', 'Кредитная карта', 'E-Transfer', 'Чек']
                        .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                        .toList(),
                    onChanged: (val) =>
                        setSheetState(() => localPaymentMethod = val!),
                    decoration: const InputDecoration(
                      labelText: 'Методы оплаты',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () async {
                        final amountPaid =
                            double.tryParse(amountController.text) ?? 0.0;
                        if (amountPaid > 0) {
                          setState(() {
                            if (_documents[documentIndex]['payments'] == null) {
                              _documents[documentIndex]['payments'] = [];
                            }
                            _documents[documentIndex]['payments'].add({
                              'amount': amountPaid,
                              'method': localPaymentMethod,
                              'date': DateTime.now().toIso8601String(),
                            });
                          });
                          await _saveDocumentsToFirestore();
                        }
                        if (context.mounted) {
                          Navigator.pop(context);
                          _askBillingDetailsAndProceed(
                            _calcDue(
                                      total,
                                      _calcPaid(
                                        _documents[documentIndex]['payments'],
                                      ),
                                    ) ==
                                    0
                                ? 'Receipt'
                                : 'Invoice',
                            documentIndex,
                          );
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF14557F),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: const Text(
                        'Принять и Отправить',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _deleteJob() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить заявку?'),
        content: const Text(
          'Вы уверены? Эта работа и все инвойсы будут удалены.',
        ),
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
                  .collection('jobs')
                  .doc(widget.jobId)
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

  void _deleteDocument(int index) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить документ?'),
        content: const Text('Вы уверены? Это действие нельзя отменить.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () async {
              setState(() {
                _documents.removeAt(index);
                _financeMode = 'main';
              });
              await _saveDocumentsToFirestore();
              if (context.mounted) Navigator.pop(context);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF14557F),
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            GestureDetector(
              onTap: () => _showPriorityMenu(context),
              child: Container(
                width: 16,
                height: 16,
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  color: _getPriorityColor(),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
            Expanded(
              child: Text(
                '${widget.jobData['applianceType']} ${widget.jobData['brand']}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            tooltip: 'Удалить заявку',
            onPressed: _deleteJob,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFFFCC520),
          labelColor: const Color(0xFFFCC520),
          unselectedLabelColor: Colors.white,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold),
          tabs: const [
            Tab(text: 'ДЕТАЛИ'),
            Tab(text: 'ФИНАНСЫ'),
            Tab(text: 'ЧАТ'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildDetailsTab(), _buildFinanceTab(), _buildChatTab()],
      ),
    );
  }

  Widget _buildDetailsTab() {
    String currentContactName = _hasJobSite
        ? _jobSiteName
        : widget.jobData['clientName'] ?? 'Неизвестно';
    String currentContactPhone = _hasJobSite
        ? _jobSitePhone
        : widget.jobData['clientPhone'] ?? '';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 5,
                child: GestureDetector(
                  onTap: _showStatusMenu,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.blue.shade100),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Статус',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                _currentStatus,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF14557F),
                                  fontSize: 16,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const Icon(
                              Icons.arrow_drop_down,
                              color: Color(0xFF14557F),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 4,
                child: GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ClientDetailsScreen(
                          clientId: widget.clientId,
                          clientData: {
                            'name': widget.jobData['clientName'] ?? '',
                            'phone': widget.jobData['clientPhone'] ?? '',
                            'address': widget.jobData['clientAddress'] ?? '',
                          },
                        ),
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 10,
                      horizontal: 12,
                    ),
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
                          child: const Icon(
                            Icons.person,
                            size: 18,
                            color: Color(0xFF14557F),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            widget.jobData['clientName'] ?? 'Клиент',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
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

          // --- ОБНОВЛЕННАЯ УМНАЯ КНОПКА С ИКОНКОЙ ЛОКАЦИИ И ВРЕМЕНЕМ ---
          Row(
            children: [
              Expanded(
                flex: 6,
                child: ElevatedButton(
                  onPressed: () => _openMap(_computedAddress),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                    ), // Убрали лишнюю высоту
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.location_on, size: 24),
                      const SizedBox(width: 6),
                      // Показываем крутилку загрузки, пока ждем ответ от Google
                      _isLoadingTime
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : Text(
                              _travelTime,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 4,
                child: ElevatedButton(
                  onPressed: () => _makeCall(currentContactPhone),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF14557F),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text(
                    'CALL',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 4,
                child: ElevatedButton(
                  onPressed: () => _showSmsTemplates(
                    currentContactPhone,
                    _hasJobSite ? 'Арендатор' : 'Владелец',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFCC520),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text(
                    'SMS',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          GestureDetector(
            onTap: _editDescription,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Описание поломки:',
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Icon(Icons.edit, size: 14, color: Colors.grey),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _currentDescription.isEmpty
                        ? 'Нажмите, чтобы добавить описание...'
                        : _currentDescription,
                    style: TextStyle(
                      fontSize: 15,
                      color: _currentDescription.isEmpty
                          ? Colors.grey
                          : Colors.black,
                      fontStyle: _currentDescription.isEmpty
                          ? FontStyle.italic
                          : FontStyle.normal,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16), const Divider(),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Связь на месте',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              IconButton(
                icon: const Icon(
                  Icons.edit,
                  color: Color(0xFF14557F),
                  size: 20,
                ),
                onPressed: _editContactDetails,
              ),
            ],
          ),
          Text(
            'Адрес:',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
          ),
          Text(
            _computedAddress,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 8),

          Text(
            'Имя:',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
          ),
          Text(
            currentContactName,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 8),

          Text(
            'Телефон:',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
          ),
          Text(
            currentContactPhone,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
          ),
          const Divider(height: 32),

          const Text(
            'Фотографии и файлы',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),

          SizedBox(
            height: 90,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _attachments.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return GestureDetector(
                    onTap: _showAddPhotoMenu,
                    child: Container(
                      width: 90,
                      margin: const EdgeInsets.only(right: 12),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.grey.shade300,
                          width: 2,
                          style: BorderStyle.solid,
                        ),
                      ),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add_a_photo, color: Colors.grey, size: 30),
                          SizedBox(height: 4),
                          Text(
                            'Добавить',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.grey,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                final fileIndex = index - 1;
                final file = _attachments[fileIndex];
                return GestureDetector(
                  onTap: () => _openGallery(fileIndex),
                  child: Container(
                    width: 90,
                    margin: const EdgeInsets.only(right: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey.shade300),
                      image: DecorationImage(
                        image: NetworkImage(file['url']),
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _buildFinanceTab() {
    if (_financeMode == 'builder') return _buildDocumentBuilderView();
    if (_financeMode == 'view_document') return _buildDocumentDetailsView();
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_documents.isEmpty)
              const Expanded(
                child: Center(
                  child: Text(
                    'Нет созданных документов.\nНажмите (+) чтобы добавить.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              ),
            if (_documents.isNotEmpty) ...[
              const Text(
                'ДОКУМЕНТЫ',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: _documents.length,
                  itemBuilder: (context, index) {
                    final doc = _documents[index];
                    final type = doc['type'] ?? 'Invoice';
                    final isDocCancelled = doc['status'] == 'cancelled';
                    final subtotal = _calcSubtotal(doc['items'] ?? []);
                    final tax = _calcTax(subtotal, doc['taxRate'] ?? 0.0);
                    final total = _calcTotal(subtotal, tax);
                    final paid = _calcPaid(doc['payments'] ?? []);
                    final due = _calcDue(total, paid);

                    bool isEstimate = type == 'Estimate';
                    bool isPaid = !isEstimate && total > 0 && due == 0;
                    bool isPartiallyPaid = !isEstimate && paid > 0 && due > 0;

                    IconData docIcon;
                    Color docIconColor;
                    Color docBgColor;
                    String subtitleText;
                    Color subtitleColor;

                    if (isDocCancelled) {
                      docIcon = Icons.cancel;
                      docIconColor = Colors.red;
                      docBgColor = Colors.red.shade100;
                      subtitleText = 'Отменен';
                      subtitleColor = Colors.red;
                    } else if (isEstimate) {
                      docIcon = Icons.description;
                      docIconColor = const Color(0xFF14557F);
                      docBgColor = Colors.blue.shade50;
                      subtitleText = '\$${total.toStringAsFixed(2)}';
                      subtitleColor = Colors.black87;
                    } else if (isPaid) {
                      docIcon = Icons.check_circle;
                      docIconColor = Colors.green.shade800;
                      docBgColor = Colors.green.shade200;
                      subtitleText = 'Оплачен полностью';
                      subtitleColor = Colors.green.shade800;
                    } else if (isPartiallyPaid) {
                      docIcon = Icons.timelapse;
                      docIconColor = Colors.amber.shade800;
                      docBgColor = Colors.amber.shade200;
                      subtitleText = 'Остаток: \$${due.toStringAsFixed(2)}';
                      subtitleColor = Colors.amber.shade800;
                    } else {
                      docIcon = Icons.circle_outlined;
                      docIconColor = Colors.blue;
                      docBgColor = Colors.blue.shade100;
                      subtitleText = 'Неоплачен: \$${total.toStringAsFixed(2)}';
                      subtitleColor = Colors.blue;
                    }

                    Color cardBgColor = isDocCancelled
                        ? Colors.red.shade50
                        : (isEstimate
                              ? Colors.white
                              : (isPaid
                                    ? Colors.green.shade100
                                    : (isPartiallyPaid
                                          ? Colors.amber.shade50
                                          : Colors.white)));
                    Color cardBorderColor = isDocCancelled
                        ? Colors.red.shade300
                        : (isEstimate
                              ? Colors.grey.shade300
                              : (isPaid
                                    ? Colors.green.shade400
                                    : (isPartiallyPaid
                                          ? Colors.amber.shade400
                                          : Colors.blue.shade300)));

                    return Card(
                      elevation: isPaid && !isDocCancelled ? 2 : 0,
                      color: cardBgColor,
                      margin: const EdgeInsets.only(bottom: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: cardBorderColor,
                          width: isPaid ? 2.0 : 1.5,
                        ),
                      ),
                      child: ListTile(
                        leading: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: docBgColor,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(docIcon, color: docIconColor),
                        ),
                        title: Text(
                          isEstimate ? 'Estimate (Оценка)' : 'Invoice (Счет)',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          subtitleText,
                          style: TextStyle(
                            color: subtitleColor,
                            fontWeight: isEstimate
                                ? FontWeight.normal
                                : FontWeight.bold,
                          ),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          setState(() {
                            _viewingDocumentIndex = index;
                            _financeMode = 'view_document';
                          });
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          setState(() {
            _builderItems.clear();
            _builderTaxRate = 0.13;
            _financeMode = 'builder';
          });
        },
        backgroundColor: const Color(0xFFFCC520),
        child: const Icon(Icons.add, color: Colors.black, size: 28),
      ),
    );
  }

  Widget _buildDocumentBuilderView() {
    double subtotal = _calcSubtotal(_builderItems);
    double taxAmount = _calcTax(subtotal, _builderTaxRate);
    double grandTotal = _calcTotal(subtotal, taxAmount);
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Новый документ',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF14557F),
                ),
              ),
              TextButton.icon(
                onPressed: () => setState(() => _financeMode = 'main'),
                icon: const Icon(Icons.close),
                label: const Text('Отмена'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: () {
              String itemType = 'Услуга';
              final nameController = TextEditingController();
              final priceController = TextEditingController();
              showDialog(
                context: context,
                builder: (context) {
                  return StatefulBuilder(
                    builder: (context, setDialogState) {
                      return AlertDialog(
                        title: const Text(
                          'Добавить позицию',
                          style: TextStyle(
                            color: Color(0xFF14557F),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        content: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              DropdownButtonFormField<String>(
                                value: itemType,
                                items: ['Услуга', 'Запчасть']
                                    .map(
                                      (t) => DropdownMenuItem(
                                        value: t,
                                        child: Text(t),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (val) => setDialogState(() {
                                  itemType = val!;
                                }),
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                ),
                              ),
                              const SizedBox(height: 16),
                              TextField(
                                controller: nameController,
                                maxLines: 3,
                                minLines: 1,
                                decoration: const InputDecoration(
                                  labelText: 'Название / Описание',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: priceController,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                decoration: const InputDecoration(
                                  labelText: 'Цена (\$)',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ],
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Отмена'),
                          ),
                          ElevatedButton(
                            onPressed: () {
                              if (nameController.text.isNotEmpty &&
                                  priceController.text.isNotEmpty) {
                                setState(() {
                                  _builderItems.add({
                                    'type': itemType,
                                    'name': nameController.text.trim(),
                                    'price':
                                        double.tryParse(priceController.text) ??
                                        0.0,
                                  });
                                });
                                Navigator.pop(context);
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFFCC520),
                              foregroundColor: Colors.black,
                            ),
                            child: const Text('Добавить'),
                          ),
                        ],
                      );
                    },
                  );
                },
              );
            },
            icon: const Icon(Icons.add),
            label: const Text('Добавить позицию'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue.shade50,
              foregroundColor: const Color(0xFF14557F),
              minimumSize: const Size(double.infinity, 40),
              elevation: 0,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.builder(
              itemCount: _builderItems.length,
              itemBuilder: (context, index) {
                final item = _builderItems[index];
                return Card(
                  elevation: 1,
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    title: Text(item['name']),
                    subtitle: Text(item['type']),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '\$${item['price']}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.red,
                          ),
                          onPressed: () =>
                              setState(() => _builderItems.removeAt(index)),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const Divider(thickness: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Подытог:', style: TextStyle(color: Colors.grey)),
              Text(
                '\$${subtotal.toStringAsFixed(2)}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              DropdownButton<double>(
                value: _builderTaxRate,
                style: const TextStyle(
                  color: Color(0xFF14557F),
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
                items: const [
                  DropdownMenuItem(value: 0.13, child: Text('HST (13%)')),
                  DropdownMenuItem(value: 0.05, child: Text('GST (5%)')),
                  DropdownMenuItem(value: 0.0, child: Text('Без налога')),
                ],
                onChanged: (val) {
                  if (val != null) {
                    setState(() => _builderTaxRate = val);
                  }
                },
              ),
              Text(
                '\$${taxAmount.toStringAsFixed(2)}',
                style: const TextStyle(color: Colors.grey),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'ИТОГО:',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              Text(
                '\$${grandTotal.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: () async {
                    if (_builderItems.isNotEmpty) {
                      setState(() {
                        _documents.add({
                          'type': 'Invoice',
                          'status': 'active',
                          'taxRate': _builderTaxRate,
                          'items': List.from(_builderItems),
                          'payments': [],
                          'createdAt': DateTime.now().toIso8601String(),
                        });
                        _financeMode = 'main';
                      });
                      await _saveDocumentsToFirestore();
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF14557F),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text('СОЗДАТЬ INVOICE'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton(
                  onPressed: () async {
                    if (_builderItems.isNotEmpty) {
                      setState(() {
                        _documents.add({
                          'type': 'Estimate',
                          'taxRate': _builderTaxRate,
                          'items': List.from(_builderItems),
                          'createdAt': DateTime.now().toIso8601String(),
                        });
                        _financeMode = 'main';
                      });
                      await _saveDocumentsToFirestore();
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey.shade300,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text('СОЗДАТЬ ESTIMATE'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDocumentDetailsView() {
    if (_viewingDocumentIndex == null) return const SizedBox.shrink();
    final doc = _documents[_viewingDocumentIndex!];
    final type = doc['type'] ?? 'Invoice';
    final isDocCancelled = doc['status'] == 'cancelled';
    final items = doc['items'] as List<dynamic> ?? [];

    final subtotal = _calcSubtotal(items);
    final tax = _calcTax(subtotal, doc['taxRate'] ?? 0.0);
    final total = _calcTotal(subtotal, tax);
    final paid = _calcPaid(doc['payments'] ?? []);
    final due = _calcDue(total, paid);

    bool isEstimate = type == 'Estimate';
    bool isFullyPaid = !isEstimate && total > 0 && due == 0;

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                isDocCancelled
                    ? 'ОТМЕНЕН'
                    : (isEstimate
                          ? 'Estimate (Оценка)'
                          : (isFullyPaid
                                ? 'ЧЕК (ОПЛАЧЕНО)'
                                : 'Invoice (Счет)')),
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: isDocCancelled
                      ? Colors.red
                      : (isFullyPaid ? Colors.green : const Color(0xFF14557F)),
                ),
              ),
              Row(
                children: [
                  if (!isDocCancelled && !isEstimate)
                    IconButton(
                      icon: const Icon(Icons.block, color: Colors.orange),
                      tooltip: 'Отменить документ',
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: const Text('Отменить инвойс?'),
                            content: const Text(
                              'Он будет помечен как отмененный.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(c),
                                child: const Text('Нет'),
                              ),
                              ElevatedButton(
                                onPressed: () async {
                                  setState(() {
                                    _documents[_viewingDocumentIndex!]['status'] =
                                        'cancelled';
                                  });
                                  await _saveDocumentsToFirestore();
                                  if (context.mounted) Navigator.pop(c);
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.orange,
                                ),
                                child: const Text('Да'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  IconButton(
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Colors.redAccent,
                    ),
                    onPressed: () => _deleteDocument(_viewingDocumentIndex!),
                    tooltip: 'Удалить навсегда',
                  ),
                  TextButton.icon(
                    onPressed: () => setState(() => _financeMode = 'main'),
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('Назад'),
                  ),
                ],
              ),
            ],
          ),
          const Divider(),

          Expanded(
            child: ListView.builder(
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${item['name']}',
                        style: TextStyle(
                          decoration: isDocCancelled
                              ? TextDecoration.lineThrough
                              : null,
                          color: isDocCancelled ? Colors.grey : Colors.black,
                        ),
                      ),
                      Text(
                        '\$${item['price']}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          decoration: isDocCancelled
                              ? TextDecoration.lineThrough
                              : null,
                          color: isDocCancelled ? Colors.grey : Colors.black,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const Divider(thickness: 2),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Подытог:', style: TextStyle(color: Colors.grey)),
              Text(
                '\$${subtotal.toStringAsFixed(2)}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Налог (${((doc['taxRate'] ?? 0.0) * 100).toInt()}%):',
                style: const TextStyle(color: Colors.grey),
              ),
              Text(
                '\$${tax.toStringAsFixed(2)}',
                style: const TextStyle(color: Colors.grey),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                !isEstimate && isFullyPaid
                    ? 'ИТОГО ОПЛАЧЕНО:'
                    : (isEstimate ? 'ОЦЕНОЧНАЯ СТОИМОСТЬ:' : 'ИТОГО:'),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                '\$${total.toStringAsFixed(2)}',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: isDocCancelled
                      ? Colors.grey
                      : (isFullyPaid ? Colors.green : Colors.black),
                ),
              ),
            ],
          ),

          if (!isEstimate && paid > 0 && !isFullyPaid) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Оплачено (Депозит):',
                  style: TextStyle(
                    color: Colors.green,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '-\$${paid.toStringAsFixed(2)}',
                  style: const TextStyle(
                    color: Colors.green,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'ОСТАТОК К ОПЛАТЕ:',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.red,
                  ),
                ),
                Text(
                  '\$${due.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.red,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),

          if (!isDocCancelled) ...[
            if (isEstimate)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => _askBillingDetailsAndProceed(
                    'Estimate',
                    _viewingDocumentIndex!,
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF14557F),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text(
                    'ОТПРАВИТЬ ESTIMATE',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              )
            else if (isFullyPaid)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => _askBillingDetailsAndProceed(
                    'Receipt',
                    _viewingDocumentIndex!,
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text(
                    'ОТПРАВИТЬ ЧЕК КЛИЕНТУ',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              )
            else
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => _showPaymentSheet(_viewingDocumentIndex!),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: Text(
                    due > 0 && paid > 0
                        ? 'ПРИНЯТЬ ОСТАТОК (\$${due.toStringAsFixed(2)})'
                        : 'ПРИНЯТЬ ПЛАТЕЖ',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildChatTab() {
    return Column(
      children: [
        if (_hasJobSite)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            color: Colors.grey.shade100,
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'Владелец', label: Text('Владелец')),
                ButtonSegment(value: 'Арендатор', label: Text('Арендатор')),
              ],
              selected: {_activeChatRole},
              onSelectionChanged: (Set<String> newSelection) {
                setState(() {
                  _activeChatRole = newSelection.first;
                });
              },
            ),
          )
        else
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Colors.grey.shade200,
            child: const Text(
              'Чат с владельцем',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.black54,
              ),
            ),
          ),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('companies')
                .doc('fix_appliance_ca')
                .collection('jobs')
                .doc(widget.jobId)
                .collection('messages')
                .orderBy('timestamp', descending: true)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting)
                return const Center(child: CircularProgressIndicator());
              final allDocs = snapshot.data?.docs ?? [];
              final filteredMessages = allDocs.where((doc) {
                final msgRole = (doc.data() as Map)['targetRole'] ?? 'Владелец';
                return msgRole == _activeChatRole;
              }).toList();
              if (filteredMessages.isEmpty)
                return const Center(
                  child: Text(
                    'Нет сообщений.',
                    style: TextStyle(color: Colors.grey),
                  ),
                );
              return ListView.builder(
                reverse: true,
                padding: const EdgeInsets.all(16),
                itemCount: filteredMessages.length,
                itemBuilder: (context, index) {
                  final msg =
                      filteredMessages[index].data() as Map<String, dynamic>;
                  final isMe = msg['sender'] == 'company';
                  return Align(
                    alignment: isMe
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(12),
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.75,
                      ),
                      decoration: BoxDecoration(
                        color: isMe
                            ? const Color(0xFF14557F)
                            : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(12).copyWith(
                          bottomRight: isMe
                              ? const Radius.circular(0)
                              : const Radius.circular(12),
                          bottomLeft: !isMe
                              ? const Radius.circular(0)
                              : const Radius.circular(12),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (msg['method'] != null)
                            Text(
                              'Отправлено: ${msg['method']}',
                              style: TextStyle(
                                fontSize: 10,
                                color: isMe ? Colors.white70 : Colors.black54,
                              ),
                            ),
                          const SizedBox(height: 4),
                          Text(
                            msg['text'] ?? '',
                            style: TextStyle(
                              color: isMe ? Colors.white : Colors.black,
                              fontSize: 15,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black12,
                blurRadius: 4,
                offset: Offset(0, -2),
              ),
            ],
          ),
          child: Row(
            children: [
              GestureDetector(
                onTap: () {
                  setState(() {
                    _chatSendMethod = _chatSendMethod == 'SMS'
                        ? 'Email'
                        : 'SMS';
                  });
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: _chatSendMethod == 'SMS'
                        ? Colors.green
                        : Colors.blue,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _chatSendMethod == 'SMS' ? Icons.sms : Icons.email,
                        color: Colors.white,
                        size: 18,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _chatSendMethod,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _chatController,
                  decoration: InputDecoration(
                    hintText: '$_chatSendMethod для: $_activeChatRole...',
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: Colors.grey.shade100,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              CircleAvatar(
                backgroundColor: const Color(0xFFFCC520),
                radius: 24,
                child: IconButton(
                  icon: const Icon(Icons.send, color: Colors.black),
                  onPressed: () {
                    if (_chatController.text.trim().isNotEmpty)
                      _sendMessageToChat(
                        _chatController.text,
                        _chatSendMethod,
                        role: _activeChatRole,
                      );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class FullScreenGallery extends StatelessWidget {
  final List<Map<String, dynamic>> images;
  final int initialIndex;

  const FullScreenGallery({
    super.key,
    required this.images,
    required this.initialIndex,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: PageView.builder(
        controller: PageController(initialPage: initialIndex),
        itemCount: images.length,
        itemBuilder: (context, index) {
          return InteractiveViewer(
            minScale: 1.0,
            maxScale: 4.0,
            child: Center(
              child: Image.network(
                images[index]['url'],
                fit: BoxFit.contain,
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) return child;
                  return const Center(
                    child: CircularProgressIndicator(color: Color(0xFFFCC520)),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}
