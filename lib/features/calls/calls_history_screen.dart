import 'package:flutter/material.dart';

import '../../core/app_commands.dart';
import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../core/utils/formatters.dart';
import '../../models/client.dart';
import '../../services/client_service.dart';
import '../../services/twilio_service.dart';
import '../../shared/widgets/selection_action_bar.dart';
import 'call_review_page.dart';
import 'call_screen.dart';
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
                    style: const TextStyle(color: Colors.black54),
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
                  style: const TextStyle(color: Colors.black54, fontSize: 16),
                ),
              );
            }

            _visibleIds = [for (final call in calls) call.id];
            return Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: ListView.builder(
                  key: const PageStorageKey('calls-list'),
                  controller: _scroll,
                  padding: const EdgeInsets.all(16),
                  itemCount: calls.length,
                  itemBuilder: (context, index) {
                    final call = calls[index];
                    return ValueListenableBuilder<Set<String>>(
                      key: ValueKey(call.id),
                      valueListenable: _selected,
                      builder: (context, selected, _) {
                        return _buildCallHistoryCard(
                          call,
                          names,
                          selected.contains(call.id),
                          selected.isNotEmpty,
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
      if (key.length >= 7 && name.trim().isNotEmpty) {
        names[key] = name.trim();
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

  Widget _buildCallHistoryCard(
    CallRecord call,
    Map<String, String> names,
    bool selected,
    bool selecting,
  ) {
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
    final name = widget.contactName ?? names[ClientService.normalizePhone(phone)];

    final card = Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: selected ? const Color(0xFFE8EEF4) : Colors.white,
      elevation: 0.6,
      shadowColor: Colors.transparent,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
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
        child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
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
                      color: isIncoming
                          ? const Color(0xFF2E7D32)
                          : const Color(0xFF1565C0),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      call.answeredByAi
                          ? Icons.notifications_active
                          : isIncoming
                              ? Icons.call_received
                              : Icons.call_made,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isIncoming ? 'Входящий'.tr : 'Исходящий'.tr,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: isIncoming
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
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 2, right: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name ?? phone,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    if (name != null && phone.trim().isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        phone,
                        style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                      ),
                    ],
                    const SizedBox(height: 2),
                    Text(
                      call.startTime != null
                          ? '${Formatters.formatDateTime(call.startTime)} • $duration'
                          : duration,
                      style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                    ),
                    if (call.answeredByAi)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Нажмите: запись, текст RU/EN, ошибка секретаря'.tr,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF475569),
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
                IconButton(
                  tooltip: 'Перезвонить'.tr,
                  onPressed: phone.trim().isEmpty
                      ? null
                      : () => CallScreen.open(
                            context,
                            phoneNumber: phone,
                            contactName: name,
                          ),
                  icon: const Icon(Icons.call, size: 20),
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
              ],
            ),
          ],
        ),
      ),
      ),
    );
    return card;
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
