import 'package:flutter/material.dart';

import '../../core/app_commands.dart';
import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../core/utils/formatters.dart';
import '../../models/client.dart';
import '../../services/client_service.dart';
import '../../shared/app_nav.dart';
import '../clients/client_details_screen.dart';
import '../../services/comms_badge_service.dart';
import '../../services/twilio_service.dart';
import '../../shared/widgets/selection_action_bar.dart';
import '../care_plan/care_plan_widgets.dart';
import 'call_review_page.dart';
import 'dial_pad_screen.dart';

/// История входящих и исходящих звонков Twilio.
class CallsHistoryScreen extends StatefulWidget {
  final bool embedded;
  final String? clientId;
  final List<String> phones;
  final String? contactName;

  const CallsHistoryScreen({
    super.key,
    this.embedded = false,
    this.clientId,
    this.phones = const [],
    this.contactName,
  });

  @override
  State<CallsHistoryScreen> createState() => _CallsHistoryScreenState();
}

class _CallsHistoryScreenState extends State<CallsHistoryScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => widget.embedded;
  final Set<String> _retryingCallIds = {};
  final ValueNotifier<Set<String>> _selected = ValueNotifier<Set<String>>({});
  final ScrollController _scroll = ScrollController();

  /// Развёрнутые номера. Один человек звонит по несколько раз, и раньше
  /// его звонки стояли в списке отдельными строками вперемешку с чужими.
  final Set<String> _expanded = <String>{};
  late final Stream<List<Client>> _clientsStream;
  late final Stream<List<CallRecord>> _callsStream;
  late final bool Function() _dismissSelection;
  List<String> _visibleIds = const [];

  @override
  void dispose() {
    AppCommands.removeSelectionGuard(_dismissSelection);
    _selected.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _setSelected(Set<String> next) => _selected.value = next;

  void _clearSelection() => _setSelected({});

  void _toggleSelected(String id) {
    final next = Set<String>.from(_selected.value);
    if (!next.add(id)) next.remove(id);
    _setSelected(next);
  }

  /// Выделение идёт по номеру целиком: в списке теперь одна строка на
  /// номер, и галочка на ней должна отвечать за все его звонки.
  void _toggleGroupSelected(_CallGroup group) {
    final next = Set<String>.from(_selected.value);
    if (group.ids.every(next.contains)) {
      next.removeAll(group.ids);
    } else {
      next.addAll(group.ids);
    }
    _setSelected(next);
  }

  void _toggleExpanded(String key) {
    setState(() {
      if (!_expanded.add(key)) _expanded.remove(key);
    });
  }

  void _selectAllVisible() => _setSelected({..._visibleIds});

  Future<void> _deleteSelected() async {
    final ids = _selected.value.toList();
    _clearSelection();
    await TwilioService.deleteMany(ids);
  }

  @override
  void initState() {
    super.initState();
    _dismissSelection = () {
      if (_selected.value.isEmpty) return false;
      _clearSelection();
      return true;
    };
    AppCommands.addSelectionGuard(_dismissSelection);
    _clientsStream = ClientService.streamAll();
    _callsStream = widget.clientId == null
        ? TwilioService.getAllCalls()
        : TwilioService.streamForClient(
            clientId: widget.clientId!,
            phones: widget.phones,
          );
    TwilioService.retryStuckAiCalls();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final body = _buildAllCalls();
    return Scaffold(
      backgroundColor: widget.embedded ? Colors.transparent : null,
      appBar: widget.embedded
          ? null
          : AppBar(
              title: Text(
                'Звонки'.tr,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
            ),
      body: body,
      floatingActionButton: widget.embedded || widget.clientId != null
          ? null
          : FloatingActionButton.extended(
              heroTag: 'calls-dial-pad',
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.black,
              icon: const Icon(Icons.dialpad),
              label: Text('Набрать номер'.tr),
              onPressed: () => DialPadScreen.open(context),
            ),
    );
  }

  Widget _buildAllCalls() {
    return StreamBuilder<List<Client>>(
      stream: _clientsStream,
      builder: (context, clientsSnap) {
        final names = _phoneNames(clientsSnap.data ?? const []);
        return StreamBuilder<List<CallRecord>>(
          stream: _callsStream,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    snapshot.error.toString(),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.inkMuted),
                  ),
                ),
              );
            }
            if (!snapshot.hasData &&
                snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            final calls = snapshot.data ?? [];
            if (calls.isEmpty) {
              return Center(
                child: Text(
                  'Нет звонков'.tr,
                  style: TextStyle(color: AppColors.inkMuted, fontSize: 16),
                ),
              );
            }

            _visibleIds = [for (final call in calls) call.id];
            final groups = _groupByNumber(calls);
            return Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: ListView.builder(
                  key: const PageStorageKey('calls-list'),
                  controller: _scroll,
                  padding: const EdgeInsets.all(16),
                  itemCount: groups.length,
                  itemBuilder: (context, index) {
                    final group = groups[index];
                    return ValueListenableBuilder<Set<String>>(
                      key: ValueKey(group.key),
                      valueListenable: _selected,
                      builder: (context, selected, _) {
                        return ValueListenableBuilder<DateTime>(
                          valueListenable: CommsBadgeService.callsNewSince,
                          builder: (context, newSince, _) {
                            return _buildGroupCard(
                              group,
                              names,
                              selected,
                              newSince,
                            );
                          },
                        );
                      },
                    );
                  },
                ),
                ),
                ValueListenableBuilder<Set<String>>(
                  valueListenable: _selected,
                  builder: (context, selected, _) {
                    if (selected.isEmpty) return const SizedBox.shrink();
                    return Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      child: SelectionActionBar(
                        count: selected.length,
                        onCancel: _clearSelection,
                        onSelectAll: _selectAllVisible,
                        onDelete: _deleteSelected,
                      ),
                    );
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  Map<String, String> _phoneNames(List<Client> clients) {
    final names = <String, String>{};
    void add(String phone, String name) {
      final key = ClientService.normalizePhone(phone);
      final cleaned = Client.stripClientWord(name);
      if (key.length >= 7 &&
          cleaned.isNotEmpty &&
          !Client.isPlaceholderName(cleaned)) {
        names[key] = cleaned;
      }
    }

    for (final client in clients) {
      add(client.phone, client.fullName);
      for (final location in client.locations) {
        for (final contact in location.contacts) {
          add(
            contact.phone,
            contact.name.trim().isNotEmpty ? contact.name : client.fullName,
          );
        }
      }
    }
    return names;
  }

  /// Новым считается входящий, которого не было, когда мастер последний раз
  /// открывал список. Исходящие он набирал сам — для них это бессмыслица.
  bool _isNewCall(CallRecord call, DateTime since) {
    if (!call.isIncoming || call.isDeleted) return false;
    final at = call.startTime;
    return at != null && at.isAfter(since);
  }

  /// Трубка со стрелкой: **в** трубку — звонили нам, **от** трубки — звонили
  /// мы (просьба FIX, 21.10.2026: «чтоб было понятно»). Раньше здесь стояли
  /// голые стрелки `call_received` / `call_made`, а у звонков секретаря —
  /// колокольчик, и направление по ним не читалось. Что звонок принял ИИ,
  /// видно по метке состояния справа.
  IconData _directionIcon(CallRecord call) {
    if (!call.isIncoming) return Icons.phone_forwarded;
    // Не дозвонились — трубка с перечёркнутой стрелкой, это тоже входящий.
    if (const ['no-answer', 'busy', 'canceled', 'cancelled']
        .contains(call.status)) {
      return Icons.phone_missed;
    }
    return Icons.phone_callback;
  }

  /// Один номер — одна строка. Звонки внутри группы уже идут от свежих к
  /// старым: поток отдаёт их по убыванию времени. Номер без цифр (скрытый
  /// определитель) в общую кучу не сваливается — у него своя строка.
  List<_CallGroup> _groupByNumber(List<CallRecord> calls) {
    final byKey = <String, _CallGroup>{};
    final order = <String>[];
    for (final call in calls) {
      final phone = call.isIncoming ? call.fromNumber : call.toNumber;
      final digits = ClientService.normalizePhone(phone);
      final key = digits.length >= 7 ? 'phone:$digits' : 'call:${call.id}';
      final group = byKey.putIfAbsent(key, () {
        order.add(key);
        return _CallGroup(key: key);
      });
      group.calls.add(call);
    }
    return [for (final key in order) byKey[key]!];
  }

  String? _extractCallName(CallRecord call) {
    final extracted = <String, dynamic>{
      ...?call.extractedData,
      if (call.aiReception?['extracted'] is Map)
        ...Map<String, dynamic>.from(call.aiReception!['extracted'] as Map),
    };
    for (final key in const [
      'client_name',
      'clientName',
      'name',
      'caller_name',
      'contactName',
      'contact_on_site_name',
    ]) {
      final cleaned = Client.stripClientWord(extracted[key]?.toString());
      if (cleaned.isNotEmpty && !Client.isPlaceholderName(cleaned)) {
        return cleaned;
      }
    }
    return null;
  }

  /// Строка номера: верх — последний звонок, под ним по нажатию раскрываются
  /// остальные звонки этого же номера.
  Widget _buildGroupCard(
    _CallGroup group,
    Map<String, String> names,
    Set<String> selectedIds,
    DateTime newSince,
  ) {
    final call = group.latest;
    final selecting = selectedIds.isNotEmpty;
    final selected = group.ids.every(selectedIds.contains);
    final isNew = group.calls.any((item) => _isNewCall(item, newSince));
    final multi = group.calls.length > 1;
    final expanded = _expanded.contains(group.key);

    final isIncoming = call.isIncoming;
    final duration = call.durationSeconds != null
        ? '${call.durationSeconds! ~/ 60}:${(call.durationSeconds! % 60).toString().padLeft(2, '0')}'
        : '-';

    final (Color statusColor, String statusText) = _statusInfo(call);
    final hasRecording = (call.recordingUrl ?? '').isNotEmpty;
    final connected = (call.durationSeconds ?? 0) > 0;
    final canRetryAi = call.aiStatus == 'error' && (hasRecording || connected);
    final isRetrying = _retryingCallIds.contains(call.id);
    final phone = isIncoming ? call.fromNumber : call.toNumber;
    final name = widget.contactName ??
        names[ClientService.normalizePhone(phone)] ??
        _extractCallName(call);
    final isRegular = ClientService.isRegularClient(
      clientId: call.clientId,
      phone: phone,
    );

    final card = Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: selected
          ? AppColors.selectedCard
          : isNew
          ? AppColors.accent.withValues(alpha: 0.18)
          : AppColors.card,
      elevation: 0.6,
      shadowColor: Colors.transparent,
      shape: isNew
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: AppColors.accent, width: 1.4),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _phoneIcon(
              call: call,
              selecting: selecting,
              selected: selected,
              onSelect: () => _toggleGroupSelected(group),
              onOpenClient: () => _openClientCard(
                phone: phone,
                name: name,
                clientId: call.clientId,
              ),
            ),
            Expanded(
              child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () => _toggleGroupSelected(group),
        onTap: () {
          if (selecting) {
            _toggleGroupSelected(group);
            return;
          }
          // Один звонок открывается сразу: разворачивать нечего.
          if (multi) {
            _toggleExpanded(group.key);
            return;
          }
          CallReviewPage.open(
            context,
            callId: call.id,
            contactName: name,
            call: call,
          );
        },
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 2, right: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name ?? phone,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        if (isRegular) const RegularClientStar(size: 17),
                        CarePlanMark(clientId: call.clientId, phone: phone),
                        if (multi) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1565C0)
                                  .withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${group.calls.length} ${'звонков'.tr}',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF1565C0),
                              ),
                            ),
                          ),
                        ],
                        if (isNew) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.accent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              'Новый'.tr,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: Colors.black,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (name != null && phone.trim().isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        phone,
                        style: TextStyle(color: AppColors.inkMuted, fontSize: 13),
                      ),
                    ],
                    const SizedBox(height: 2),
                    Text(
                      duration,
                      style: TextStyle(color: AppColors.inkMuted, fontSize: 13),
                    ),
                    if (call.answeredByAi)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Нажмите: запись, текст RU/EN, ошибка секретаря'.tr,
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.inkMuted,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (call.startTime != null) ...[
                  Text(
                    Formatters.messageDay(call.startTime),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.ink,
                    ),
                  ),
                  Text(
                    Formatters.formatTime(call.startTime),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.ink,
                    ),
                  ),
                  const SizedBox(height: 4),
                ],
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    isRetrying ? 'ИИ обрабатывает'.tr : statusText,
                    style: TextStyle(
                      color: isRetrying ? Colors.purple : statusColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                if (canRetryAi && !isRetrying)
                  TextButton(
                    onPressed: () => _retryAi(call),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.red,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    child: Text(
                      'Повторить ИИ'.tr,
                      style: const TextStyle(
                        fontSize: 11,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                if (multi)
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 22,
                    color: const Color(0xFF64748B),
                  ),
              ],
            ),
          ],
        ),
              ),
            ),
          ],
        ),
          ),
          if (multi && expanded)
            _expandedCalls(group, name, selectedIds, selecting),
        ],
      ),
    );
    return card;
  }

  /// Трубка слева — отдельная кнопка. Стоит снаружи нажатия на строку,
  /// иначе открылась бы карточка звонка, а не клиента.
  Widget _phoneIcon({
    required CallRecord call,
    required bool selecting,
    required bool selected,
    required VoidCallback onSelect,
    required VoidCallback onOpenClient,
  }) {
    final incoming = call.isIncoming;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: onSelect,
      onTap: selecting ? onSelect : onOpenClient,
      child: SizedBox(
        width: 64,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.topCenter,
          children: [
            Column(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: incoming
                        ? const Color(0xFF2E7D32)
                        : const Color(0xFF1565C0),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _directionIcon(call),
                    color: Colors.white,
                    size: 22,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  incoming ? 'Входящий'.tr : 'Исходящий'.tr,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: incoming
                        ? const Color(0xFF2E7D32)
                        : const Color(0xFF1565C0),
                  ),
                ),
              ],
            ),
            if (selecting)
              Positioned(
                left: -8,
                top: -8,
                child: SelectCheckbox(selected: selected),
              ),
          ],
        ),
      ),
    );
  }

  /// Раскрытый номер — отдельная секция, а не продолжение строки: своя
  /// рамка и чередование серый / бежевый, чтобы список читался как список.
  Widget _expandedCalls(
    _CallGroup group,
    String? name,
    Set<String> selectedIds,
    bool selecting,
  ) {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFD6CBB8)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < group.calls.length; i++) ...[
            if (i > 0)
              const Divider(height: 1, thickness: 1, color: Color(0xFFE4D9C8)),
            _groupCallRow(
              group.calls[i],
              name,
              selectedIds,
              selecting,
              stripe: i.isOdd,
            ),
          ],
        ],
      ),
    );
  }

  /// Один звонок внутри раскрытого номера: когда, сколько длился и чем
  /// кончился. Открывает ту же карточку звонка, что и строка списка.
  Widget _groupCallRow(
    CallRecord call,
    String? name,
    Set<String> selectedIds,
    bool selecting, {
    bool stripe = false,
  }) {
    final (Color statusColor, String statusText) = _statusInfo(call);
    final duration = call.durationSeconds != null
        ? '${call.durationSeconds! ~/ 60}:${(call.durationSeconds! % 60).toString().padLeft(2, '0')}'
        : '-';
    return InkWell(
      onLongPress: () => _toggleSelected(call.id),
      onTap: () {
        if (selecting) {
          _toggleSelected(call.id);
          return;
        }
        CallReviewPage.open(
          context,
          callId: call.id,
          contactName: name,
          call: call,
        );
      },
      child: Container(
        color: selectedIds.contains(call.id)
            ? const Color(0xFFE8EEF4)
            : (stripe ? const Color(0xFFF3E6D0) : const Color(0xFFF4F1EC)),
        padding: const EdgeInsets.fromLTRB(16, 9, 12, 9),
        child: Row(
          children: [
            Icon(
              _directionIcon(call),
              size: 18,
              color: call.isIncoming
                  ? const Color(0xFF2E7D32)
                  : const Color(0xFF1565C0),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                call.startTime != null
                    ? '${Formatters.formatDateTime(call.startTime)} • $duration'
                    : duration,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            Text(
              statusText,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: statusColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Трубка слева от номера — карточка клиента, а не сам звонок.
  Future<void> _openClientCard({
    required String phone,
    String? name,
    String? clientId,
  }) async {
    var id = (clientId ?? '').trim();
    Client? client;
    if (id.isNotEmpty) {
      client = await ClientService.getById(id);
    }
    if (client == null && phone.trim().isNotEmpty) {
      client = await ClientService.findByPhone(phone);
      if (client != null) id = client.id;
    }
    if (!mounted) return;
    if (id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Карточка клиента не найдена'.tr)),
      );
      return;
    }
    final data = client?.toUiMap() ??
        {
          'name': name ?? '',
          'fullName': name ?? '',
          'phone': phone,
        };
    AppNav.openCard(
      context,
      key: AppNav.clientKey(id),
      builder: (_) => ClientDetailsScreen(clientId: id, clientData: data),
    );
  }

  Future<void> _retryAi(CallRecord call) async {
    if (_retryingCallIds.contains(call.id)) return;
    setState(() => _retryingCallIds.add(call.id));
    try {
      await TwilioService.retryAiProcessing(call.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ИИ запущен повторно'.tr)),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Не удалось запустить ИИ'.tr),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _retryingCallIds.remove(call.id));
      }
    }
  }

  (Color, String) _statusInfo(CallRecord call) {
    if (call.aiStatus == 'processing') return (Colors.purple, 'ИИ обрабатывает'.tr);
    if (call.aiStatus == 'error') return (Colors.red, 'Ошибка ИИ'.tr);
    if (call.reviewed) return (Colors.green, 'Обработан'.tr);
    if (call.aiStatus == 'done') return (Colors.orange, 'Ожидает проверки'.tr);

    if (call.answeredBy == 'ai') return (Colors.deepPurple, 'ИИ ответил'.tr);

    switch (call.status) {
      case 'completed':
        return (Colors.blue, 'Завершён'.tr);
      case 'no-answer':
        return (Colors.grey, 'Без ответа'.tr);
      case 'busy':
        return (Colors.grey, 'Занято'.tr);
      case 'failed':
        return (Colors.red, 'Не удался'.tr);
      case 'ringing':
        return (Colors.amber, 'Звонит'.tr);
      case 'in-progress':
        return (Colors.blue, 'В процессе'.tr);
      default:
        return (Colors.grey, call.status);
    }
  }
}

/// Все звонки одного номера, от свежего к старому.
class _CallGroup {
  final String key;
  final List<CallRecord> calls = [];

  _CallGroup({required this.key});

  CallRecord get latest => calls.first;

  List<String> get ids => [for (final call in calls) call.id];
}
