import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/app_feedback.dart';
import '../../core/constants.dart';
import '../../services/client_service.dart';
import '../../services/email_service.dart';
import '../../services/job_service.dart';
import '../../services/message_translate_service.dart';
import '../../services/outbound_media_service.dart';
import '../../services/settings_service.dart';
import '../../services/sms_service.dart';
import '../../models/client.dart';
import '../calls/call_screen.dart';
import '../clients/client_details_screen.dart';
import '../../core/l10n/app_locale.dart';
import '../../shared/widgets/selection_action_bar.dart';

enum ConversationChannel { sms, email }

/// Хозяин или человек на объекте — отдельная нить SMS.
class ConversationPeer {
  final String id;
  final String label;
  final String name;
  final String phone;
  final String email;

  const ConversationPeer({
    required this.id,
    required this.label,
    required this.name,
    this.phone = '',
    this.email = '',
  });

  String get displayName => name.trim().isEmpty ? label : name.trim();

  bool get hasPhone => SmsService.normalizePhone(phone).length >= 10;

  bool get hasEmail => email.trim().contains('@');

  bool get hasChannel => hasPhone || hasEmail;

  /// Хозяин и люди на объекте (арендатор) для переключения нити.
  static Future<List<ConversationPeer>> loadForClient({
    required String clientId,
    String name = '',
    String phone = '',
    String email = '',
  }) async {
    final peers = <ConversationPeer>[];
    final seen = <String>{};

    void add(ConversationPeer peer) {
      if (!peer.hasChannel) return;
      final keys = <String>[
        if (peer.hasPhone) SmsService.normalizePhone(peer.phone),
        if (peer.hasEmail) peer.email.trim().toLowerCase(),
      ];
      if (keys.any(seen.contains)) return;
      seen.addAll(keys);
      peers.add(peer);
    }

    try {
      final client = clientId.trim().isEmpty
          ? null
          : await ClientService.getById(clientId);
      add(
        ConversationPeer(
          id: 'owner',
          label: 'Хозяин'.tr,
          name: name.trim().isNotEmpty ? name.trim() : (client?.fullName ?? ''),
          phone: phone.trim().isNotEmpty ? phone.trim() : (client?.phone ?? ''),
          email: email.trim().isNotEmpty
              ? email.trim()
              : (client?.email ?? ''),
        ),
      );
      if (client != null) {
        for (final location in client.locations) {
          for (final contact in location.contacts) {
            add(
              ConversationPeer(
                id: 'loc-${contact.id.isEmpty ? contact.phone : contact.id}',
                label: contact.role == 'owner'
                    ? 'Хозяин'.tr
                    : contact.roleLabel,
                name: contact.name,
                phone: contact.phone,
              ),
            );
          }
        }
      }
      if (clientId.trim().isNotEmpty) {
        final jobs = await JobService.streamByClient(clientId).first;
        for (final job in jobs) {
          if (!job.hasJobSite) continue;
          add(
            ConversationPeer(
              id: 'job-${job.id}',
              label: 'Арендатор'.tr,
              name: (job.jobSiteName ?? '').trim().isEmpty
                  ? 'Арендатор'.tr
                  : job.jobSiteName!.trim(),
              phone: job.jobSitePhone ?? '',
              email: job.jobSiteEmail ?? '',
            ),
          );
        }
      }
    } catch (_) {}
    return peers;
  }
}

/// Переписка с одним клиентом. SMS и почта переключаются, лента меняется.
class ConversationScreen extends StatefulWidget {
  final String phoneNumber;
  final String? email;
  final String? contactName;
  final String? clientId;
  final String? jobId;
  final List<String> extraPhones;
  final List<ConversationPeer> recipients;
  final bool embedded;
  final ConversationChannel? initialChannel;

  const ConversationScreen({
    super.key,
    this.phoneNumber = '',
    this.email,
    this.contactName,
    this.clientId,
    this.jobId,
    this.extraPhones = const [],
    this.recipients = const [],
    this.embedded = false,
    this.initialChannel,
  });

  static Future<void> open(
    BuildContext context, {
    String phoneNumber = '',
    String? email,
    String? contactName,
    String? clientId,
    String? jobId,
    ConversationChannel? initialChannel,
    bool rootNavigator = false,
  }) async {
    AppFeedback.pleasant();
    final recipients = (clientId != null && clientId.trim().isNotEmpty)
        ? await ConversationPeer.loadForClient(
            clientId: clientId,
            name: contactName ?? '',
            phone: phoneNumber,
            email: email ?? '',
          )
        : const <ConversationPeer>[];
    if (!context.mounted) return;
    await Navigator.of(context, rootNavigator: rootNavigator).push(
      MaterialPageRoute(
        builder: (_) => ConversationScreen(
          phoneNumber: phoneNumber,
          email: email,
          contactName: contactName,
          clientId: clientId,
          jobId: jobId,
          recipients: recipients,
          initialChannel: initialChannel,
        ),
      ),
    );
  }

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isSending = false;
  late ConversationChannel _channel;
  final List<OutboundAttachment> _attachments = [];
  late String _phone;
  late String _email;
  late String _contactName;
  late String _peerId;
  final Map<String, List<SmsMessage>> _threadCache = {};
  String? _lastJumpId;
  final Set<String> _selectedIds = {};
  List<String> _visibleIds = const [];

  bool get _selecting => _selectedIds.isNotEmpty;

  void _clearSelection() => setState(() => _selectedIds.clear());

  void _toggleSelected(String id) {
    setState(() {
      if (!_selectedIds.add(id)) _selectedIds.remove(id);
    });
  }

  void _selectAllVisible() {
    setState(() => _selectedIds.addAll(_visibleIds));
  }

  Future<void> _deleteSelected() async {
    final ids = _selectedIds.toList();
    _clearSelection();
    await SmsService.deleteMany(ids);
  }

  List<ConversationPeer> get _peers =>
      widget.recipients.where((peer) => peer.hasChannel).toList();

  bool get _hasPhone => SmsService.normalizePhone(_phone).length >= 10;
  bool get _hasEmail => _email.contains('@');

  @override
  void initState() {
    super.initState();
    _applyPeerFromWidget();
    _channel = widget.initialChannel ??
        (_hasEmail && !_hasPhone ? ConversationChannel.email : ConversationChannel.sms);
    _textController.addListener(_onDraftChanged);
    _markRead();
  }

  @override
  void didUpdateWidget(covariant ConversationScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final phoneChanged = oldWidget.phoneNumber != widget.phoneNumber;
    final emailChanged = oldWidget.email != widget.email;
    if (phoneChanged || emailChanged) {
      _applyPeerFromWidget();
      _markRead();
    }
  }

  void _applyPeerFromWidget() {
    _phone = widget.phoneNumber;
    _email = (widget.email ?? '').trim();
    _contactName = (widget.contactName ?? '').trim();
    final match = _peers.cast<ConversationPeer?>().firstWhere(
      (peer) =>
          peer != null &&
          ((peer.hasPhone &&
                  SmsService.normalizePhone(peer.phone) ==
                      SmsService.normalizePhone(_phone)) ||
              (peer.hasEmail &&
                  peer.email.trim().toLowerCase() == _email.toLowerCase())),
      orElse: () => _peers.isEmpty ? null : _peers.first,
    );
    _peerId = match?.id ?? '';
    if (match != null) {
      _phone = match.phone;
      _email = match.email.trim();
      _contactName = match.displayName;
    }
  }

  void _selectPeer(ConversationPeer peer) {
    setState(() {
      _peerId = peer.id;
      _phone = peer.phone;
      _email = peer.email.trim();
      _contactName = peer.displayName;
      if (!_hasPhone && _hasEmail) {
        _channel = ConversationChannel.email;
      } else if (_hasPhone && _channel == ConversationChannel.email && !_hasEmail) {
        _channel = ConversationChannel.sms;
      }
    });
    _markRead();
  }

  void _onDraftChanged() {
    if (mounted) setState(() {});
  }

  void _markRead() {
    SmsService.markConversationRead(
      _phone,
      email: _hasEmail ? _email : null,
      clientId: widget.clientId,
    );
  }

  @override
  void dispose() {
    _textController.removeListener(_onDraftChanged);
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    if ((text.isEmpty && _attachments.isEmpty) || _isSending) return;

    if (_channel == ConversationChannel.email && !_hasEmail) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Нет email у клиента'.tr), backgroundColor: Colors.red),
      );
      return;
    }
    if (_channel == ConversationChannel.sms && !_hasPhone) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Нет телефона у клиента'.tr), backgroundColor: Colors.red),
      );
      return;
    }

    setState(() => _isSending = true);
    final pending = List<OutboundAttachment>.from(_attachments);
    _textController.clear();
    setState(() => _attachments.clear());

    try {
      final uploaded = <String>[];
      for (final file in pending) {
        uploaded.add(await OutboundMediaService.upload(file));
      }

      var englishBody = text;
      var russianBody = text;
      if (text.isNotEmpty && MessageTranslateService.looksRussian(text)) {
        englishBody = await MessageTranslateService.toEnglish(text);
        russianBody = text;
        if (MessageTranslateService.failedEnglish(text, englishBody)) {
          englishBody = text;
        }
      } else if (text.isNotEmpty) {
        englishBody = text;
        russianBody = MessageTranslateService.needsRussian(text)
            ? await MessageTranslateService.toRussian(text)
            : text;
      }

      final bool ok;
      if (_channel == ConversationChannel.email) {
        ok = await EmailService.sendEmail(
          to: _email,
          body: englishBody,
          clientId: widget.clientId,
          phone: _phone,
          mediaUrls: uploaded,
          bodyRu: russianBody,
        );
      } else {
        final mms = <String>[];
        final extra = StringBuffer(englishBody);
        for (var i = 0; i < pending.length; i++) {
          if (pending[i].isMmsSafe) {
            mms.add(uploaded[i]);
          } else {
            if (extra.isNotEmpty) extra.writeln();
            extra.write(uploaded[i]);
          }
        }
        ok = await SmsService.sendSms(
          to: _phone,
          body: extra.toString().trim(),
          clientId: widget.clientId,
          mediaUrls: mms,
          bodyRu: russianBody,
        );
      }

      if (!mounted) return;
      setState(() => _isSending = false);

      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось отправить сообщение'.tr), backgroundColor: Colors.red),
        );
        _textController.text = text;
        setState(() {
          _attachments
            ..clear()
            ..addAll(pending);
        });
      } else {
        Future.delayed(const Duration(milliseconds: 200), () {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSending = false;
        _textController.text = text;
        _attachments
          ..clear()
          ..addAll(pending);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось отправить сообщение'.tr), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _pickAttachment() async {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.photo_camera, color: AppColors.primary),
                title: Text('Камера'.tr),
                onTap: () async {
                  Navigator.pop(context);
                  await _addAttachment(await OutboundMediaService.pickImage(ImageSource.camera));
                },
              ),
              ListTile(
                leading: Icon(Icons.photo_library, color: AppColors.primary),
                title: Text('Галерея'.tr),
                onTap: () async {
                  Navigator.pop(context);
                  await _addAttachment(await OutboundMediaService.pickImage(ImageSource.gallery));
                },
              ),
              ListTile(
                leading: Icon(Icons.attach_file, color: AppColors.primary),
                title: Text('Файл'.tr),
                onTap: () async {
                  Navigator.pop(context);
                  await _addAttachment(await OutboundMediaService.pickFile());
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _addAttachment(OutboundAttachment? file) async {
    if (file == null || !mounted) return;
    setState(() => _attachments.add(file));
  }

  Future<void> _openMedia(String url) async {
    final lower = url.toLowerCase();
    final isImage = lower.contains('.jpg') ||
        lower.contains('.jpeg') ||
        lower.contains('.png') ||
        lower.contains('.gif') ||
        lower.contains('.webp');
    if (isImage) {
      _openPhoto(url);
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _call() async {
    if (!_hasPhone) return;
    CallScreen.open(
      context,
      phoneNumber: _phone,
      contactName: _contactName.isEmpty ? widget.contactName : _contactName,
    );
  }

  Future<void> _openClientCard() async {
    Client? client;
    final id = (widget.clientId ?? '').trim();
    if (id.isNotEmpty) {
      client = await ClientService.getById(id);
    }
    client ??= await ClientService.findByPhone(_phone);
    if (client == null && _email.contains('@')) {
      client = await ClientService.findByEmail(_email);
    }
    if (!mounted) return;
    if (client == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Нет карточки клиента'.tr)),
      );
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ClientDetailsScreen(
          clientId: client!.id,
          clientData: client.toUiMap(),
        ),
      ),
    );
  }

  void _openPhoto(String url) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
          body: Center(
            child: InteractiveViewer(
              minScale: 0.8,
              maxScale: 4,
              child: Image.network(
                url,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.white54, size: 64),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showSmsTemplates() async {
    final templates = await SettingsService.loadSmsTemplates();
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Шаблоны сообщений'.tr,
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.directions_car, color: Colors.green),
                title: Text('Я в пути'.tr),
                subtitle: Text(
                  templates['on_way'] ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.pop(context);
                  setState(() => _textController.text = templates['on_way'] ?? '');
                },
              ),
              ListTile(
                leading: const Icon(Icons.inventory, color: Colors.orange),
                title: Text('Запчасть заказана'.tr),
                subtitle: Text(
                  templates['part_ordered'] ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.pop(context);
                  setState(() => _textController.text = templates['part_ordered'] ?? '');
                },
              ),
              ListTile(
                leading: const Icon(Icons.check_circle, color: Colors.blue),
                title: Text('Работа завершена'.tr),
                subtitle: Text(
                  templates['job_done'] ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.pop(context);
                  setState(() => _textController.text = templates['job_done'] ?? '');
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final thread = Column(
      children: [
        if (_peers.length > 1) _buildRecipientBar(),
        Expanded(
          child: StreamBuilder<List<SmsMessage>>(
            key: ValueKey('$_channel|$_phone|$_email'),
            stream: SmsService.streamConversation(
              _phone,
              email: _hasEmail ? _email : null,
              extraPhones: widget.extraPhones,
              emailsOnly: _channel == ConversationChannel.email,
            ),
            builder: (context, snapshot) {
              final key = '$_channel|$_phone|$_email';
              if (snapshot.hasData) {
                _threadCache[key] = snapshot.data!;
              }
              final messages = snapshot.data ?? _threadCache[key] ?? [];

              if (messages.isEmpty &&
                  snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              if (messages.isEmpty) {
                return Center(
                  child: Text(
                    _channel == ConversationChannel.email
                        ? 'Нет писем — напишите первым'.tr
                        : 'Нет SMS — напишите первым'.tr,
                    style: TextStyle(color: Colors.grey),
                  ),
                );
              }

              _visibleIds = [for (final message in messages) message.id];
              final lastId = messages.last.id;
              if (lastId != _lastJumpId) {
                _lastJumpId = lastId;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_scrollController.hasClients) {
                    _scrollController.jumpTo(
                      _scrollController.position.maxScrollExtent,
                    );
                  }
                });
              }

              return ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                itemCount: messages.length,
                itemBuilder: (context, index) => _buildBubble(messages[index]),
              );
            },
          ),
        ),
        _buildInputBar(),
      ],
    );

    if (widget.embedded) {
      return ColoredBox(
        color: Colors.grey.shade100,
        child: Column(
          children: [
            if (_selecting)
              SelectionActionBar(
                count: _selectedIds.length,
                onCancel: _clearSelection,
                onSelectAll: _selectAllVisible,
                onDelete: _deleteSelected,
              ),
            Expanded(child: thread),
          ],
        ),
      );
    }

    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _selecting) _clearSelection();
      },
      child: Scaffold(
        backgroundColor: Colors.grey.shade100,
        appBar: _selecting
            ? AppBar(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _clearSelection,
                ),
                title: Text('${_selectedIds.length}'),
                actions: [
                  IconButton(
                    tooltip: 'Выбрать все'.tr,
                    onPressed: _selectAllVisible,
                    icon: const Icon(Icons.select_all),
                  ),
                  IconButton(
                    tooltip: 'Удалить'.tr,
                    onPressed: _deleteSelected,
                    icon: const Icon(Icons.delete_outline, color: Color(0xFFFF8A80)),
                  ),
                ],
              )
            : AppBar(
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _contactName.isNotEmpty
                          ? _contactName
                          : (widget.contactName ??
                              (_hasPhone ? _phone : _email)),
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                    ),
                    if (_contactName.isNotEmpty || widget.contactName != null)
                      Text(
                        [
                          if (_hasPhone) _phone,
                          if (_hasEmail) _email,
                        ].join(' · '),
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
                      ),
                  ],
                ),
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                actions: [
                  IconButton(
                    icon: const Icon(Icons.person_outline),
                    tooltip: 'Карточка клиента'.tr,
                    onPressed: _openClientCard,
                  ),
                  if (_hasPhone)
                    IconButton(
                      icon: const Icon(Icons.call),
                      tooltip: 'Позвонить'.tr,
                      onPressed: _call,
                    ),
                ],
              ),
        body: thread,
      ),
    );
  }

  Widget _buildBubble(SmsMessage message) {
    final isOutbound = message.isOutbound;
    final selected = _selectedIds.contains(message.id);
    return GestureDetector(
      onLongPress: () => _toggleSelected(message.id),
      onTap: _selecting ? () => _toggleSelected(message.id) : null,
      child: Align(
      alignment: isOutbound ? Alignment.centerRight : Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_selecting && !isOutbound)
            Padding(
              padding: const EdgeInsets.only(right: 6, bottom: 10),
              child: SelectCheckbox(selected: selected),
            ),
          Flexible(
            child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: selected
              ? (isOutbound ? const Color(0xFF0D47A1) : const Color(0xFFE3F2FD))
              : (isOutbound ? AppColors.primary : Colors.white),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isOutbound ? 14 : 2),
            bottomRight: Radius.circular(isOutbound ? 2 : 14),
          ),
          boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 3, offset: Offset(0, 1))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  message.isEmail ? Icons.email : Icons.sms,
                  size: 14,
                  color: isOutbound
                      ? Colors.white70
                      : (message.isEmail ? const Color(0xFFEA4335) : Colors.indigo),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    message.isEmail
                        ? (isOutbound
                            ? '${'Кому'.tr}: ${message.toEmail.isNotEmpty ? message.toEmail : message.to}'
                            : '${'От'.tr}: ${message.fromEmail.isNotEmpty ? message.fromEmail : message.from}')
                        : (isOutbound ? 'SMS'.tr : '${'От'.tr}: ${message.from}'),
                    style: TextStyle(
                      color: isOutbound ? Colors.white70 : Colors.grey.shade600,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (message.isEmail && message.subject.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                message.subject.trim(),
                style: TextStyle(
                  color: isOutbound ? Colors.white : Colors.black87,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            const SizedBox(height: 6),
            if (message.mediaUrls.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  children: [
                    for (final url in message.mediaUrls)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: _buildMediaPreview(url, isOutbound),
                      ),
                  ],
                ),
              )
            else if (message.hasPendingMedia ||
                (message.body.trim().isEmpty && message.aiStatus == 'processing'))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  height: 120,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (message.aiStatus == 'processing')
                        const Padding(
                          padding: EdgeInsets.only(bottom: 8),
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      Text(
                        message.aiStatus == 'processing' ? 'Загружается фото…'.tr : 'Фото'.tr,
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                    ],
                  ),
                ),
              ),
            if (message.body.trim().isNotEmpty)
              _TranslatedMessageBody(
                message: message,
                isOutbound: isOutbound,
              ),
            if (message.extractedData != null &&
                (message.extractedData!['model'] != null ||
                    message.extractedData!['brand'] != null))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  [
                    if (message.extractedData!['brand'] != null)
                      '${'Бренд'.tr}: ${message.extractedData!['brand']}',
                    if (message.extractedData!['model'] != null)
                      '${'Модель'.tr}: ${message.extractedData!['model']}',
                    if (message.jobId != null) 'Добавлено в заявку'.tr,
                  ].join(' · '),
                  style: TextStyle(
                    color: isOutbound ? Colors.white70 : AppColors.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                message.createdAt != null ? DateFormat('HH:mm').format(message.createdAt!) : '',
                style: TextStyle(
                  color: isOutbound ? Colors.white70 : Colors.grey.shade500,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
      ),
          ),
          if (_selecting && isOutbound)
            Padding(
              padding: const EdgeInsets.only(left: 6, bottom: 10),
              child: SelectCheckbox(selected: selected),
            ),
        ],
      ),
    ),
    );
  }

  Widget _buildMediaPreview(String url, bool isOutbound) {
    final lower = url.toLowerCase();
    final isImage = lower.contains('.jpg') ||
        lower.contains('.jpeg') ||
        lower.contains('.png') ||
        lower.contains('.gif') ||
        lower.contains('.webp');
    if (isImage) {
      return GestureDetector(
        onTap: () => _openMedia(url),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.network(
            url,
            height: 180,
            width: double.infinity,
            fit: BoxFit.cover,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return const SizedBox(
                height: 180,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              );
            },
            errorBuilder: (_, __, ___) => _fileTile(url, isOutbound),
          ),
        ),
      );
    }
    return _fileTile(url, isOutbound);
  }

  Widget _fileTile(String url, bool isOutbound) {
    final name = Uri.tryParse(url)?.pathSegments.last.replaceAll(RegExp(r'^\d+_'), '') ??
        'Файл'.tr;
    return Material(
      color: isOutbound ? Colors.white12 : Colors.grey.shade100,
      borderRadius: BorderRadius.circular(8),
      child: ListTile(
        dense: true,
        leading: Icon(
          Icons.insert_drive_file,
          color: isOutbound ? Colors.white : AppColors.primary,
        ),
        title: Text(
          Uri.decodeComponent(name),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isOutbound ? Colors.white : Colors.black87,
            fontSize: 13,
          ),
        ),
        onTap: () => _openMedia(url),
      ),
    );
  }

  Future<void> _openComposeSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) {
        return _ComposeMessageSheet(
          initialText: _textController.text,
          channel: _channel,
          sending: _isSending,
          onChanged: (value) => _textController.text = value,
          onSend: () async {
            Navigator.pop(sheetContext);
            await _send();
          },
        );
      },
    );
    if (mounted) setState(() {});
  }

  Widget _buildRecipientBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      color: Colors.grey.shade100,
      child: Row(
        children: [
          Text(
            'Кому'.tr,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.black54,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                value: _peers.any((peer) => peer.id == _peerId)
                    ? _peerId
                    : _peers.first.id,
                items: [
                  for (final peer in _peers)
                    DropdownMenuItem(
                      value: peer.id,
                      child: Text(
                        '${peer.label} — ${peer.displayName}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (id) {
                  if (id == null) return;
                  final peer = _peers.cast<ConversationPeer?>().firstWhere(
                    (item) => item?.id == id,
                    orElse: () => null,
                  );
                  if (peer != null) _selectPeer(peer);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: EdgeInsets.only(
        left: 8,
        right: 12,
        top: 8,
        bottom: 8 + (widget.embedded ? 0 : MediaQuery.of(context).padding.bottom),
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, -2))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<ConversationChannel>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              segments: [
                ButtonSegment(
                  value: ConversationChannel.sms,
                  enabled: _hasPhone,
                  icon: const Icon(Icons.sms, size: 16),
                  label: Text('SMS'.tr),
                ),
                ButtonSegment(
                  value: ConversationChannel.email,
                  enabled: _hasEmail,
                  icon: const Icon(Icons.email, size: 16),
                  label: Text('Email'.tr),
                ),
              ],
              selected: {_channel},
              onSelectionChanged: (value) {
                setState(() => _channel = value.first);
                _markRead();
              },
            ),
          ),
          const SizedBox(height: 8),
          if (_attachments.isNotEmpty)
            SizedBox(
              height: 72,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _attachments.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final file = _attachments[index];
                  return Stack(
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: file.isImage
                            ? Image.memory(file.bytes, fit: BoxFit.cover)
                            : Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.insert_drive_file, color: AppColors.primary),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 4),
                                    child: Text(
                                      file.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 10),
                                    ),
                                  ),
                                ],
                              ),
                      ),
                      Positioned(
                        top: 0,
                        right: 0,
                        child: GestureDetector(
                          onTap: () => setState(() => _attachments.removeAt(index)),
                          child: const CircleAvatar(
                            radius: 10,
                            backgroundColor: Colors.black54,
                            child: Icon(Icons.close, size: 12, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          if (_attachments.isNotEmpty) const SizedBox(height: 8),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.attach_file),
                color: AppColors.primary,
                tooltip: 'Прикрепить'.tr,
                onPressed: _isSending ? null : _pickAttachment,
              ),
              IconButton(
                icon: const Icon(Icons.library_books),
                color: AppColors.primary,
                tooltip: 'Шаблоны'.tr,
                onPressed: _showSmsTemplates,
              ),
              Expanded(
                child: Material(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(22),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(22),
                    onTap: _isSending ? null : _openComposeSheet,
                    child: Container(
                      height: 40,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _textController.text.trim().isEmpty
                            ? (_channel == ConversationChannel.email
                                ? 'Пишите по-русски — клиенту уйдёт на английском'.tr
                                : 'Пишите по-русски — клиенту уйдёт на английском'.tr)
                            : _textController.text.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          color: _textController.text.trim().isEmpty
                              ? Colors.grey.shade600
                              : const Color(0xFF1A1A1A),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _isSending
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : IconButton(
                      onPressed: _send,
                      icon: Icon(_channel == ConversationChannel.email ? Icons.email : Icons.send),
                      style: IconButton.styleFrom(
                        backgroundColor: _channel == ConversationChannel.email
                            ? const Color(0xFFEA4335)
                            : AppColors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.all(12),
                      ),
                    ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ComposeMessageSheet extends StatefulWidget {
  final String initialText;
  final ConversationChannel channel;
  final bool sending;
  final ValueChanged<String> onChanged;
  final Future<void> Function() onSend;

  const _ComposeMessageSheet({
    required this.initialText,
    required this.channel,
    required this.sending,
    required this.onChanged,
    required this.onSend,
  });

  @override
  State<_ComposeMessageSheet> createState() => _ComposeMessageSheetState();
}

class _ComposeMessageSheetState extends State<_ComposeMessageSheet> {
  late final TextEditingController _controller;
  final GlobalKey _polishKey = GlobalKey();
  bool _polishing = false;
  String? _polishSource;
  String? _lastPolished;
  int _polishVariant = 0;
  String _emojiLevel = 'normal';
  bool _showPolishMenu = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _controller.addListener(() => widget.onChanged(_controller.text));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _polish({String? emoji}) async {
    final text = _controller.text.trim();
    if (text.isEmpty || _polishing) return;
    if (emoji != null) _emojiLevel = emoji;
    if (_polishSource == null || text != _lastPolished) {
      _polishSource = text;
    }
    setState(() => _polishing = true);
    _polishVariant += 1;
    final out = await MessageTranslateService.polish(
      _polishSource!,
      variant: _polishVariant,
      emoji: _emojiLevel,
      previous: _lastPolished ?? '',
    );
    if (!mounted) return;
    final offerMenu = !_showPolishMenu;
    setState(() {
      _polishing = false;
      _showPolishMenu = true;
    });
    if (out.trim().isNotEmpty) {
      _lastPolished = out.trim();
      _controller.value = TextEditingValue(
        text: out,
        selection: TextSelection.collapsed(offset: out.length),
      );
    }
    if (offerMenu) {
      await Future<void>.delayed(const Duration(milliseconds: 160));
      if (mounted) await _openPolishMenu();
    }
  }

  Future<void> _openPolishMenu() async {
    final box = _polishKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final origin = box.localToGlobal(Offset.zero);
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        origin.dx,
        origin.dy - 8,
        origin.dx + box.size.width,
        origin.dy,
      ),
      items: [
        PopupMenuItem(
          value: 'more',
          child: Text(
            _emojiLevel == 'more' ? '✓ Больше эмодзи'.tr : 'Больше эмодзи'.tr,
          ),
        ),
        PopupMenuItem(
          value: 'less',
          child: Text(
            _emojiLevel == 'less' ? '✓ Меньше эмодзи'.tr : 'Меньше эмодзи'.tr,
          ),
        ),
        PopupMenuItem(
          value: 'normal',
          child: Text(
            _emojiLevel == 'normal' ? '✓ Обычные эмодзи'.tr : 'Обычные эмодзи'.tr,
          ),
        ),
      ],
    );
    if (selected == null || !mounted) return;
    await _polish(emoji: selected);
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + inset),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.62,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Сообщение'.tr,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 18,
                color: Color(0xFF1A1A1A),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: TextField(
                controller: _controller,
                autofocus: true,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Пишите по-русски — клиенту уйдёт на английском'.tr,
                  filled: true,
                  fillColor: Colors.grey.shade100,
                  contentPadding: const EdgeInsets.all(16),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: _polishKey,
                    onPressed: _polishing ? null : () => _polish(),
                    onLongPress: _polishing ? null : _openPolishMenu,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (_polishing)
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          const Icon(Icons.auto_fix_high, size: 20),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            _showPolishMenu
                                ? 'Ещё вариант'.tr
                                : 'Оформить и эмодзи'.tr,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          onPressed: _polishing ? null : _openPolishMenu,
                          icon: const Icon(Icons.expand_less, size: 22),
                          tooltip: 'Больше / меньше эмодзи'.tr,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: widget.sending ? null : widget.onSend,
                  style: FilledButton.styleFrom(
                    backgroundColor: widget.channel == ConversationChannel.email
                        ? const Color(0xFFEA4335)
                        : AppColors.primary,
                    foregroundColor: Colors.white,
                  ),
                  icon: Icon(
                    widget.channel == ConversationChannel.email
                        ? Icons.email
                        : Icons.send,
                  ),
                  label: Text('Отправить'.tr),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TranslatedMessageBody extends StatefulWidget {
  final SmsMessage message;
  final bool isOutbound;

  const _TranslatedMessageBody({
    required this.message,
    required this.isOutbound,
  });

  @override
  State<_TranslatedMessageBody> createState() => _TranslatedMessageBodyState();
}

class _TranslatedMessageBodyState extends State<_TranslatedMessageBody> {
  late String _display;
  String? _original;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _display = widget.message.displayBody;
    final ru = widget.message.bodyRu.trim();
    final original = widget.message.body.trim();
    if (ru.isNotEmpty && original.isNotEmpty && ru != original) {
      _original = widget.message.isOutbound ? original : original;
    }
    _maybeTranslateInbound();
  }

  @override
  void didUpdateWidget(covariant _TranslatedMessageBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.id != widget.message.id ||
        oldWidget.message.body != widget.message.body ||
        oldWidget.message.bodyRu != widget.message.bodyRu) {
      _display = widget.message.displayBody;
      final ru = widget.message.bodyRu.trim();
      final original = widget.message.body.trim();
      _original = (ru.isNotEmpty && original.isNotEmpty && ru != original)
          ? original
          : null;
      _maybeTranslateInbound();
    }
  }

  Future<void> _maybeTranslateInbound() async {
    final message = widget.message;
    if (message.isOutbound) return;
    final existingRu = message.bodyRu.trim();
    final alreadyTranslated = existingRu.isNotEmpty &&
        existingRu != message.body.trim() &&
        MessageTranslateService.looksRussian(existingRu);
    if (alreadyTranslated) return;
    if (!MessageTranslateService.needsRussian(message.body)) return;
    setState(() => _loading = true);
    final ru = await MessageTranslateService.toRussian(message.body);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (ru.trim().isNotEmpty) {
        _display = ru;
        if (ru.trim() != message.body.trim()) {
          _original = message.body.trim();
        }
      }
    });
    if (ru.trim().isNotEmpty && ru.trim() != message.body.trim()) {
      await SmsService.saveBodyRu(message.id, ru);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.isOutbound ? Colors.white : Colors.black87;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_loading)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'Перевод...'.tr,
              style: TextStyle(
                color: widget.isOutbound ? Colors.white70 : Colors.black54,
                fontSize: 12,
              ),
            ),
          ),
        Text(
          _display,
          style: TextStyle(color: color, fontSize: 15),
        ),
        if (_original != null && _original!.trim() != _display.trim()) ...[
          const SizedBox(height: 6),
          Text(
            _original!,
            style: TextStyle(
              color: widget.isOutbound ? Colors.white70 : Colors.black54,
              fontSize: 11,
              height: 1.3,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ],
    );
  }
}

