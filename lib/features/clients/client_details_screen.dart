import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../../core/app_feedback.dart';
import '../../core/constants.dart';
import '../../services/services.dart';
import '../jobs/job_details/job_details_screen.dart';
import '../jobs/job_details/editors/call_recording_page.dart';
import '../jobs/create_job_screen.dart';
import '../calls/call_screen.dart';
import '../messages/conversation_screen.dart';
import '../../core/l10n/app_locale.dart';
import '../../core/motion.dart';
import '../../models/client.dart';
import '../../models/contact.dart';
import '../../models/job.dart';
import '../../models/location.dart';
import '../../shared/app_nav.dart';
import '../../shared/stale_routes.dart';
import '../../shared/widgets/appliance_picture.dart';
import '../../shared/widgets/confirm_action_sheet.dart';
import '../care_plan/care_plan_section.dart';
import 'edit_client_sheet.dart';

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

class _ClientDetailsScreenState extends State<ClientDetailsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _historyTabs;
  Stream<List<CallRecord>>? _callsStream;
  String _callsKey = '';
  Stream<DocumentSnapshot>? _clientStream;
  late Stream<List<Job>> _jobsStream;
  StreamSubscription<DocumentSnapshot>? _goneSub;
  bool? _optimisticRegular;

  @override
  void initState() {
    super.initState();
    _historyTabs = TabController(length: 2, vsync: this);
    _bindClient();
  }

  void _bindClient() {
    _optimisticRegular = null;
    _clientStream = widget.clientId.isEmpty
        ? null
        : FirestoreService.clientsRef.doc(widget.clientId).snapshots();
    _jobsStream = JobService.streamByClient(widget.clientId);
    _watchGone();
  }

  /// Клиента удалили или отправили в корзину (здесь, при объединении
  /// дублей, на другом устройстве) — снимаем все его карточки со стека.
  /// Карточку, открытую уже из корзины, не закрываем.
  void _watchGone() {
    _goneSub?.cancel();
    final id = widget.clientId;
    StaleRoutes.watchClient(id, this);
    if (id.isEmpty) return;
    var seenAlive = false;
    _goneSub = FirestoreService.clientsRef.doc(id).snapshots().listen((snap) {
      final data = snap.exists ? snap.data() as Map<String, dynamic>? : null;
      if (data == null) {
        if (seenAlive || !snap.metadata.isFromCache) {
          StaleRoutes.dropClient(id);
        }
      } else if (!StaleRoutes.isTrashed(data, snap.metadata)) {
        seenAlive = true;
      } else if (seenAlive) {
        StaleRoutes.dropClient(id);
      }
    });
  }

  @override
  void didUpdateWidget(covariant ClientDetailsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clientId != widget.clientId) {
      StaleRoutes.unwatchClient(oldWidget.clientId, this);
      _bindClient();
    }
  }

  @override
  void dispose() {
    _goneSub?.cancel();
    StaleRoutes.unwatchClient(widget.clientId, this);
    _historyTabs.dispose();
    super.dispose();
  }

  Future<void> _makeCall(String phone, String name) async {
    final peers = await ConversationPeer.loadForClient(
      clientId: widget.clientId,
      name: name,
      phone: phone,
    );
    if (!mounted) return;
    final chosen = peers.isEmpty
        ? ConversationPeer(
            id: 'owner',
            label: 'Хозяин'.tr,
            name: name,
            phone: phone,
          )
        : await ConversationPeer.pick(
            context,
            peers,
            title: 'Кому позвонить?'.tr,
            phoneOnly: true,
          );
    if (chosen == null || !mounted || chosen.phone.trim().isEmpty) return;
    CallScreen.open(
      context,
      phoneNumber: chosen.phone,
      contactName: chosen.displayName,
    );
  }

  Future<void> _sendSms(String phone, String name, {String? email}) async {
    final peers = await ConversationPeer.loadForClient(
      clientId: widget.clientId,
      name: name,
      phone: phone,
      email: email ?? '',
    );
    if (!mounted) return;
    final chosen = peers.isEmpty
        ? ConversationPeer(
            id: 'owner',
            label: 'Хозяин'.tr,
            name: name,
            phone: phone,
            email: email ?? '',
          )
        : await ConversationPeer.pick(
            context,
            peers,
            title: 'Кому написать?'.tr,
          );
    if (chosen == null || !mounted) return;
    if (chosen.phone.isEmpty && !chosen.hasEmail) return;
    await AppNav.openCard(
      context,
      key: AppNav.chatKey(
        phone: chosen.phone,
        email: chosen.hasEmail ? chosen.email : null,
      ),
      builder: (context) => ConversationScreen(
        phoneNumber: chosen.phone,
        email: chosen.hasEmail ? chosen.email : null,
        contactName: chosen.displayName,
        clientId: widget.clientId,
        recipients: peers,
      ),
    );
  }

  String _extractClientName(Map<String, dynamic> data) {
    return Client.extractName(data, fallback: 'Без имени'.tr);
  }

  void _openNewJob(String name, String phone, String address, {String? email, String? company}) {
    final cleanName = name == 'Без имени'.tr ? phone : name;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CreateJobScreen(
          existingClientId: widget.clientId,
          initialName: cleanName,
          initialPhone: phone,
          initialAddress: address,
          initialEmail: email,
          initialCompany: company,
        ),
      ),
    );
  }

  Future<void> _deleteClient(String name) async {
    final confirm = await showConfirmCancelSheet(
      context,
      title: 'Удалить клиента?'.tr,
      message:
          '$name\n\n${'Карточка будет удалена. Заявки в календаре останутся.'.tr}',
      confirmLabel: 'Удалить'.tr,
    );
    if (!confirm || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final clientId = widget.clientId;
    await ClientService.delete(clientId);
    StaleRoutes.dropClient(clientId);
    messenger.showSnackBar(
      SnackBar(
        content: Text('Клиент удалён'.tr),
        backgroundColor: Colors.red,
      ),
    );
  }

  /// Заявку можно убрать прямо из истории клиента — корзина на плитке,
  /// чтобы не открывать карточку заявки ради удаления.
  Future<void> _deleteJob(Job job) async {
    final confirm = await showConfirmCancelSheet(
      context,
      title: 'Удалить заявку?'.tr,
      message:
          'Заявка попадёт в корзину на 30 дней. Потом удалится навсегда.'.tr,
      confirmLabel: 'Удалить'.tr,
    );
    if (!confirm || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    await JobService.delete(job.id);
    // Та же заявка может быть открыта глубже в стеке — снимаем её с экрана,
    // иначе «Назад» вернёт на удалённую карточку.
    StaleRoutes.dropJob(job.id);
    messenger.showSnackBar(
      SnackBar(
        content: Text('Заявка удалена'.tr),
        backgroundColor: Colors.red,
      ),
    );
  }

  void _editClientDialog(Map<String, dynamic> currentData) {
    showModalBottomSheet(
      sheetAnimationStyle: AppMotion.sheet,
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => EditClientSheet(
        clientId: widget.clientId,
        currentData: currentData,
        extractName: _extractClientName,
      ),
    );
  }


  Future<void> _toggleRegular(
    Map<String, dynamic> currentData,
    bool current,
  ) async {
    if (widget.clientId.trim().isEmpty) return;
    final next = !current;
    AppFeedback.selection();
    setState(() => _optimisticRegular = next);
    await ClientService.setRegular(
      widget.clientId,
      next,
      currentData: currentData,
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: _clientStream,
      builder: (context, snapshot) {
        final remoteData =
            snapshot.data?.data() as Map<String, dynamic>?;
        final data = remoteData ?? widget.clientData;
        if (remoteData != null) {
          ClientService.noteClientMap(widget.clientId, remoteData);
          if (_optimisticRegular != null &&
              (remoteData['isRegular'] == true) == _optimisticRegular) {
            _optimisticRegular = null;
          }
        }
        final isRegular = _optimisticRegular ??
            ClientService.isRegularMap(data, widget.clientId);
        final name = _extractClientName(data);
        final phone = data['phone'] ?? '';
        final address = data['address'] ?? '';
        final company = data['companyName'] ?? data['company'] ?? '';
        final email = (data['email'] ?? '').toString();
        final notes = (data['notes'] ?? data['description'] ?? '').toString();
        final source =
            (data['source'] ?? data['referralSource'] ?? '').toString().trim();
        final topInset = MediaQuery.viewPaddingOf(context).top;

        return Scaffold(
          // «Изменить», «Новый ремонт» и «Удалить» — внизу, под большим пальцем.
          bottomNavigationBar: SafeArea(
            minimum: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: Row(
              children: [
                IconButton.filledTonal(
                  tooltip: 'Удалить клиента'.tr,
                  iconSize: 26,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(52, 52),
                    foregroundColor: Colors.red,
                    backgroundColor: Colors.red.withValues(alpha: 0.1),
                  ),
                  onPressed: () => _deleteClient(name),
                  icon: const Icon(Icons.delete_outline),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    height: 52,
                    child: ElevatedButton.icon(
                      onPressed: () => _openNewJob(name, phone, address, email: email, company: company),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: Colors.black,
                        elevation: 2,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: const Icon(Icons.add),
                      label: Text(
                        'Новый ремонт'.tr,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton.filledTonal(
                  tooltip: 'Изменить'.tr,
                  iconSize: 26,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(52, 52),
                    foregroundColor: AppColors.primaryOnCard,
                    backgroundColor: AppColors.primary.withValues(alpha: 0.14),
                  ),
                  onPressed: () =>
                      _editClientDialog({...data, 'isRegular': isRegular}),
                  icon: const Icon(Icons.edit),
                ),
              ],
            ),
          ),
          body: NestedScrollView(
            headerSliverBuilder: (context, innerBoxIsScrolled) => [
              SliverToBoxAdapter(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(4, 2, 8, 16),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: const BorderRadius.only(
                      bottomLeft: Radius.circular(24),
                      bottomRight: Radius.circular(24),
                    ),
                  ),
                  child: Column(
                    children: [
                      SizedBox(height: topInset + 12),
                      CircleAvatar(
                        radius: 28,
                        backgroundColor: Colors.white,
                        child: Text(
                          name.isNotEmpty ? name[0].toUpperCase() : '?',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                name,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Tooltip(
                              message: 'Постоянный клиент'.tr,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _toggleRegular(data, isRegular),
                                child: Padding(
                                  padding: const EdgeInsets.all(4),
                                  child: Icon(
                                    isRegular
                                        ? Icons.star_rounded
                                        : Icons.star_border_rounded,
                                    color: isRegular
                                        ? AppColors.accent
                                        : Colors.white54,
                                    size: 28,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (company.isNotEmpty)
                        Text(
                          company,
                          style: const TextStyle(color: Colors.white70),
                        ),
                      const SizedBox(height: 8),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _toggleRegular(data, isRegular),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: isRegular
                                ? AppColors.accent.withValues(alpha: 0.18)
                                : Colors.white.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isRegular
                                  ? AppColors.accent
                                  : Colors.white24,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isRegular
                                    ? Icons.star_rounded
                                    : Icons.star_border_rounded,
                                size: 16,
                                color: isRegular
                                    ? AppColors.accent
                                    : Colors.white70,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                'Постоянный клиент'.tr,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: isRegular
                                      ? AppColors.accent
                                      : Colors.white70,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _buildActionButton(
                            icon: Icons.phone,
                            label: 'Позвонить'.tr,
                            color: const Color(0xFF25D366),
                            onTap: () => _makeCall(phone, name),
                            onLongPress: phone.isNotEmpty ? () => AppFeedback.copy(context, phone) : null,
                          ),
                          const SizedBox(width: 16),
                          _buildActionButton(
                            icon: Icons.forum,
                            label: 'Написать'.tr,
                            color: const Color(0xFF1E88E5),
                            onTap: () => _sendSms(phone, name, email: email),
                            onLongPress: phone.isNotEmpty ? () => AppFeedback.copy(context, phone) : (email.isNotEmpty ? () => AppFeedback.copy(context, email) : null),
                          ),
                          const SizedBox(width: 16),
                          _buildActionButton(
                            icon: Icons.navigation,
                            label: 'Маршрут'.tr,
                            color: const Color(0xFFFF9800),
                            onTap: () => MapsService.openNavigator(address),
                            onLongPress: address.isNotEmpty ? () => AppFeedback.copy(context, address) : null,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildInfoCard(
                        icon: Icons.phone,
                        title: 'Телефон'.tr,
                        value: phone.isEmpty ? 'Не указан'.tr : phone,
                      ),
                      _buildInfoCard(
                        icon: Icons.email_outlined,
                        title: 'Электронный адрес'.tr,
                        value: email.isEmpty ? 'Не указан'.tr : email,
                      ),
                      _buildInfoCard(
                        icon: Icons.location_on,
                        title: 'Адрес'.tr,
                        value: address.isEmpty ? 'Не указан'.tr : address,
                      ),
                      if (source.isNotEmpty)
                        _buildInfoCard(
                          icon: Icons.campaign_outlined,
                          title: 'Откуда узнали'.tr,
                          value: trAny(source),
                        ),
                      if (notes.isNotEmpty)
                        _buildInfoCard(
                          icon: Icons.notes,
                          title: 'Описание'.tr,
                          value: notes,
                        ),
                      ..._filledExtraCards(data, phone, address),
                      if (widget.clientId.isNotEmpty)
                        CarePlanSection(
                          clientId: widget.clientId,
                          clientData: data,
                        ),
                    ],
                  ),
                ),
              ),
              SliverPersistentHeader(
                pinned: true,
                delegate: _HistoryTabBarDelegate(
                  TabBar(
                    controller: _historyTabs,
                    labelColor: AppColors.primary,
                    unselectedLabelColor: Colors.grey.shade600,
                    indicatorColor: AppColors.primary,
                    indicatorWeight: 3,
                    tabs: [
                      Tab(text: 'История заявок'.tr),
                      Tab(text: 'История звонков'.tr),
                    ],
                  ),
                ),
              ),
            ],
            body: TabBarView(
              controller: _historyTabs,
              children: [
                _buildJobsHistory(),
                _buildCallHistory(data),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }

  /// То, что заполнено в окне «Изменить», но выше уже не показано:
  /// второй адрес, другой контакт, почта контакта.
  List<Widget> _filledExtraCards(
    Map<String, dynamic> data,
    String phone,
    String address,
  ) {
    final cards = <Widget>[];
    final raw = data['locations'];
    if (raw is! List) return cards;
    final mainPhone = phone.trim();
    final mainAddress = address.trim();
    for (final item in raw) {
      if (item is! Map) continue;
      final loc = Location.fromMap(Map<String, dynamic>.from(item));
      final locAddress = loc.fullAddress.trim();
      if (locAddress.isNotEmpty && locAddress != mainAddress) {
        cards.add(
          _buildInfoCard(
            icon: Icons.home_outlined,
            title: 'Адрес'.tr,
            value: locAddress,
          ),
        );
      }
      if ((loc.notes ?? '').trim().isNotEmpty) {
        cards.add(
          _buildInfoCard(
            icon: Icons.sticky_note_2_outlined,
            title: 'Заметка к адресу'.tr,
            value: loc.notes!.trim(),
          ),
        );
      }
      for (final contact in loc.contacts) {
        cards.addAll(_contactCards(contact, mainPhone));
      }
    }
    return cards;
  }

  List<Widget> _contactCards(Contact contact, String mainPhone) {
    final name = contact.name.trim();
    final phone = contact.phone.trim();
    final samePhone = phone.isNotEmpty && phone == mainPhone;
    if (name.isEmpty && (phone.isEmpty || samePhone)) return const [];
    final value = [
      if (name.isNotEmpty) name,
      if (phone.isNotEmpty && !samePhone) phone,
      if (contact.role != 'owner') trAny(contact.roleLabel),
    ].join(' · ');
    return [
      _buildInfoCard(
        icon: Icons.person_outline,
        title: 'Контакт'.tr,
        value: value,
      ),
    ];
  }

  Widget _buildInfoCard({
    required IconData icon,
    required String title,
    required String value,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      onLongPress: () => AppFeedback.copy(context, value),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Icon(icon, color: AppColors.primaryOnCard),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(color: AppColors.inkMuted, fontSize: 12),
                  ),
                  Text(
                    value,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
            if (onTap != null)
              Icon(Icons.edit, color: AppColors.inkMuted, size: 18),
          ],
        ),
      ),
    );
  }

  String _ago(DateTime date) {
    final days = DateTime.now().difference(date).inDays;
    if (days <= 0) return 'сегодня'.tr;
    if (days == 1) return 'вчера'.tr;
    if (days < 21) return '$days ${'дн. назад'.tr}';
    if (days < 60) return '${(days / 7).floor()} ${'нед. назад'.tr}';
    return '${(days / 30).floor()} ${'мес. назад'.tr}';
  }

  Set<String> _phoneKeys(Map<String, dynamic> data) {
    final keys = <String>{};
    void add(String raw) {
      final n = SmsService.normalizePhone(raw);
      if (n.length >= 10) keys.add(n.substring(n.length - 10));
    }

    add((data['phone'] ?? '').toString());
    final locations = data['locations'];
    if (locations is List) {
      for (final loc in locations) {
        if (loc is! Map) continue;
        final contacts = loc['contacts'];
        if (contacts is! List) continue;
        for (final contact in contacts) {
          if (contact is Map) add((contact['phone'] ?? '').toString());
        }
      }
    }
    return keys;
  }

  String _callWhen(CallRecord call) {
    final at = call.startTime;
    if (at == null) return '';
    return DateFormat('dd.MM.yyyy HH:mm').format(at);
  }

  String _callLength(CallRecord call) {
    final seconds = call.durationSeconds ??
        (call.startTime != null && call.endTime != null
            ? call.endTime!.difference(call.startTime!).inSeconds
            : null);
    if (seconds == null || seconds <= 0) return '';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  bool _callMatches(CallRecord call, Set<String> phones) {
    bool hit(String raw) {
      final n = SmsService.normalizePhone(raw);
      if (n.length < 10) return false;
      return phones.contains(n.substring(n.length - 10));
    }

    final id = (call.clientId ?? '').trim();
    if (id.isNotEmpty && id == widget.clientId) return true;
    return hit(call.fromNumber) || hit(call.toNumber);
  }

  Stream<List<CallRecord>> _callsFor(Set<String> phones) {
    final key = (phones.toList()..sort()).join(',');
    if (_callsStream == null || key != _callsKey) {
      _callsKey = key;
      _callsStream = TwilioService.streamForContact(
        clientId: widget.clientId,
        phones: phones,
      );
    }
    return _callsStream!;
  }

  Widget _buildCallHistory(Map<String, dynamic> data) {
    final phones = _phoneKeys(data);
    return StreamBuilder<List<CallRecord>>(
      stream: _callsFor(phones),
      builder: (context, snapshot) {
        final calls = [
          for (final call in snapshot.data ?? const <CallRecord>[])
            if (!call.isDeleted && _callMatches(call, phones)) call,
        ];
        if (snapshot.connectionState == ConnectionState.waiting &&
            calls.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        if (calls.isEmpty) {
          return Center(
            child: Text(
              'Звонков пока нет'.tr,
              style: const TextStyle(color: Colors.grey),
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
          children: [
            for (final call in calls)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(
                    call.isIncoming ? Icons.call_received : Icons.call_made,
                    color: call.isIncoming
                        ? const Color(0xFF2EBD59)
                        : AppColors.primary,
                  ),
                  title: Text(
                    [
                      call.isIncoming ? 'Входящий'.tr : 'Исходящий'.tr,
                      _callWhen(call),
                    ].where((part) => part.trim().isNotEmpty).join(' · '),
                  ),
                  subtitle: Text(
                    [
                      call.isIncoming ? call.fromNumber : call.toNumber,
                      _callLength(call),
                      if ((call.summary ?? '').trim().isNotEmpty)
                        call.summary!.trim(),
                    ].where((part) => part.trim().isNotEmpty).join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => openCallRecordingSheet(
                    context,
                    call.toAttachment(),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildJobsHistory() {
    return StreamBuilder<List<Job>>(
      stream: _jobsStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final jobs = [...(snapshot.data ?? [])]
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

        if (jobs.isEmpty) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 88),
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: AppColors.cardMuted,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    'Нет заявок'.tr,
                    style: TextStyle(color: AppColors.inkMuted),
                  ),
                ),
              ),
            ],
          );
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
          children: jobs.map((job) {
            final status = job.status;
            final applianceType = job.applianceType;
            final visits = job.coalescedVisits;
            final nextVisit = job.scheduledAt ??
                (visits.isNotEmpty ? visits.last.startAt : null);
            final visitLabel = visits.length > 1
                ? '${visits.length} ${'визитов'.tr}'
                : visits.length == 1
                    ? '1 ${'визит'.tr}'
                    : '';
            final dateLabel = nextVisit == null
                ? 'Дата не указана'.tr
                : DateFormat('dd.MM.yyyy').format(nextVisit);
            final notes = [
              if (nextVisit != null) _ago(nextVisit),
              if (job.isUnpaid) 'Неоплачено'.tr,
              if (job.status == JobStatuses.completed) 'Прошлый визит'.tr,
            ].join(' · ');

            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: StatusService.colorOf(status).withOpacity(0.3)),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  AppNav.openCard(
                    context,
                    key: AppNav.jobKey(job.id),
                    builder: (context) => JobDetailsScreen(
                      jobId: job.id,
                      clientId: widget.clientId,
                      jobData: job.toMap(),
                    ),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
                  child: Row(
                    children: [
                      AppliancePicture(type: applianceType, size: 40),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(
                                    trAny(applianceType),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      dateLabel,
                                      style: TextStyle(
                                        color: AppColors.inkMuted,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    if (visitLabel.isNotEmpty)
                                      Text(
                                        visitLabel,
                                        style: TextStyle(
                                          color: AppColors.inkMuted,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Flexible(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: StatusService.colorOf(status).withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      trAny(status),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: StatusService.colorOf(status),
                                        fontWeight: FontWeight.bold,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                ),
                                if (notes.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      notes,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: AppColors.inkMuted,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Удалить заявку'.tr,
                        onPressed: () => _deleteJob(job),
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 36,
                          minHeight: 36,
                        ),
                        color: Colors.red,
                        icon: const Icon(Icons.delete_outline, size: 20),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }
}

class _HistoryTabBarDelegate extends SliverPersistentHeaderDelegate {
  _HistoryTabBarDelegate(this.tabBar);

  final TabBar tabBar;

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      elevation: overlapsContent ? 1 : 0,
      child: tabBar,
    );
  }

  @override
  bool shouldRebuild(covariant _HistoryTabBarDelegate oldDelegate) =>
      tabBar != oldDelegate.tabBar;
}
