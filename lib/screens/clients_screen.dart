import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'client_details_screen.dart';

class ClientsScreen extends StatefulWidget {
  const ClientsScreen({super.key});

  @override
  State<ClientsScreen> createState() => _ClientsScreenState();
}

class _ClientsScreenState extends State<ClientsScreen> {
  String _searchQuery = '';
  String _sortMethod = 'Имя (А-Я)';

  final ScrollController _scrollController = ScrollController();

  void _showAddClientDialog() {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final addressCtrl = TextEditingController();
    final companyCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text(
            'Новый клиент',
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
                  controller: nameCtrl,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Имя / Контактное лицо',
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
                const SizedBox(height: 12),
                // --- УМНОЕ ПОЛЕ АДРЕСА ---
                TextField(
                  controller: addressCtrl,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Адрес',
                    hintText: 'Начните вводить адрес...',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.location_on, color: Colors.grey),
                    suffixIcon: Icon(Icons.search, color: Color(0xFF14557F)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: companyCtrl,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Название компании (опционально)',
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
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFCC520),
                foregroundColor: Colors.black,
              ),
              onPressed: () async {
                if (nameCtrl.text.trim().isNotEmpty) {
                  await FirebaseFirestore.instance
                      .collection('companies')
                      .doc('fix_appliance_ca')
                      .collection('clients')
                      .add({
                        'name': nameCtrl.text.trim(),
                        'phone': phoneCtrl.text.trim(),
                        'address': addressCtrl.text.trim(),
                        'company': companyCtrl.text.trim(),
                        'createdAt': FieldValue.serverTimestamp(),
                        'lastActiveAt': FieldValue.serverTimestamp(),
                      });
                  if (context.mounted) Navigator.pop(context);
                }
              },
              child: const Text(
                'Создать',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
  }

  // --- УНИВЕРСАЛЬНАЯ ФУНКЦИЯ ДЛЯ ПОИСКА ИМЕНИ ---
  String _extractClientName(Map<String, dynamic> data) {
    if (data['name'] != null && data['name'].toString().trim().isNotEmpty) {
      return data['name'].toString().trim();
    }
    if (data['clientName'] != null &&
        data['clientName'].toString().trim().isNotEmpty) {
      return data['clientName'].toString().trim();
    }
    if (data['fullName'] != null &&
        data['fullName'].toString().trim().isNotEmpty) {
      return data['fullName'].toString().trim();
    }
    return 'Без имени';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        backgroundColor: const Color(0xFF14557F),
        foregroundColor: Colors.white,
        elevation: 0,
        title: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: _sortMethod,
            dropdownColor: const Color(0xFF14557F),
            icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
            items: ['Имя (А-Я)', 'Сначала новые', 'Последние активные'].map((
              String value,
            ) {
              return DropdownMenuItem<String>(value: value, child: Text(value));
            }).toList(),
            onChanged: (newValue) {
              if (newValue != null) {
                setState(() {
                  _sortMethod = newValue;
                });
              }
            },
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add, color: Colors.white, size: 28),
            tooltip: 'Добавить клиента',
            onPressed: _showAddClientDialog,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Поиск по имени, компании или телефону...',
                prefixIcon: const Icon(Icons.search, color: Colors.grey),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (val) {
                setState(() {
                  _searchQuery = val.toLowerCase();
                });
              },
            ),
          ),

          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('companies')
                  .doc('fix_appliance_ca')
                  .collection('clients')
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: Color(0xFFFCC520)),
                  );
                }
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return const Center(
                    child: Text(
                      'Список клиентов пуст.\nНажмите (+) чтобы добавить.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  );
                }

                List<Map<String, dynamic>> clients = snapshot.data!.docs.map((
                  doc,
                ) {
                  var data = doc.data() as Map<String, dynamic>;
                  data['id'] = doc.id;
                  data['display_name'] = _extractClientName(data);
                  return data;
                }).toList();

                if (_searchQuery.isNotEmpty) {
                  clients = clients.where((data) {
                    final name = data['display_name'].toString().toLowerCase();
                    final company = (data['company'] ?? '')
                        .toString()
                        .toLowerCase();
                    final phone = (data['phone'] ?? '')
                        .toString()
                        .toLowerCase();
                    return name.contains(_searchQuery) ||
                        phone.contains(_searchQuery) ||
                        company.contains(_searchQuery);
                  }).toList();
                }

                if (_sortMethod == 'Имя (А-Я)') {
                  clients.sort(
                    (a, b) => a['display_name'].toString().compareTo(
                      b['display_name'].toString(),
                    ),
                  );
                } else if (_sortMethod == 'Сначала новые') {
                  clients.sort((a, b) {
                    Timestamp? timeA = a['createdAt'] as Timestamp?;
                    Timestamp? timeB = b['createdAt'] as Timestamp?;
                    if (timeA == null) return 1;
                    if (timeB == null) return -1;
                    return timeB.compareTo(timeA);
                  });
                } else if (_sortMethod == 'Последние активные') {
                  clients.sort((a, b) {
                    Timestamp? timeA =
                        (a['lastActiveAt'] ?? a['createdAt']) as Timestamp?;
                    Timestamp? timeB =
                        (b['lastActiveAt'] ?? b['createdAt']) as Timestamp?;
                    if (timeA == null) return 1;
                    if (timeB == null) return -1;
                    return timeB.compareTo(timeA);
                  });
                }

                List<String> letters = [];
                Map<String, int> letterIndexes = {};

                if (_sortMethod == 'Имя (А-Я)' && _searchQuery.isEmpty) {
                  for (int i = 0; i < clients.length; i++) {
                    String name = clients[i]['display_name'];
                    if (name.isNotEmpty && name != 'Без имени') {
                      String firstLetter = name[0].toUpperCase();
                      if (!letterIndexes.containsKey(firstLetter)) {
                        letterIndexes[firstLetter] = i;
                        letters.add(firstLetter);
                      }
                    }
                  }
                }

                return Stack(
                  children: [
                    ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.only(
                        left: 16,
                        right: 32,
                        bottom: 20,
                      ),
                      itemCount: clients.length,
                      itemExtent: 80.0,
                      itemBuilder: (context, index) {
                        final data = clients[index];
                        final name = data['display_name'];
                        final company = data['company'] ?? '';
                        final phone = data['phone'] ?? 'Нет телефона';

                        return Container(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Card(
                            elevation: 0,
                            margin: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(color: Colors.grey.shade300),
                            ),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: Colors.blue.shade50,
                                child: Text(
                                  name != 'Без имени'
                                      ? name[0].toUpperCase()
                                      : '?',
                                  style: const TextStyle(
                                    color: Color(0xFF14557F),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18,
                                  ),
                                ),
                              ),
                              title: Text(
                                name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              subtitle: Text(
                                company.isNotEmpty
                                    ? '$company • $phone'
                                    : phone,
                                style: TextStyle(color: Colors.grey.shade600),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: const Icon(
                                Icons.chevron_right,
                                color: Colors.grey,
                              ),
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => ClientDetailsScreen(
                                      clientId: data['id'],
                                      clientData: data,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        );
                      },
                    ),

                    if (letters.isNotEmpty)
                      Align(
                        alignment: Alignment.centerRight,
                        child: Container(
                          width: 24,
                          margin: const EdgeInsets.only(right: 4),
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: letters.map((letter) {
                                return GestureDetector(
                                  onTap: () {
                                    int targetIndex = letterIndexes[letter]!;
                                    _scrollController.animateTo(
                                      targetIndex * 80.0,
                                      duration: const Duration(
                                        milliseconds: 300,
                                      ),
                                      curve: Curves.easeInOut,
                                    );
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 2.0,
                                    ),
                                    child: Text(
                                      letter,
                                      style: const TextStyle(
                                        color: Color(0xFF14557F),
                                        fontWeight: FontWeight.bold,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
