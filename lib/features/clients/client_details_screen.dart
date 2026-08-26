import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../../core/constants.dart';
import '../../services/services.dart';
import '../jobs/job_details/job_details_screen.dart';
import '../jobs/job_details/editors/call_recording_page.dart';
import '../jobs/create_job_screen.dart';
import '../calls/call_screen.dart';
import '../messages/conversation_screen.dart';
import '../../core/l10n/app_locale.dart';
import '../../models/job.dart';
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

  @override
  void initState() {
    super.initState();
    _historyTabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _historyTabs.dispose();
    super.dispose();
  }

  void _makeCall(String phone, String name) {
    if (phone.isEmpty) return;
    CallScreen.open(context, phoneNumber: phone, contactName: name);
  }

  Future<void> _sendSms(String phone, String name, {String? email}) async {
    final peers = await ConversationPeer.loadForClient(
      clientId: widget.clientId,
      name: name,
      phone: phone,
      email: email ?? '',
    );
    if (!mounted) return;
    ConversationPeer? chosen = peers.isEmpty
        ? ConversationPeer(
            id: 'owner',
            label: 'Хозяин'.tr,
            name: name,
            phone: phone,
            email: email ?? '',
          )
        : peers.first;
    if (peers.length > 1) {
      chosen = await showModalBottomSheet<ConversationPeer>(
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
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Кому написать?'.tr,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
                for (final peer in peers)
                  ListTile(
                    leading: Icon(
                      peer.id == 'owner' ? Icons.person : Icons.location_on,
                      color: AppColors.primary,
                    ),
                    title: Text(peer.displayName),
                    subtitle: Text(
                      [
                        peer.label,
                        if (peer.hasPhone) peer.phone,
                        if (peer.hasEmail) peer.email,
                      ].join(' · '),
                    ),
                    onTap: () => Navigator.pop(context, peer),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      );
      if (chosen == null || !mounted) return;
    }
    if (chosen.phone.isEmpty && !chosen.hasEmail) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ConversationScreen(
          phoneNumber: chosen!.phone,
          email: chosen.hasEmail ? chosen.email : null,
          contactName: chosen.displayName,
          clientId: widget.clientId,
          recipients: peers.length > 1 ? peers : const [],
        ),
      ),
    );
  }

  String _extractClientName(Map<String, dynamic> data) {
    for (final key in ['fullName', 'name', 'clientName']) {
      final value = data[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return 'Без имени'.tr;
  }

  void _openNewJob(String name, String phone, String address, {String? email, String? company}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CreateJobScreen(
          existingClientId: widget.clientId,
          initialName: name,
          initialPhone: phone,
          initialAddress: address,
          initialEmail: email,
          initialCompany: company,
        ),
      ),
    );
  }

  Future<void> _deleteClient(String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (context) => AlertDialog(
        title: Text('Удалить клиента?'.tr),
        content: Text('$name\n\n${'Карточка будет удалена. Заявки в календаре останутся.'.tr}'),
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
    await ClientService.delete(widget.clientId);
    if (!mounted) return;
    Navigator.pop(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text('Клиент удалён'.tr),
        backgroundColor: Colors.red,
      ),
    );
  }

  void _editClientDialog(Map<String, dynamic> currentData) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.white,
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


  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirestoreService.clientsRef.doc(widget.clientId).snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data() as Map<String, dynamic>? ?? widget.clientData;
        final name = _extractClientName(data);
        final phone = data['phone'] ?? '';
        final address = data['address'] ?? '';
        final company = data['companyName'] ?? data['company'] ?? '';
        final email = (data['email'] ?? '').toString();
        final notes = (data['notes'] ?? data['description'] ?? '').toString();
        final source = (data['source'] ?? '').toString();
        final topInset = MediaQuery.viewPaddingOf(context).top;

        return Scaffold(
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _openNewJob(name, phone, address, email: email, company: company),
            backgroundColor: AppColors.accent,
            foregroundColor: Colors.black,
            icon: const Icon(Icons.add),
            label: Text('Новый ремонт'.tr),
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
                      SizedBox(height: topInset),
                      Row(
                        children: [
                          _headerIcon(
                            icon: Icons.arrow_back,
                            onTap: () => Navigator.maybePop(context),
                          ),
                          _headerIcon(
                            icon: Icons.delete,
                            color: Colors.red,
                            tooltip: 'Удалить клиента'.tr,
                            onTap: () => _deleteClient(name),
                          ),
                          const Spacer(),
                          _headerIcon(
                            icon: Icons.edit,
                            tooltip: 'Изменить'.tr,
                            onTap: () => _editClientDialog(data),
                          ),
                        ],
                      ),
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
                      Text(
                        name,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      if (company.isNotEmpty)
                        Text(
                          company,
                          style: const TextStyle(color: Colors.white70),
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
                          ),
                          const SizedBox(width: 16),
                          _buildActionButton(
                            icon: Icons.forum,
                            label: 'Написать'.tr,
                            color: const Color(0xFF1E88E5),
                            onTap: () => _sendSms(phone, name, email: email),
                          ),
                          const SizedBox(width: 16),
                          _buildActionButton(
                            icon: Icons.navigation,
                            label: 'Маршрут'.tr,
                            color: const Color(0xFFFF9800),
                            onTap: () => MapsService.openNavigator(address),
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
                      _buildInfoCard(
                        icon: Icons.campaign_outlined,
                        title: 'Откуда узнали'.tr,
                        value: source.isEmpty ? 'Не указано'.tr : trAny(source),
                      ),
                      if (notes.isNotEmpty)
                        _buildInfoCard(
                          icon: Icons.notes,
                          title: 'Описание'.tr,
                          value: notes,
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

  Widget _headerIcon({
    required IconData icon,
    required VoidCallback onTap,
    Color color = Colors.white,
    String? tooltip,
  }) {
    final button = Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, color: color),
        ),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip, child: button);
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
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

  Widget _buildInfoCard({
    required IconData icon,
    required String title,
    required String value,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Row(
          children: [
            Icon(icon, color: AppColors.primary),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  Text(
                    value,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
            if (onTap != null)
              Icon(Icons.edit, color: Colors.grey.shade400, size: 18),
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

  Widget _buildCallHistory(Map<String, dynamic> data) {
    final phones = _phoneKeys(data);
    return StreamBuilder<List<CallRecord>>(
      stream: TwilioService.streamAll(),
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
      stream: JobService.streamByClient(widget.clientId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final jobs = snapshot.data ?? [];

        if (jobs.isEmpty) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 88),
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    'Нет заявок'.tr,
                    style: const TextStyle(color: Colors.grey),
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

            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: StatusService.colorOf(status).withOpacity(0.3)),
              ),
              child: ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: StatusService.colorOf(status).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    ApplianceCategories.getIcon(applianceType),
                    color: StatusService.colorOf(status),
                  ),
                ),
                title: Text(
                  trAny(applianceType),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  [
                    if (visits.length > 1)
                      '${visits.length} ${'визитов'.tr} · ${DateFormat('dd.MM.yyyy HH:mm').format(nextVisit!)}'
                    else if (nextVisit != null)
                      DateFormat('dd.MM.yyyy HH:mm').format(nextVisit)
                    else
                      'Дата не указана'.tr,
                    if (nextVisit != null) _ago(nextVisit),
                    if (job.isUnpaid) 'Неоплачено'.tr,
                    if (job.status == JobStatuses.completed) 'Прошлый визит'.tr,
                  ].join(' · '),
                ),
                trailing: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: StatusService.colorOf(status).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    trAny(status),
                    style: TextStyle(
                      color: StatusService.colorOf(status),
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => JobDetailsScreen(
                        jobId: job.id,
                        clientId: widget.clientId,
                        jobData: job.toMap(),
                      ),
                    ),
                  );
                },
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
