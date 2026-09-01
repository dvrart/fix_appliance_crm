import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/app_commands.dart';
import '../../core/app_feedback.dart';
import '../../core/constants.dart';
import '../../models/client.dart';
import '../../services/client_service.dart';
import '../../services/firestore_service.dart';
import '../../services/settings_service.dart';
import '../../services/sms_service.dart';
import 'conversation_screen.dart';
import '../../core/l10n/app_locale.dart';
import '../../shared/widgets/email_field.dart';
import '../../shared/widgets/selection_action_bar.dart';

/// Список переписок — SMS и почта в одном месте.
class MessagesScreen extends StatefulWidget {
  final bool embedded;

  const MessagesScreen({super.key, this.embedded = false});

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();

  static Future<void> startNewConversation(
    BuildContext context, {
    ConversationChannel? channel,
  }) =>
      _MessagesScreenState.startNewConversation(context, channel: channel);
}

class _MessagesScreenState extends State<MessagesScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => widget.embedded;
  final ValueNotifier<Set<String>> _selected = ValueNotifier<Set<String>>({});
  final ScrollController _scroll = ScrollController();
  final Map<String, List<String>> _idsByKey = {};
  List<SmsMessage> _allMessages = const [];
  Map<String, String> _watchedNames = const {};
  StreamSubscription? _configSub;
  late final Stream<List<Client>> _clientsStream;
  late final Stream<List<SmsMessage>> _smsStream;
  late final bool Function() _dismissSelection;

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
    _smsStream = SmsService.streamAll();
    _configSub = FirestoreService.configRef.snapshots().listen((snap) {
      final data = (snap.data() as Map<String, dynamic>?) ?? {};
      if (!mounted) return;
      setState(() {
        _watchedNames = {
          for (final s in SettingsService.readWatchedEmailSenders(data))
            if (s.name.trim().isNotEmpty) s.email: s.name.trim(),
        };
      });
    });
  }

  @override
  void dispose() {
    _configSub?.cancel();
    AppCommands.removeSelectionGuard(_dismissSelection);
    _selected.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String? _threadTitle(SmsConversation conv, Client? client) {
    if (conv.isWebsite) return kWebsiteInboxTitle.tr;
    final clientName = (client?.fullName ?? '').trim();
    if (clientName.isNotEmpty) return clientName;
    final email = SmsService.normalizeEmail(conv.email ?? '');
    final watched = _watchedNames[email];
    if (watched != null && watched.isNotEmpty) return watched;
    if (conv.phoneNumber.isNotEmpty) return conv.phoneNumber;
    if (email.contains('@')) return email;
    return null;
  }

  void _setSelected(Set<String> next) => _selected.value = next;

  void _clearSelection() => _setSelected({});

  void _toggleSelected(String key) {
    final next = Set<String>.from(_selected.value);
    if (!next.add(key)) next.remove(key);
    _setSelected(next);
  }

  void _selectAllVisible() => _setSelected({..._idsByKey.keys});

  Future<void> _deleteSelected() async {
    final ids = <String>{
      for (final key in _selected.value) ...(_idsByKey[key] ?? const <String>[]),
    };
    _clearSelection();
    await SmsService.deleteMany(ids);
  }

  Future<void> _copySelected() async {
    final ids = <String>{
      for (final key in _selected.value) ...(_idsByKey[key] ?? const <String>[]),
    };
    final byId = {for (final m in _allMessages) m.id: m};
    final parts = <String>[];
    for (final id in ids) {
      final message = byId[id];
      if (message == null) continue;
      final subject = message.subject.trim();
      final body = message.body.trim();
      if (subject.isNotEmpty && body.isNotEmpty) {
        parts.add('$subject\n$body');
      } else if (subject.isNotEmpty) {
        parts.add(subject);
      } else if (body.isNotEmpty) {
        parts.add(body);
      }
    }
    if (parts.isEmpty) return;
    await AppFeedback.copy(context, parts.join('\n\n'));
    _clearSelection();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final body = StreamBuilder<List<Client>>(
      stream: _clientsStream,
      builder: (context, clientsSnapshot) {
        final clients = clientsSnapshot.data ?? [];
        final clientsById = {for (final c in clients) c.id: c};

        return StreamBuilder<List<SmsMessage>>(
          stream: _smsStream,
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

            final conversations = SmsService.buildConversations(snapshot.data ?? [], clients);
            _allMessages = snapshot.data ?? const [];

            if (conversations.isEmpty) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.forum_outlined, size: 80, color: Colors.grey.shade300),
                    const SizedBox(height: 16),
                    Text('Нет сообщений'.tr, style: TextStyle(fontSize: 18, color: Colors.grey)),
                    const SizedBox(height: 8),
                    Text(
                      'SMS и письма от клиентов\nпоявятся здесь'.tr,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              );
            }

            _idsByKey
              ..clear()
              ..addAll({
                for (final conv in conversations) conv.selectKey: conv.messageIds,
              });
            return Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: ListView.separated(
                    key: const PageStorageKey('messages-list'),
                    controller: _scroll,
                    itemCount: conversations.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, indent: 72),
                    itemBuilder: (context, index) {
                      final conv = conversations[index];
                      final client =
                          conv.clientId != null ? clientsById[conv.clientId] : null;
                      return ValueListenableBuilder<Set<String>>(
                        key: ValueKey(conv.selectKey),
                        valueListenable: _selected,
                        builder: (context, selected, _) {
                          return _buildConversationTile(
                            context,
                            conv,
                            client,
                            selected.contains(conv.selectKey),
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
                        onCopy: _copySelected,
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

    if (widget.embedded) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: body,
      );
    }

    final fab = FloatingActionButton(
      heroTag: 'messages-compose',
      onPressed: () => startNewConversation(context),
      backgroundColor: AppColors.accent,
      foregroundColor: AppColors.primary,
      elevation: 4,
      child: const Icon(Icons.add, size: 34),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text('Сообщения'.tr, style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      floatingActionButton: fab,
      body: body,
    );
  }

  Widget _buildConversationTile(
    BuildContext context,
    SmsConversation conv,
    Client? client,
    bool selected,
    bool selecting,
  ) {
    final name = _threadTitle(conv, client) ?? '';
    final hasUnread = conv.unreadCount > 0;
    final last = conv.lastMessage;
    final preview = last.isEmail && last.subject.trim().isNotEmpty
        ? last.subject.trim()
        : last.displayBody;
    final avatar = CircleAvatar(
      backgroundColor: AppColors.primary.withValues(alpha: 0.15),
      child: conv.isWebsite
          ? Icon(Icons.language, color: AppColors.primary)
          : client != null
          ? Text(
              client.initials,
              style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold),
            )
          : Icon(
              conv.hasEmail && !conv.hasSms ? Icons.email_outlined : Icons.person_outline,
              color: AppColors.primary,
            ),
    );

    return ColoredBox(
      color: selected ? const Color(0xFFE8EEF4) : Colors.transparent,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () => _toggleSelected(conv.selectKey),
        onTap: () {
          if (selecting) {
            _toggleSelected(conv.selectKey);
            return;
          }
          ConversationScreen.open(
            context,
            phoneNumber: conv.isWebsite ? '' : conv.phoneNumber,
            email: conv.isWebsite ? null : (conv.email ?? client?.email),
            contactName: conv.isWebsite
                ? kWebsiteInboxTitle
                : _threadTitle(conv, client),
            clientId: conv.isWebsite ? null : (conv.clientId ?? client?.id),
            websiteInbox: conv.isWebsite,
            initialChannel:
                last.isEmail ? ConversationChannel.email : ConversationChannel.sms,
          );
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: hasUnread ? FontWeight.bold : FontWeight.w600,
                            ),
                          ),
                        ),
                        if (conv.hasSms)
                          const Padding(
                            padding: EdgeInsets.only(left: 4),
                            child: Icon(Icons.sms, size: 16, color: Colors.indigo),
                          ),
                        if (conv.hasEmail)
                          const Padding(
                            padding: EdgeInsets.only(left: 4),
                            child: Icon(Icons.email, size: 16, color: Color(0xFFEA4335)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${last.isOutbound ? '${'Вы'.tr}: ' : ''}$preview',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: hasUnread ? Colors.black87 : Colors.grey.shade600,
                        fontWeight: hasUnread ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    last.createdAt != null
                        ? DateFormat('dd.MM HH:mm').format(last.createdAt!)
                        : '',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                  ),
                  if (hasUnread) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${conv.unreadCount}',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.black,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Future<void> startNewConversation(
    BuildContext context, {
    ConversationChannel? channel,
  }) async {
    final wantEmail = channel == ConversationChannel.email;
    final ctrl = TextEditingController();
    final result = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            12,
            20,
            16 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                wantEmail ? 'Email'.tr : 'SMS'.tr,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF14557F),
                ),
              ),
              const SizedBox(height: 16),
              if (wantEmail)
                EmailAutocompleteField(
                  controller: ctrl,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (value) => Navigator.pop(context, value.trim()),
                  decoration: InputDecoration(
                    labelText: 'Email'.tr,
                    prefixIcon: const Icon(Icons.mail_outline, color: Color(0xFFEA4335)),
                  ),
                )
              else
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (value) => Navigator.pop(context, value.trim()),
                  decoration: InputDecoration(
                    labelText: 'Телефон'.tr,
                    prefixIcon: const Icon(Icons.sms_outlined, color: Color(0xFF1E88E5)),
                  ),
                ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context, ctrl.text.trim()),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF14557F),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text('Далее'.tr),
                ),
              ),
            ],
          ),
        );
      },
    );
    ctrl.dispose();
    if (result == null || result.isEmpty || !context.mounted) return;
    if (wantEmail && !result.contains('@')) return;
    if (!wantEmail && result.replaceAll(RegExp(r'\D'), '').length < 10) return;

    await ConversationScreen.open(
      context,
      phoneNumber: wantEmail ? '' : result,
      email: wantEmail ? result : null,
      initialChannel: wantEmail ? ConversationChannel.email : ConversationChannel.sms,
    );
  }
}
