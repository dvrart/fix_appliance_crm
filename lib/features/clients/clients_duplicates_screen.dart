import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../services/client_service.dart';
import '../../services/job_service.dart';
import 'client_details_screen.dart';

class ClientMatchGroup {
  final Set<String> reasons;
  final List<Map<String, dynamic>> clients;

  const ClientMatchGroup({required this.reasons, required this.clients});
}

class ClientsDuplicatesScreen extends StatefulWidget {
  final List<Map<String, dynamic>> clients;

  const ClientsDuplicatesScreen({super.key, required this.clients});

  static List<ClientMatchGroup> findGroups(List<Map<String, dynamic>> clients) {
    if (clients.length < 2) return [];

    final parent = List<int>.generate(clients.length, (i) => i);
    int find(int x) => parent[x] == x ? x : parent[x] = find(parent[x]);
    void union(int a, int b) {
      a = find(a);
      b = find(b);
      if (a != b) parent[b] = a;
    }

    final buckets = <String, List<int>>{};
    final reasonByKey = <String, String>{};

    void add(String key, String reason, int index) {
      buckets.putIfAbsent(key, () => <int>[]).add(index);
      reasonByKey[key] = reason;
    }

    for (var i = 0; i < clients.length; i++) {
      final data = clients[i];
      final phone = ClientService.normalizePhone((data['phone'] ?? '').toString());
      if (phone.length >= 7) {
        add('p:$phone', 'Телефон', i);
      }
      final email = (data['email'] ?? '').toString().trim().toLowerCase();
      if (email.contains('@')) {
        add('e:$email', 'Email', i);
      }
      final name = _normalizedName(data);
      final address = _normalizedAddress(data);
      if (name.isNotEmpty && address.isNotEmpty) {
        add('n:$name|$address', 'Имя и адрес', i);
      }
    }

    final reasonsByRoot = <int, Set<String>>{};
    for (final entry in buckets.entries) {
      final indexes = entry.value;
      if (indexes.length < 2) continue;
      final reason = reasonByKey[entry.key] ?? 'Совпадение';
      for (var i = 1; i < indexes.length; i++) {
        union(indexes[0], indexes[i]);
      }
      reasonsByRoot.putIfAbsent(find(indexes[0]), () => <String>{}).add(reason);
    }

    final remappedReasons = <int, Set<String>>{};
    for (final entry in reasonsByRoot.entries) {
      remappedReasons.putIfAbsent(find(entry.key), () => <String>{}).addAll(entry.value);
    }

    final members = <int, List<int>>{};
    for (var i = 0; i < clients.length; i++) {
      final root = find(i);
      if (!remappedReasons.containsKey(root)) continue;
      members.putIfAbsent(root, () => <int>[]).add(i);
    }

    final groups = <ClientMatchGroup>[];
    for (final entry in members.entries) {
      if (entry.value.length < 2) continue;
      final groupClients = entry.value.map((i) => clients[i]).toList()
        ..sort(_compareKeepers);
      groups.add(
        ClientMatchGroup(
          reasons: remappedReasons[entry.key] ?? {'Совпадение'},
          clients: groupClients,
        ),
      );
    }
    groups.sort((a, b) => b.clients.length.compareTo(a.clients.length));
    return groups;
  }

  static String _normalizedName(Map<String, dynamic> data) {
    final raw = (data['display_name'] ??
            data['fullName'] ??
            data['name'] ??
            data['clientName'] ??
            '')
        .toString()
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ');
    if (raw.isEmpty || raw == 'без имени') return '';
    return raw;
  }

  static String _normalizedAddress(Map<String, dynamic> data) {
    var address = (data['address'] ?? '').toString().trim().toLowerCase();
    if (address.isEmpty) {
      final locs = data['locations'];
      if (locs is List && locs.isNotEmpty && locs.first is Map) {
        final loc = Map<String, dynamic>.from(locs.first as Map);
        address = [
          loc['street'],
          loc['city'],
          loc['postalCode'] ?? loc['postal'],
        ].where((e) => (e ?? '').toString().trim().isNotEmpty).join(', ').toLowerCase();
      }
    }
    return address.replaceAll(RegExp(r'\s+'), ' ');
  }

  static int _compareKeepers(Map<String, dynamic> a, Map<String, dynamic> b) {
    final score = _completeness(b).compareTo(_completeness(a));
    if (score != 0) return score;
    final timeA = a['lastActiveAt'] ?? a['createdAt'];
    final timeB = b['lastActiveAt'] ?? b['createdAt'];
    return '$timeB'.compareTo('$timeA');
  }

  static int _completeness(Map<String, dynamic> data) {
    var score = 0;
    if (ClientService.normalizePhone((data['phone'] ?? '').toString()).length >= 7) {
      score += 3;
    }
    if ((data['email'] ?? '').toString().contains('@')) score += 2;
    if (_normalizedAddress(data).isNotEmpty) score += 2;
    if (_normalizedName(data).length > 2) score += 1;
    return score;
  }

  @override
  State<ClientsDuplicatesScreen> createState() => _ClientsDuplicatesScreenState();
}

class _ClientsDuplicatesScreenState extends State<ClientsDuplicatesScreen> {
  late final List<ClientMatchGroup> _groups;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _groups = ClientsDuplicatesScreen.findGroups(widget.clients);
    for (final group in _groups) {
      for (var i = 1; i < group.clients.length; i++) {
        final id = (group.clients[i]['id'] ?? '').toString();
        if (id.isNotEmpty) _selectedIds.add(id);
      }
    }
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (context) => AlertDialog(
        title: Text('Удалить клиентов?'.tr),
        content: Text(
          '${_selectedIds.length} ${'выбрано'.tr}\n\n${'Карточки попадут в корзину на 30 дней.'.tr}',
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
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final blocked = await JobService.clientIdsWithJobs(_selectedIds);
    if (!mounted) return;
    final toDelete = _selectedIds.where((id) => !blocked.contains(id)).toList();
    if (toDelete.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Нельзя удалить клиента'.tr),
          content: Text(
            '${'Пока есть заявки'.tr}. ${'Карточку удалить нельзя. Сначала удалите работы или перенесите их другому клиенту.'.tr}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Понятно'.tr),
            ),
          ],
        ),
      );
      return;
    }
    await ClientService.deleteMany(toDelete);
    if (!mounted) return;
    Navigator.pop(context);
    if (blocked.isNotEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${blocked.length} ${'не удалены — есть заявки'.tr}',
          ),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        title: Text(
          _selectedIds.isEmpty
              ? 'Совпадения'.tr
              : '${'Совпадения'.tr} · ${_selectedIds.length}',
        ),
        actions: [
          IconButton(
            tooltip: 'Удалить'.tr,
            onPressed: _selectedIds.isEmpty ? null : _deleteSelected,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: _groups.isEmpty
          ? Center(child: Text('Нет совпадений'.tr))
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: _groups.length,
              itemBuilder: (context, index) {
                final group = _groups[index];
                final reason = group.reasons.map(trAny).join(', ');
                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                          child: Text(
                            '${'Совпадение'.tr}: $reason',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                        for (var i = 0; i < group.clients.length; i++)
                          _matchTile(group.clients[i], keep: i == 0),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  Widget _matchTile(Map<String, dynamic> data, {required bool keep}) {
    final id = (data['id'] ?? '').toString();
    final name = (data['display_name'] ?? data['fullName'] ?? data['name'] ?? 'Без имени')
        .toString();
    final phone = ((data['phone'] ?? '') as String).trim();
    final email = ((data['email'] ?? '') as String).trim();
    final selected = _selectedIds.contains(id);

    return ListTile(
      dense: true,
      leading: Checkbox(
        value: selected,
        activeColor: AppColors.primary,
        onChanged: (value) {
          setState(() {
            if (value == true) {
              _selectedIds.add(id);
            } else {
              _selectedIds.remove(id);
            }
          });
        },
      ),
      title: Text(
        name == 'Без имени' ? 'Без имени'.tr : name,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [if (keep) 'Оставить этого'.tr, phone, email]
            .where((e) => e.toString().trim().isNotEmpty)
            .join(' · '),
      ),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ClientDetailsScreen(
              clientId: id,
              clientData: data,
            ),
          ),
        );
      },
    );
  }
}
