import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../core/app_commands.dart';
import '../../core/app_feedback.dart';
import '../../core/constants.dart';
import '../../shared/widgets/confirm_action_sheet.dart';
import '../../shared/widgets/unsaved_changes_dialog.dart';
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
import '../../shared/widgets/selection_action_bar.dart';
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
  final ValueNotifier<Set<String>?> _selected = ValueNotifier<Set<String>?>(null);
  List<String> _visibleIds = [];
  List<Map<String, dynamic>> _latestClients = [];

  final ScrollController _scrollController = ScrollController();
  late final Stream<QuerySnapshot> _clientsStream;
  late final bool Function() _dismissSelection;

  @override
  void initState() {
    super.initState();
    _clientsStream = FirebaseFirestore.instance
        .collection('companies')
        .doc(kCompanyId)
        .collection('clients')
        .snapshots();
    _dismissSelection = () {
      if (_selected.value == null) return false;
      _exitSelect();
      return true;
    };
    AppCommands.addSelectionGuard(_dismissSelection);
  }

  @override
  void dispose() {
    AppCommands.removeSelectionGuard(_dismissSelection);
    _selected.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _setSelected(Set<String>? next) => _selected.value = next;

  void _openMap() {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(builder: (_) => const ClientsMapScreen()),
    );
  }

  void _enterSelect({String? id, bool all = false}) {
    if (all) {
      _setSelected({..._visibleIds});
      return;
    }
    final current = Set<String>.from(_selected.value ?? {});
    if (id != null) current.add(id);
    _setSelected(current);
  }

  void _exitSelect() => _setSelected(null);

  void _toggleSelect(String id) {
    final next = Set<String>.from(_selected.value ?? {});
    if (!next.add(id)) next.remove(id);
    _setSelected(next);
  }

  Future<void> _deleteSelected() async {
    final ids = _selected.value;
    if (ids == null || ids.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (context) => AlertDialog(
        title: Text('Удалить клиентов?'.tr),
        content: Text(
          '${ids.length} ${'выбрано'.tr}\n\n${'Карточки будут удалены. Заявки в календаре останутся.'.tr}',
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
    await ClientService.deleteMany(ids);
    if (!mounted) return;
    _exitSelect();
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

    bool isDirty() {
      return nameCtrl.text.trim().isNotEmpty ||
          phoneCtrl.text.trim().isNotEmpty ||
          streetCtrl.text.trim().isNotEmpty ||
          cityCtrl.text.trim().isNotEmpty ||
          postalCtrl.text.trim().isNotEmpty ||
          companyCtrl.text.trim().isNotEmpty ||
          emailCtrl.text.trim().isNotEmpty ||
          notesCtrl.text.trim().isNotEmpty ||
          source.trim().isNotEmpty;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (builderContext, setSheetState) {
            Future<bool> saveClient() async {
              if (nameCtrl.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Укажите имя клиента'.tr),
                    backgroundColor: Colors.red,
                  ),
                );
                return false;
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
                return false;
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
              AppCommands.reactHappy();
              if (sheetContext.mounted) Navigator.pop(sheetContext);
              return true;
            }

            Future<void> requestClose() async {
              if (!isDirty()) {
                if (sheetContext.mounted) Navigator.pop(sheetContext);
                return;
              }
              final action = await showUnsavedChangesDialog(
                sheetContext,
                title: 'Сохранить клиента?'.tr,
              );
              if (!sheetContext.mounted) return;
              if (action == UnsavedChangesAction.save) {
                await saveClient();
              } else if (action == UnsavedChangesAction.discard) {
                Navigator.pop(sheetContext);
              }
            }

            return PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, result) {
                if (!didPop) requestClose();
              },
              child: KeyboardAvoidingSheet(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Заголовок
                    Text(
                      'Новый клиент'.tr,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: 16),

                    TextField(
                      controller: nameCtrl,
                      textCapitalization: TextCapitalization.words,
                      decoration: InputDecoration(
                        labelText: 'Имя / Контактное лицо'.tr,
                        helperText: 'Имя на английском'.tr,
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.person),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: phoneCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                        labelText: 'Телефон'.tr,
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.phone),
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
                    if (phoneMatches.isNotEmpty)
                      Expanded(
                        child: ListView(
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          children: [
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
                          ],
                        ),
                      )
                    else
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
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
                                  onSaved: (street, city, postal, unit) {
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
                            onTap: () => saveClient(),
                          ),
                          RoundActionButton(
                            color: const Color(0xFFE53935),
                            icon: Icons.close_rounded,
                            tooltip: 'Удалить'.tr,
                            size: 72,
                            onTap: requestClose,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
            ),
            );
          },
        );
      },
    ).whenComplete(() => phoneDebounce?.cancel());
  }

  Widget _buildClientTile(
    Map<String, dynamic> data,
    bool selected,
    bool selecting,
  ) {
    final name = (data['display_name'] as String?) ?? 'Без имени';
    final company = (data['company'] as String?) ?? '';
    final phone = ((data['phone'] as String?) ?? '').trim().isEmpty
        ? 'Нет телефона'.tr
        : (data['phone'] as String).trim();
    final avatar = CircleAvatar(
      backgroundColor: Colors.blue.shade50,
      child: Text(
        name != 'Без имени' ? name[0].toUpperCase() : '?',
        style: TextStyle(
          color: AppColors.primary,
          fontWeight: FontWeight.bold,
          fontSize: 18,
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? const Color(0xFFE8EEF4) : Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected ? AppColors.primary : const Color(0xFFBBDEFB),
            width: selected ? 2 : 1,
          ),
        ),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: () {
            if (!selecting) _enterSelect(id: data['id'] as String);
          },
          onTap: () {
            if (selecting) {
              _toggleSelect(data['id'] as String);
              return;
            }
            AppFeedback.pleasant();
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
          child: SizedBox(
            height: 72,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        avatar,
                        Positioned(
                          left: -10,
                          top: -8,
                          child: Opacity(
                            opacity: selecting ? 1 : 0,
                            child: SelectCheckbox(selected: selected),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name == 'Без имени' ? 'Без имени'.tr : name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          company.isNotEmpty ? '$company • $phone' : phone,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: Colors.grey),
                ],
              ),
            ),
          ),
        ),
      ),
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
    return ListenableBuilder(
      listenable: AppUiSettings.instance,
      builder: (context, _) {
        return Scaffold(
      backgroundColor: Colors.grey.shade100,
      floatingActionButton: ValueListenableBuilder<Set<String>?>(
        valueListenable: _selected,
        builder: (context, selected, _) {
          if (selected != null) return const SizedBox.shrink();
          return FloatingActionButton(
            heroTag: 'clients-add',
            backgroundColor: AppColors.accent,
            foregroundColor: AppColors.primary,
            elevation: 4,
            onPressed: _showAddClientDialog,
            child: const Icon(Icons.add, size: 34),
          );
        },
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        toolbarHeight: 44,
        elevation: 0,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: false,
        leading: ValueListenableBuilder<Set<String>?>(
          valueListenable: _selected,
          builder: (context, selected, _) {
            if (selected == null) return const SizedBox.shrink();
            return IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Отмена'.tr,
              onPressed: _exitSelect,
            );
          },
        ),
        title: ValueListenableBuilder<Set<String>?>(
          valueListenable: _selected,
          builder: (context, selected, _) {
            if (selected != null) {
              return Text('${selected.length} ${'выбрано'.tr}');
            }
            return Align(
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
              );
          },
        ),
        actions: [
          ValueListenableBuilder<Set<String>?>(
            valueListenable: _selected,
            builder: (context, selected, _) {
              if (selected == null) {
                return const SizedBox.shrink();
              }
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Выбрать все'.tr,
                    onPressed: () => _enterSelect(all: true),
                    icon: const Icon(Icons.select_all),
                  ),
                  IconButton(
                    tooltip: 'Удалить'.tr,
                    onPressed: selected.isEmpty ? null : _deleteSelected,
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              );
            },
          ),
          ValueListenableBuilder<Set<String>?>(
            valueListenable: _selected,
            builder: (context, selected, _) {
              if (selected != null) return const SizedBox.shrink();
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
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
                ],
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Поиск по любой информации в карточке...'.tr,
                hintMaxLines: 1,
                prefixIcon: const Icon(Icons.search, color: Colors.grey),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppColors.primary, width: 1.4),
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
              stream: _clientsStream,
              builder: (context, snapshot) {
                if (!snapshot.hasData &&
                    snapshot.connectionState == ConnectionState.waiting) {
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
                }).where((data) => data['deletedAt'] == null).toList();

                if (_searchQuery.isNotEmpty) {
                  clients = clients.where((data) {
                    return ClientService.matchesMap(
                      data,
                      data['id'] as String,
                      _searchQuery,
                    );
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
                  clipBehavior: Clip.none,
                  children: [
                    ListView.builder(
                      key: const PageStorageKey('clients-list'),
                      controller: _scrollController,
                      padding: const EdgeInsets.only(
                        left: 16,
                        right: 32,
                        bottom: 88,
                      ),
                      itemCount: clients.length,
                      itemExtent: 80.0,
                      itemBuilder: (context, index) {
                        final data = clients[index];
                        return ValueListenableBuilder<Set<String>?>(
                          key: ValueKey(data['id']),
                          valueListenable: _selected,
                          builder: (context, selected, _) {
                            return _buildClientTile(
                              data,
                              selected?.contains(data['id']) ?? false,
                              selected != null,
                            );
                          },
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
