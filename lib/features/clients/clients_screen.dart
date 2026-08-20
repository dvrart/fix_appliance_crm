import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../core/constants.dart';
import '../../core/ui_scale.dart';
import '../../models/client.dart';
import '../../services/catalog_service.dart';
import '../../shared/widgets/keyboard_safe.dart';
import '../../shared/widgets/phone_client_matches.dart';
import '../../widgets/smart_address_picker.dart';
import 'client_details_screen.dart';
import '../../core/l10n/app_locale.dart';
import '../../services/import_export_service.dart';
import '../../services/client_service.dart';
import '../../shared/widgets/alphabet_index_bar.dart';
import '../../shared/widgets/animated_app_logo.dart';
import '../../shared/widgets/email_field.dart';
import 'clients_map_screen.dart';
import 'clients_duplicates_screen.dart';

class ClientsScreen extends StatefulWidget {
  const ClientsScreen({super.key});

  @override
  State<ClientsScreen> createState() => _ClientsScreenState();
}

class _ClientsScreenState extends State<ClientsScreen> {
  String _searchQuery = '';
  String _sortMethod = 'Имя (А-Я)';
  bool _selecting = false;
  final Set<String> _selectedIds = {};
  List<String> _visibleIds = [];
  List<Map<String, dynamic>> _latestClients = [];

  final ScrollController _scrollController = ScrollController();

  void _openMap() {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(builder: (_) => const ClientsMapScreen()),
    );
  }

  void _enterSelect({String? id, bool all = false}) {
    setState(() {
      _selecting = true;
      if (all) {
        _selectedIds
          ..clear()
          ..addAll(_visibleIds);
      } else if (id != null) {
        _selectedIds.add(id);
      }
    });
  }

  void _exitSelect() {
    setState(() {
      _selecting = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelect(String id) {
    setState(() {
      if (!_selectedIds.add(id)) _selectedIds.remove(id);
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (context) => AlertDialog(
        title: Text('Удалить клиентов?'.tr),
        content: Text(
          '${_selectedIds.length} ${'выбрано'.tr}\n\n${'Карточки будут удалены. Заявки в календаре останутся.'.tr}',
        ),
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
    await ClientService.deleteMany(_selectedIds);
    if (!mounted) return;
    _exitSelect();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Клиенты удалены'.tr),
        backgroundColor: Colors.red,
      ),
    );
  }

  void _openDuplicates() {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => ClientsDuplicatesScreen(clients: _latestClients),
      ),
    );
  }

  void _showAddClientDialog() {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final streetCtrl = TextEditingController();
    final cityCtrl = TextEditingController();
    final postalCtrl = TextEditingController();
    final companyCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    String source = '';
    Timer? phoneDebounce;
    var phoneMatches = <Client>[];
    var phoneSearching = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
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
                          'Новый клиент'.tr,
                          style: TextStyle(
                            fontSize: 22,
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
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TextField(
                              controller: nameCtrl,
                              textCapitalization: TextCapitalization.words,
                              decoration: InputDecoration(
                                labelText: 'Имя / Контактное лицо'.tr,
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.person),
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: phoneCtrl,
                              keyboardType: TextInputType.phone,
                              decoration: InputDecoration(
                                labelText: 'Телефон'.tr,
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.phone),
                                suffixIcon: phoneSearching
                                    ? const Padding(
                                        padding: EdgeInsets.all(12),
                                        child: SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(strokeWidth: 2),
                                        ),
                                      )
                                    : null,
                              ),
                              onChanged: (value) {
                                phoneDebounce?.cancel();
                                final digits = ClientService.normalizePhone(value);
                                if (digits.length < 7) {
                                  setSheetState(() {
                                    phoneMatches = [];
                                    phoneSearching = false;
                                  });
                                  return;
                                }
                                setSheetState(() => phoneSearching = true);
                                phoneDebounce = Timer(
                                  const Duration(milliseconds: 350),
                                  () async {
                                    final found =
                                        await ClientService.searchByPhone(value);
                                    if (!sheetContext.mounted) return;
                                    setSheetState(() {
                                      phoneMatches = found;
                                      phoneSearching = false;
                                    });
                                  },
                                );
                              },
                            ),
                            PhoneClientMatches(
                              clients: phoneMatches,
                              onSelect: (client) {
                                phoneDebounce?.cancel();
                                Navigator.pop(sheetContext);
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ClientDetailsScreen(
                                      clientId: client.id,
                                      clientData: client.toUiMap(),
                                    ),
                                  ),
                                );
                              },
                            ),
                            const SizedBox(height: 16),

                            // --- УМНЫЙ ПОИСК АДРЕСА (как в create_job_screen) ---
                            Text(
                              'АДРЕС'.tr,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey,
                              ),
                            ),
                            const SizedBox(height: 8),
                            GestureDetector(
                              onTap: () {
                                showSmartAddressPicker(
                                  context: context,
                                  initialStreet: streetCtrl.text,
                                  initialCity: cityCtrl.text,
                                  initialPostal: postalCtrl.text,
                                  onSaved: (street, city, postal) {
                                    setSheetState(() {
                                      streetCtrl.text = street;
                                      cityCtrl.text = city;
                                      postalCtrl.text = postal;
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
                                        cityCtrl.text.isEmpty
                                            ? 'Нажмите, чтобы ввести адрес...'.tr
                                            : '${streetCtrl.text}, ${cityCtrl.text}',
                                        style: TextStyle(
                                          color: cityCtrl.text.isEmpty
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
                              controller: emailCtrl,
                              decoration: InputDecoration(
                                labelText: 'Электронный адрес'.tr,
                                border: const OutlineInputBorder(),
                                prefixIcon: const Icon(Icons.email_outlined),
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: notesCtrl,
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
                            const SizedBox(height: 12),
                            TextField(
                              controller: companyCtrl,
                              textCapitalization: TextCapitalization.words,
                              decoration: InputDecoration(
                                labelText: 'Название компании (опционально)'.tr,
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.business),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // Кнопка создания
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () async {
                          if (nameCtrl.text.trim().isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Укажите имя клиента'.tr),
                                backgroundColor: Colors.red,
                              ),
                            );
                            return;
                          }
                          final phone = phoneCtrl.text.trim();
                          final existing = phone.isEmpty
                              ? const <Client>[]
                              : (phoneMatches.isNotEmpty
                                  ? phoneMatches
                                  : await ClientService.searchByPhone(phone));
                          if (existing.isNotEmpty) {
                            final client = existing.first;
                            final open = await showDialog<bool>(
                              context: context,
                              useRootNavigator: true,
                              builder: (context) => AlertDialog(
                                title: Text('Клиент с этим номером уже есть'.tr),
                                content: Text(
                                  '${client.fullName.isEmpty ? 'Без имени'.tr : client.fullName}\n${client.phone}\n\n${'Открыть карточку?'.tr}',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context, false),
                                    child: Text('Отмена'.tr),
                                  ),
                                  ElevatedButton(
                                    onPressed: () => Navigator.pop(context, true),
                                    child: Text('Открыть'.tr),
                                  ),
                                ],
                              ),
                            );
                            if (open == true && context.mounted) {
                              if (sheetContext.mounted) Navigator.pop(sheetContext);
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ClientDetailsScreen(
                                    clientId: client.id,
                                    clientData: client.toUiMap(),
                                  ),
                                ),
                              );
                            }
                            return;
                          }
                          final fullAddress =
                              '${streetCtrl.text}, ${cityCtrl.text}, ${postalCtrl.text}';
                          await FirebaseFirestore.instance
                              .collection('companies')
                              .doc(kCompanyId)
                              .collection('clients')
                              .add({
                                'name': nameCtrl.text.trim(),
                                'fullName': nameCtrl.text.trim(),
                                'phone': phone,
                                'address': fullAddress.trim(),
                                'company': companyCtrl.text.trim(),
                                'companyName': companyCtrl.text.trim(),
                                'email': emailCtrl.text.trim(),
                                'notes': notesCtrl.text.trim(),
                                'source': source,
                                'createdAt': FieldValue.serverTimestamp(),
                                'lastActiveAt': FieldValue.serverTimestamp(),
                              });
                          ClientService.invalidateCache();
                          if (sheetContext.mounted) Navigator.pop(sheetContext);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFCC520),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          'СОЗДАТЬ КЛИЕНТА'.tr,
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
    ).whenComplete(() => phoneDebounce?.cancel());
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
    return ListenableBuilder(
      listenable: AppUiSettings.instance,
      builder: (context, _) {
        return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        automaticallyImplyLeading: false,
        leading: _selecting
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Отмена'.tr,
                onPressed: _exitSelect,
              )
            : null,
        title: _selecting
            ? Text('${_selectedIds.length} ${'выбрано'.tr}')
            : Align(
                alignment: Alignment.centerLeft,
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _sortMethod,
                    isDense: true,
                    dropdownColor: AppColors.primary,
                    icon: const SizedBox.shrink(),
                    iconSize: 0,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                    items: ['Имя (А-Я)', 'Сначала новые', 'Последние активные']
                        .map((String value) {
                      return DropdownMenuItem<String>(
                        value: value,
                        child: Text(trAny(value)),
                      );
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
              ),
        actions: _selecting
            ? [
                IconButton(
                  tooltip: 'Выбрать все'.tr,
                  onPressed: () {
                    setState(() {
                      _selectedIds
                        ..clear()
                        ..addAll(_visibleIds);
                    });
                  },
                  icon: const Icon(Icons.select_all),
                ),
                IconButton(
                  tooltip: 'Удалить'.tr,
                  onPressed: _selectedIds.isEmpty ? null : _deleteSelected,
                  icon: const Icon(Icons.delete_outline),
                ),
              ]
            : [
          IconButton(
            tooltip: 'Клиенты на карте'.tr,
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 40),
            icon: const Icon(Icons.map_outlined, color: Colors.white),
            onPressed: _openMap,
          ),
          PopupMenuButton<String>(
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: (value) async {
              if (value == 'import') {
                final messenger = ScaffoldMessenger.of(context);
                final result = await ImportExportService.importFromFile();
                if (!mounted || (result.error != null && result.error!.isEmpty)) {
                  return;
                }
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(result.summary),
                    backgroundColor:
                        result.error == null ? Colors.green : Colors.red,
                  ),
                );
              } else if (value == 'matches') {
                _openDuplicates();
              } else if (value == 'select') {
                _enterSelect();
              } else if (value == 'select_all') {
                _enterSelect(all: true);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'import',
                child: Text('Импорт клиентов'.tr),
              ),
              PopupMenuItem(
                value: 'matches',
                child: Text('Найти совпадения'.tr),
              ),
              PopupMenuItem(
                value: 'select',
                child: Text('Выбрать'.tr),
              ),
              PopupMenuItem(
                value: 'select_all',
                child: Text('Выбрать все'.tr),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.add, color: Colors.white, size: 28),
            tooltip: 'Добавить клиента'.tr,
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
                hintText: 'Поиск по имени, компании или телефону...'.tr,
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
                  .doc(kCompanyId)
                  .collection('clients')
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const AppLoading();
                }
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return Center(
                    child: Text(
                      'Список клиентов пуст.\nНажмите (+) чтобы добавить.'.tr,
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
                  final phoneDigits =
                      ClientService.normalizePhone(_searchQuery);
                  clients = clients.where((data) {
                    final name = data['display_name'].toString().toLowerCase();
                    final company = (data['company'] ?? '')
                        .toString()
                        .toLowerCase();
                    final phone = (data['phone'] ?? '').toString();
                    final email = (data['email'] ?? '').toString().toLowerCase();
                    final phoneHit = phoneDigits.length >= 3 &&
                        ClientService.queryMatchesPhone(phone, _searchQuery);
                    return name.contains(_searchQuery) ||
                        phoneHit ||
                        company.contains(_searchQuery) ||
                        email.contains(_searchQuery);
                  }).toList();
                }

                if (_sortMethod == 'Имя (А-Я)') {
                  clients.sort((a, b) {
                    final left = a['display_name'].toString().toLowerCase();
                    final right = b['display_name'].toString().toLowerCase();
                    return left.compareTo(right);
                  });
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

                _latestClients = clients;
                _visibleIds = clients.map((c) => c['id'] as String).toList();

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
                        final name = (data['display_name'] as String?) ?? 'Без имени';
                        final company = (data['company'] as String?) ?? '';
                        final phone = ((data['phone'] as String?) ?? '').trim().isEmpty
                            ? 'Нет телефона'.tr
                            : (data['phone'] as String).trim();

                        return Container(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Card(
                            elevation: 0,
                            margin: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(
                                color: _selecting &&
                                        _selectedIds.contains(data['id'])
                                    ? AppColors.primary
                                    : Colors.grey.shade300,
                                width: _selecting &&
                                        _selectedIds.contains(data['id'])
                                    ? 2
                                    : 1,
                              ),
                            ),
                            child: ListTile(
                              leading: _selecting
                                  ? Checkbox(
                                      value: _selectedIds.contains(data['id']),
                                      activeColor: AppColors.primary,
                                      onChanged: (_) =>
                                          _toggleSelect(data['id'] as String),
                                    )
                                  : CircleAvatar(
                                backgroundColor: Colors.blue.shade50,
                                child: Text(
                                  name != 'Без имени'
                                      ? name[0].toUpperCase()
                                      : '?',
                                  style: TextStyle(
                                    color: AppColors.primary,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18,
                                  ),
                                ),
                              ),
                              title: Text(
                                name == 'Без имени' ? 'Без имени'.tr : name,
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
                              trailing: _selecting
                                  ? null
                                  : const Icon(
                                      Icons.chevron_right,
                                      color: Colors.grey,
                                    ),
                              onLongPress: () {
                                if (!_selecting) {
                                  _enterSelect(id: data['id'] as String);
                                }
                              },
                              onTap: () {
                                if (_selecting) {
                                  _toggleSelect(data['id'] as String);
                                  return;
                                }
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
                      Positioned(
                        right: 0,
                        top: 8,
                        bottom: 8,
                        width: 40,
                        child: AlphabetIndexBar(
                          letters: letters,
                          onLetter: (letter) {
                            final targetIndex = letterIndexes[letter];
                            if (targetIndex == null) return;
                            if (!_scrollController.hasClients) return;
                            final max = _scrollController.position.maxScrollExtent;
                            _scrollController.jumpTo(
                              (targetIndex * 80.0).clamp(0.0, max),
                            );
                          },
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
      },
    );
  }
}
