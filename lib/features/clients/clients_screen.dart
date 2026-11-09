import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../core/app_commands.dart';
import '../../core/app_feedback.dart';
import '../../core/constants.dart';
import '../../shared/app_nav.dart';
import '../../shared/widgets/confirm_action_sheet.dart';
import '../../shared/widgets/unsaved_changes_dialog.dart';
import '../../core/motion.dart';
import '../../core/ui_scale.dart';
import '../../models/client.dart';
import '../../models/job.dart';
import '../../services/catalog_service.dart';
import '../../services/job_service.dart';
import '../../shared/widgets/keyboard_safe.dart';
import '../../shared/widgets/phone_client_matches.dart';
import '../../widgets/smart_address_picker.dart';
import 'client_details_screen.dart';
import 'client_search_filter.dart';
import '../../core/l10n/app_locale.dart';
import '../../services/import_export_service.dart';
import '../../services/client_service.dart';
import '../../services/network_status_service.dart';
import '../../shared/widgets/alphabet_index_bar.dart';
import '../../shared/widgets/animated_app_logo.dart';
import '../../shared/widgets/email_field.dart';
import '../../shared/widgets/selection_action_bar.dart';
import 'clients_map_screen.dart';
import 'clients_duplicates_screen.dart';
import '../../services/error_log_service.dart';

class ClientsScreen extends StatefulWidget {
  const ClientsScreen({super.key});

  @override
  State<ClientsScreen> createState() => _ClientsScreenState();
}

class _ClientsScreenState extends State<ClientsScreen> {
  String _searchQuery = '';
  final Set<ClientSearchField> _selectedFields = {};
  final Map<ClientSearchField, TextEditingController> _fieldCtrls = {
    for (final field in ClientSearchField.values)
      if (field != ClientSearchField.all) field: TextEditingController(),
  };
  final Map<ClientSearchField, String> _fieldQueries = {
    for (final field in ClientSearchField.values)
      if (field != ClientSearchField.all) field: '',
  };
  ClientJobIndex? _jobIndex;
  StreamSubscription<List<Job>>? _jobsSub;
  String _sortMethod = 'Имя (А-Я)';
  final ValueNotifier<Set<String>?> _selected = ValueNotifier<Set<String>?>(null);
  List<String> _visibleIds = [];
  List<Map<String, dynamic>> _latestClients = [];
  List<Map<String, dynamic>> _allClients = [];

  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();
  late final Stream<QuerySnapshot> _clientsStream;
  late final bool Function() _dismissSelection;
  final Map<String, String> _knownNamesByClientId = {};
  final Map<String, String> _knownNamesByPhone = {};
  final Set<String> _backfilledClientIds = {};

  bool _externalNamesRequested = false;

  @override
  void initState() {
    super.initState();
    ErrorLogService.markScreen('Клиенты');
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

  void _rememberExternalName({
    String? clientId,
    String? phone,
    String? rawName,
  }) {
    final cleaned = Client.stripClientWord(rawName);
    if (cleaned.isEmpty || Client.isPlaceholderName(cleaned)) return;
    final id = (clientId ?? '').trim();
    if (id.isNotEmpty) {
      _knownNamesByClientId.putIfAbsent(id, () => cleaned);
    }
    final normPhone = ClientService.normalizePhone(phone ?? '');
    if (normPhone.length >= 7) {
      _knownNamesByPhone.putIfAbsent(normPhone, () => cleaned);
    }
  }

  Future<void> _loadExternalClientNames() async {
    try {
      final company = FirebaseFirestore.instance
          .collection('companies')
          .doc(kCompanyId);
      // Заявки держит в кэше общий живой список; звонков хватает последних.
      Future<QuerySnapshot<Map<String, dynamic>>> jobs() async {
        final ref = company.collection('jobs');
        try {
          final cached = await ref.get(const GetOptions(source: Source.cache));
          if (cached.docs.isNotEmpty) return cached;
        } catch (_) {}
        return ref.get();
      }

      final results = await Future.wait([
        jobs(),
        company
            .collection('calls')
            .orderBy('startTime', descending: true)
            .limit(200)
            .get(),
      ]);
      if (!mounted) return;
      for (final doc in results[0].docs) {
        final d = doc.data();
        final cid = (d['clientId'] ?? '').toString();
        final phone = (d['clientPhone'] ?? d['phone'] ?? '').toString();
        for (final key in const ['clientName', 'name', 'jobSiteName']) {
          _rememberExternalName(
            clientId: cid,
            phone: phone,
            rawName: d[key]?.toString(),
          );
        }
      }
      for (final doc in results[1].docs) {
        final d = doc.data();
        final cid = (d['clientId'] ?? '').toString();
        final isInbound = (d['direction'] ?? 'inbound') != 'outbound';
        final phone = (isInbound ? d['fromNumber'] : d['toNumber'])?.toString();
        final extracted = <String, dynamic>{
          if (d['extractedData'] is Map)
            ...Map<String, dynamic>.from(d['extractedData'] as Map),
          if (d['aiReception'] is Map &&
              (d['aiReception'] as Map)['extracted'] is Map)
            ...Map<String, dynamic>.from(
              (d['aiReception'] as Map)['extracted'] as Map,
            ),
        };
        for (final key in const [
          'client_name',
          'clientName',
          'name',
          'caller_name',
          'contactName',
        ]) {
          _rememberExternalName(
            clientId: cid,
            phone: phone,
            rawName: extracted[key]?.toString(),
          );
        }
      }
      if (mounted &&
          (_knownNamesByClientId.isNotEmpty || _knownNamesByPhone.isNotEmpty)) {
        setState(() {});
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    AppCommands.removeSelectionGuard(_dismissSelection);
    _jobsSub?.cancel();
    _selected.dispose();
    _scrollController.dispose();
    _searchCtrl.dispose();
    for (final ctrl in _fieldCtrls.values) {
      ctrl.dispose();
    }
    super.dispose();
  }

  void _setSelected(Set<String>? next) => _selected.value = next;

  /// Фильтры включаются и выключаются независимо; «Везде» сбрасывает их все.
  /// Город, описание и запчасти ищутся по заявкам клиента — заявки читаем,
  /// только пока включён хотя бы один такой фильтр.
  void _toggleSearchField(ClientSearchField field) {
    if (field == ClientSearchField.all) {
      if (_selectedFields.isEmpty) return;
      _selectedFields.clear();
    } else if (!_selectedFields.add(field)) {
      _selectedFields.remove(field);
    }
    AppFeedback.pleasant();
    setState(() {});
    _syncJobsSubscription();
  }

  void _syncJobsSubscription() {
    final needsJobs = _selectedFields.any((f) => f.needsJobs);
    if (needsJobs && _jobsSub == null) {
      _jobsSub = JobService.streamAll().listen((jobs) {
        if (!mounted) return;
        setState(() => _jobIndex = ClientJobIndex.build(jobs));
      }, onError: (_) {});
    } else if (!needsJobs && _jobsSub != null) {
      _jobsSub?.cancel();
      _jobsSub = null;
      _jobIndex = null;
    }
  }

  void _setFieldText(ClientSearchField field, String text) {
    _fieldCtrls[field]!.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() => _fieldQueries[field] = text.toLowerCase());
  }

  void _openMap() {
    AppNav.navigatorOf(context).push(
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
    final confirm = await showConfirmCancelSheet(
      context,
      title: 'Удалить клиентов?'.tr,
      message:
          '${ids.length} ${'выбрано'.tr}\n\n${'Карточки будут удалены. Заявки в календаре останутся.'.tr}',
      confirmLabel: 'Удалить'.tr,
    );
    if (!confirm) return;
    await ClientService.deleteMany(ids);
    if (!mounted) return;
    _exitSelect();
  }

  void _openDuplicates() {
    AppNav.navigatorOf(context).push(
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
      sheetAnimationStyle: AppMotion.sheet,
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (builderContext, setSheetState) {
            Future<bool> saveClient() async {
              final phone = phoneCtrl.text.trim();
              if (nameCtrl.text.trim().isEmpty && phone.isNotEmpty) {
                nameCtrl.text = phone;
              }
              if (nameCtrl.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Укажите имя клиента'.tr),
                    backgroundColor: Colors.red,
                  ),
                );
                return false;
              }
              final existing = phone.isEmpty
                  ? const <Client>[]
                  : (phoneMatches.isNotEmpty
                      ? phoneMatches
                      : await ClientService.searchByPhone(phone));
              if (existing.isNotEmpty) {
                final client = existing.first;
                final open = await showConfirmCancelSheet(
                  context,
                  title: 'Клиент с этим номером уже есть'.tr,
                  message:
                      '${client.fullName.isEmpty ? 'Без имени'.tr : client.fullName}\n${client.phone}\n\n${'Открыть карточку?'.tr}',
                  confirmLabel: 'Открыть'.tr,
                );
                if (open && context.mounted) {
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                  AppNav.openCard(
                    context,
                    key: AppNav.clientKey(client.id),
                    builder: (_) => ClientDetailsScreen(
                      clientId: client.id,
                      clientData: client.toUiMap(),
                    ),
                  );
                }
                return false;
              }
              final fullAddress =
                  '${streetCtrl.text}, ${cityCtrl.text}, ${postalCtrl.text}';
              await settleWrite(
                FirebaseFirestore.instance
                    .collection('companies')
                    .doc(kCompanyId)
                    .collection('clients')
                    .doc()
                    .set({
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
                    }),
              );
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
                                AppNav.openCard(
                                  context,
                                  key: AppNav.clientKey(client.id),
                                  builder: (_) => ClientDetailsScreen(
                                    clientId: client.id,
                                    clientData: client.toUiMap(),
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
                              style: const TextStyle(
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
                                  color: AppColors.cardMuted,
                                  border: Border.all(color: AppColors.border),
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
                                              ? AppColors.inkMuted
                                              : AppColors.ink,
                                          fontSize: 16,
                                        ),
                                      ),
                                    ),
                                    Icon(Icons.search, color: AppColors.primaryOnCard),
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
                                border: const OutlineInputBorder(),
                                prefixIcon: const Icon(Icons.notes),
                              ),
                            ),
                            const SizedBox(height: 12),
                            StreamBuilder<List<String>>(
                              stream: CatalogService.streamLeadSources(),
                              builder: (context, snap) {
                                final sources = snap.data ?? CatalogService.defaultLeadSources;
                                return DropdownButtonFormField<String>(
                                  initialValue: sources.contains(source) ? source : null,
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
                                border: const OutlineInputBorder(),
                                prefixIcon: const Icon(Icons.business),
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
                            // Кнопка закрывает окно и ничего не удаляет.
                            // Подпись «Удалить» пугала: казалось, что нажатие
                            // сотрёт карточку клиента.
                            tooltip: 'Закрыть'.tr,
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
    final isRegular = ClientService.isRegularMap(data);
    final company = (data['company'] as String?) ?? '';
    final rawPhone = ((data['phone'] as String?) ?? '').trim();
    final phone = rawPhone.isEmpty ? 'Нет телефона'.tr : rawPhone;
    final hasRealName =
        name.isNotEmpty &&
        name != 'Без имени' &&
        !Client.isPlaceholderName(name);
    final avatar = CircleAvatar(
      backgroundColor: AppColors.tint(AppColors.primary, 0.14),
      child: Text(
        hasRealName ? name[0].toUpperCase() : '?',
        style: TextStyle(
          color: AppColors.primaryOnCard,
          fontWeight: FontWeight.bold,
          fontSize: 18,
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? AppColors.selectedCard : AppColors.card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected ? AppColors.primary : AppColors.border,
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
            AppNav.openCard(
              context,
              key: AppNav.clientKey('${data['id']}'),
              builder: (context) => ClientDetailsScreen(
                clientId: data['id'],
                clientData: data,
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
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                name == 'Без имени' ? 'Без имени'.tr : name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            if (isRegular) const RegularClientStar(size: 18),
                          ],
                        ),
                        if (hasRealName ||
                            rawPhone.isEmpty ||
                            company.isNotEmpty)
                          Text(
                            !hasRealName && rawPhone.isNotEmpty
                                ? company
                                : (company.isNotEmpty
                                      ? '$company • $phone'
                                      : phone),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: AppColors.inkMuted),
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
    final extracted = Client.extractName(data, fallback: '');
    if (extracted.isNotEmpty && !Client.isPlaceholderName(extracted)) {
      return extracted;
    }
    final id = (data['id'] ?? '').toString().trim();
    if (id.isNotEmpty) {
      final byId = _knownNamesByClientId[id];
      if (byId != null && byId.isNotEmpty) return byId;
    }
    final normPhone = ClientService.normalizePhone(
      (data['phone'] ?? '').toString(),
    );
    if (normPhone.length >= 7) {
      final byPhone = _knownNamesByPhone[normPhone];
      if (byPhone != null && byPhone.isNotEmpty) return byPhone;
    }
    if (extracted.isNotEmpty) return extracted;
    return 'Без имени';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppUiSettings.instance,
      builder: (context, _) {
        return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        toolbarHeight: 44,
        elevation: 0,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: false,
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
          Expanded(child: _buildClientList()),
          // Поиск, «+» и действия выбора — внизу, под большим пальцем.
          ValueListenableBuilder<Set<String>?>(
            valueListenable: _selected,
            builder: (context, selected, _) {
              if (selected != null) {
                return SelectionActionBar(
                  count: selected.length,
                  onCancel: _exitSelect,
                  onSelectAll: () => _enterSelect(all: true),
                  onDelete: _deleteSelected,
                );
              }
              return _buildSearchBar();
            },
          ),
        ],
      ),
    );
      },
    );
  }

  String _hintFor(ClientSearchField field) {
    switch (field) {
      case ClientSearchField.all:
        return 'Поиск по любой информации в карточке...'.tr;
      case ClientSearchField.city:
        return context.tr('Город...', 'City...');
      case ClientSearchField.name:
        return context.tr('Имя клиента...', 'Client name...');
      case ClientSearchField.description:
        return context.tr(
          'Что ремонтировали: техника, поломка...',
          'What was repaired: appliance, problem...',
        );
      case ClientSearchField.parts:
        return context.tr(
          'Запчасть или номер детали...',
          'Part name or number...',
        );
    }
  }

  IconData _fieldIcon(ClientSearchField field) {
    switch (field) {
      case ClientSearchField.all:
        return Icons.manage_search;
      case ClientSearchField.city:
        return Icons.location_city_outlined;
      case ClientSearchField.name:
        return Icons.person_outline;
      case ClientSearchField.description:
        return Icons.handyman_outlined;
      case ClientSearchField.parts:
        return Icons.settings_outlined;
    }
  }

  Widget _searchFieldChip(ClientSearchField field, IconData icon, String label) {
    final selected = field == ClientSearchField.all
        ? _selectedFields.isEmpty
        : _selectedFields.contains(field);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: selected ? AppColors.primary : AppColors.card,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _toggleSearchField(field),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selected ? AppColors.primary : AppColors.border,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: selected ? Colors.white : AppColors.primaryOnCard,
                ),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : AppColors.primaryOnCard,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Фильтры поиска. Можно включить несколько полей сразу — условия
  /// складываются по «И»; «Везде» сбрасывает их все.
  Widget _buildSearchFieldChips() {
    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        children: [
          _searchFieldChip(
            ClientSearchField.all,
            Icons.manage_search,
            context.tr('Везде', 'All'),
          ),
          _searchFieldChip(
            ClientSearchField.city,
            Icons.location_city_outlined,
            context.tr('Город', 'City'),
          ),
          _searchFieldChip(
            ClientSearchField.name,
            Icons.person_outline,
            context.tr('Имя', 'Name'),
          ),
          _searchFieldChip(
            ClientSearchField.description,
            Icons.handyman_outlined,
            context.tr('Описание', 'Description'),
          ),
          _searchFieldChip(
            ClientSearchField.parts,
            Icons.settings_outlined,
            context.tr('Запчасти', 'Parts'),
          ),
        ],
      ),
    );
  }

  /// Быстрый выбор города: самые частые города клиентов.
  Widget _buildCityChips() {
    final cities = topClientCities(
      _allClients,
      _jobIndex ?? ClientJobIndex.empty,
    );
    if (cities.isEmpty) return const SizedBox.shrink();
    final cityQuery = _fieldQueries[ClientSearchField.city] ?? '';
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
        children: [
          for (final city in cities)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                label: Text(city),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                labelStyle: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: cityQuery == city.toLowerCase()
                      ? Colors.white
                      : AppColors.primaryOnCard,
                ),
                backgroundColor: cityQuery == city.toLowerCase()
                    ? AppColors.primary
                    : AppColors.cardMuted,
                side: BorderSide(color: AppColors.border),
                onPressed: () => _setFieldText(
                  ClientSearchField.city,
                  cityQuery == city.toLowerCase() ? '' : city,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildSearchFieldChips(),
        if (_selectedFields.contains(ClientSearchField.city)) _buildCityChips(),
        if (_selectedFields.isEmpty)
          _buildSearchRow()
        else
          ..._buildFieldSearchRows(),
      ],
    );
  }

  /// По полю поиска на каждый включённый фильтр; все условия — по «И».
  List<Widget> _buildFieldSearchRows() {
    final fields = ClientSearchField.values
        .where((f) => f != ClientSearchField.all && _selectedFields.contains(f))
        .toList();
    return [
      for (var i = 0; i < fields.length; i++)
        Padding(
          padding: EdgeInsets.fromLTRB(
            12,
            6,
            12,
            i == fields.length - 1 ? 10 : 0,
          ),
          child: Row(
            children: [
              Expanded(child: _buildFieldSearchField(fields[i])),
              if (i == 0) ...[
                const SizedBox(width: 10),
                _buildAddFab(),
              ],
            ],
          ),
        ),
    ];
  }

  Widget _buildFieldSearchField(ClientSearchField field) {
    final ctrl = _fieldCtrls[field]!;
    return TextField(
      controller: ctrl,
      decoration: InputDecoration(
        hintText: _hintFor(field),
        hintMaxLines: 1,
        prefixIcon: Icon(_fieldIcon(field), color: Colors.grey, size: 20),
        suffixIcon: ctrl.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Очистить'.tr,
                icon: const Icon(Icons.clear, color: Colors.grey, size: 20),
                onPressed: () => _setFieldText(field, ''),
              ),
        filled: true,
        fillColor: AppColors.card,
        contentPadding: const EdgeInsets.symmetric(vertical: 0),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.primary, width: 1.4),
        ),
      ),
      onChanged: (val) {
        setState(() => _fieldQueries[field] = val.toLowerCase());
      },
    );
  }

  Widget _buildSearchRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: _hintFor(ClientSearchField.all),
                hintMaxLines: 1,
                prefixIcon: const Icon(Icons.search, color: Colors.grey),
                filled: true,
                fillColor: AppColors.card,
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppColors.border),
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
          const SizedBox(width: 10),
          _buildAddFab(),
        ],
      ),
    );
  }

  Widget _buildAddFab() {
    return SizedBox(
      width: 52,
      height: 52,
      child: FloatingActionButton(
        heroTag: 'clients-add',
        backgroundColor: AppColors.accent,
        foregroundColor: AppColors.primary,
        elevation: 2,
        onPressed: _showAddClientDialog,
        child: const Icon(Icons.add, size: 32),
      ),
    );
  }

  Widget _buildClientList() {
    return StreamBuilder<QuerySnapshot>(
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
                      style: const TextStyle(color: Colors.grey),
                    ),
                  );
                }

                final rawDocs = snapshot.data!.docs;
                var needsExternalLookup = false;
                for (final doc in rawDocs) {
                  final d = doc.data() as Map<String, dynamic>;
                  if (d['deletedAt'] != null) continue;
                  final own = Client.extractName(d, fallback: '');
                  if (own.isNotEmpty && !Client.isPlaceholderName(own)) {
                    _rememberExternalName(
                      clientId: doc.id,
                      phone: (d['phone'] ?? '').toString(),
                      rawName: own,
                    );
                  } else {
                    needsExternalLookup = true;
                  }
                }
                if (needsExternalLookup && !_externalNamesRequested) {
                  _externalNamesRequested = true;
                  unawaited(_loadExternalClientNames());
                }

                List<Map<String, dynamic>> clients = rawDocs.map((
                  doc,
                ) {
                  var data = Map<String, dynamic>.from(
                    doc.data() as Map<String, dynamic>,
                  );
                  data['id'] = doc.id;
                  final displayName = _extractClientName(data);
                  data['display_name'] = displayName;
                  if (displayName.isNotEmpty &&
                      displayName != 'Без имени' &&
                      !Client.isPlaceholderName(displayName)) {
                    final storedFull =
                        (data['fullName'] ?? '').toString().trim();
                    final storedName = (data['name'] ?? '').toString().trim();
                    data['fullName'] = displayName;
                    data['name'] = displayName;
                    if ((Client.isPlaceholderName(storedFull) ||
                            Client.isPlaceholderName(storedName)) &&
                        _backfilledClientIds.add(doc.id)) {
                      unawaited(
                        doc.reference
                            .set(
                              {'fullName': displayName, 'name': displayName},
                              SetOptions(merge: true),
                            )
                            .catchError((_) {}),
                      );
                    }
                  }
                  return data;
                }).where((data) => data['deletedAt'] == null).toList();
                ClientService.syncRegularFromMaps(clients);
                _allClients = clients;

                final criteria = <ClientSearchCriterion>[
                  if (_selectedFields.isEmpty && _searchQuery.isNotEmpty)
                    ClientSearchCriterion(ClientSearchField.all, _searchQuery),
                  for (final field in _selectedFields)
                    if ((_fieldQueries[field] ?? '').trim().isNotEmpty)
                      ClientSearchCriterion(field, _fieldQueries[field] ?? ''),
                ];
                final hasFilters = criteria.isNotEmpty;

                if (hasFilters) {
                  // Заявки для фильтра ещё грузятся — не показываем пустой
                  // список, будто никого не нашли.
                  if (criteria.any((c) => c.field.needsJobs) &&
                      _jobIndex == null) {
                    return const AppLoading();
                  }
                  final index = _jobIndex ?? ClientJobIndex.empty;
                  clients = clients.where((data) {
                    return clientMatchesAll(
                      data,
                      data['id'] as String,
                      index,
                      criteria,
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

                if (_sortMethod == 'Имя (А-Я)' && !hasFilters) {
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
                        top: 8,
                        bottom: 8,
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
            );
  }
}
