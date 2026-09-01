import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../models/models.dart';
import '../../services/services.dart';
import '../../shared/widgets/highlight_text.dart';
import '../clients/client_details_screen.dart';
import '../jobs/job_details/job_details_screen.dart';
import '../warehouse/warehouse_screen.dart';

class GlobalSearchOverlay {
  static Future<void> open(BuildContext context) {
    return Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: const Color(0x99000000),
        barrierDismissible: true,
        transitionDuration: const Duration(milliseconds: 280),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (context, animation, _) {
          return FadeTransition(
            opacity: animation,
            child: const _GlobalSearchPage(),
          );
        },
      ),
    );
  }
}

class _GlobalSearchPage extends StatefulWidget {
  const _GlobalSearchPage();

  @override
  State<_GlobalSearchPage> createState() => _GlobalSearchPageState();
}

class _GlobalSearchPageState extends State<_GlobalSearchPage> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  String _query = '';
  bool _loading = false;
  _Hits _hits = const _Hits.empty();

  bool get _hasHits => _query.trim().length >= 2 && !_hits.isEmpty;

  bool get _nothingFound =>
      _query.trim().length >= 2 && !_loading && _hits.isEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onQuery(String value) {
    _debounce?.cancel();
    final q = value.trim();
    if (q.length < 2) {
      setState(() {
        _query = q;
        _hits = const _Hits.empty();
        _loading = false;
      });
      return;
    }
    setState(() {
      _query = q;
      _loading = true;
    });
    _debounce = Timer(const Duration(milliseconds: 180), () {
      _run(q);
    });
  }

  Future<void> _run(String q) async {
    final hits = await _search(q);
    if (!mounted || _query != q) return;
    setState(() {
      _hits = hits;
      _loading = false;
    });
  }

  void _close() {
    Navigator.of(context).pop();
  }

  void _openRoute(Widget page) {
    final nav = Navigator.of(context, rootNavigator: true);
    nav.pop();
    nav.push(MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    final hasHits = _hasHits;
    return GestureDetector(
      onTap: _close,
      child: Material(
        color: Colors.transparent,
        child: Padding(
          padding: EdgeInsets.only(bottom: inset),
          child: SafeArea(
            child: Stack(
              children: [
                Positioned(
                  left: 12,
                  right: 12,
                  top: 8,
                  bottom: 72,
                  child: IgnorePointer(
                    ignoring: !hasHits,
                    child: AnimatedSlide(
                      duration: const Duration(milliseconds: 420),
                      curve: Curves.easeOutCubic,
                      offset: hasHits ? Offset.zero : const Offset(0, 0.22),
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 280),
                        opacity: hasHits ? 1 : 0,
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: GestureDetector(
                            onTap: () {},
                            behavior: HitTestBehavior.opaque,
                        child: hasHits
                            ? _ResultsCard(
                                query: _query,
                                hits: _hits,
                                onOpen: _openRoute,
                              )
                            : const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                AnimatedAlign(
                  duration: const Duration(milliseconds: 420),
                  curve: Curves.easeOutCubic,
                  alignment:
                      hasHits ? Alignment.bottomCenter : Alignment.center,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_nothingFound)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              'Ничего не найдено'.tr,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        GestureDetector(
                          onTap: () {},
                          behavior: HitTestBehavior.opaque,
                          child: _SearchField(
                            controller: _controller,
                            focus: _focus,
                            loading: _loading,
                            onChanged: _onQuery,
                            onClose: _close,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focus;
  final bool loading;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;

  const _SearchField({
    required this.controller,
    required this.focus,
    required this.loading,
    required this.onChanged,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 10,
      shadowColor: Colors.black38,
      borderRadius: BorderRadius.circular(28),
      color: Colors.white,
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            const SizedBox(width: 16),
            Icon(Icons.search, color: AppColors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focus,
                textInputAction: TextInputAction.search,
                onChanged: onChanged,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
                decoration: InputDecoration(
                  hintText: 'Поиск клиентов, заявок, склада...'.tr,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            if (loading)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (context, value, _) {
                  if (value.text.isEmpty) return const SizedBox.shrink();
                  return IconButton(
                    tooltip: 'Очистить'.tr,
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                    icon: const Icon(Icons.close, size: 20),
                  );
                },
              ),
            IconButton(
              tooltip: 'Закрыть'.tr,
              onPressed: onClose,
              icon: const Icon(Icons.keyboard_hide_outlined, size: 20),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultsCard extends StatelessWidget {
  final String query;
  final _Hits hits;
  final void Function(Widget page) onOpen;

  const _ResultsCard({
    required this.query,
    required this.hits,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.sizeOf(context).height * 0.55;
    return Material(
      color: Colors.white,
      elevation: 8,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: ListView(
          reverse: true,
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          children: [
            for (final client in hits.clients)
              _clientTile(context, client),
            if (hits.clients.isNotEmpty)
              _section('Клиенты'.tr, Icons.people, Colors.blue),
            for (final job in hits.jobs)
              _jobTile(context, job),
            if (hits.jobs.isNotEmpty)
              _section('Заявки'.tr, Icons.list_alt, AppColors.primary),
            for (final item in hits.items)
              _itemTile(context, item),
            if (hits.items.isNotEmpty)
              _section('Склад'.tr, Icons.inventory_2, Colors.orange),
          ],
        ),
      ),
    );
  }

  Widget _section(String title, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text(
            title.toUpperCase(),
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
              letterSpacing: 0.8,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _clientTile(BuildContext context, Client client) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Colors.blue.shade50,
        child: Text(
          client.initials,
          style: const TextStyle(color: Colors.blue, fontWeight: FontWeight.bold),
        ),
      ),
      title: HighlightText(
        client.fullName,
        query: query,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: HighlightText(
        client.phone.isNotEmpty ? client.phone : client.address,
        query: query,
      ),
      onTap: () => onOpen(
        ClientDetailsScreen(
          clientId: client.id,
          clientData: {
            'fullName': client.fullName,
            'phone': client.phone,
            'address': client.address,
            'companyName': client.companyName,
          },
        ),
      ),
    );
  }

  Widget _jobTile(BuildContext context, Job job) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: job.statusColor.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(job.applianceIcon, color: job.statusColor),
      ),
      title: HighlightText(
        '${trAny(job.applianceType)} — ${job.clientName}',
        query: query,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: HighlightText(
        '${trAny(job.status)} • ${job.workAddress}',
        query: query,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => onOpen(
        JobDetailsScreen(
          jobId: job.id,
          clientId: job.clientId,
          jobData: {
            'clientName': job.clientName,
            'clientPhone': job.clientPhone,
            'clientAddress': job.clientAddress,
            'applianceType': job.applianceType,
            'brand': job.applianceBrand,
            'status': job.status,
            'priority': job.priority,
            'description': job.description,
          },
        ),
      ),
    );
  }

  Widget _itemTile(BuildContext context, WarehouseItem item) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.build, color: Colors.orange),
      ),
      title: HighlightText(
        item.name,
        query: query,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: HighlightText(
        '${item.partNumber} • ${'Остаток'.tr}: ${item.quantity}',
        query: query,
      ),
      trailing: Text(
        '\$${item.price.toStringAsFixed(2)}',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      onTap: () => onOpen(const WarehouseScreen()),
    );
  }
}

class _Hits {
  final List<Client> clients;
  final List<Job> jobs;
  final List<WarehouseItem> items;

  const _Hits({
    required this.clients,
    required this.jobs,
    required this.items,
  });

  const _Hits.empty()
      : clients = const [],
        jobs = const [],
        items = const [];

  bool get isEmpty => clients.isEmpty && jobs.isEmpty && items.isEmpty;
}

int _rank(String haystack, String q) {
  final value = haystack.toLowerCase();
  if (value.startsWith(q)) return 0;
  if (value.contains(q)) return 1;
  return 2;
}

Future<_Hits> _search(String raw) async {
  final q = raw.trim().toLowerCase();
  final clientsFuture = ClientService.streamAll().first;
  final jobsFuture = JobService.streamAll().first;
  final itemsFuture = WarehouseService.streamAll().first;
  final allClients = await clientsFuture;
  final allJobs = await jobsFuture;
  final allItems = await itemsFuture;

  final clients = allClients.where((c) {
    return ClientService.matchesClient(c, raw);
  }).toList()
    ..sort((a, b) {
      final byRank = _rank(a.fullName, q).compareTo(_rank(b.fullName, q));
      if (byRank != 0) return byRank;
      return a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase());
    });

  final jobs = allJobs.where((j) {
    return j.clientName.toLowerCase().contains(q) ||
        ClientService.queryMatchesPhone(j.clientPhone, raw) ||
        j.description.toLowerCase().contains(q) ||
        j.applianceType.toLowerCase().contains(q) ||
        j.applianceBrand.toLowerCase().contains(q) ||
        j.workAddress.toLowerCase().contains(q) ||
        j.status.toLowerCase().contains(q);
  }).toList()
    ..sort((a, b) {
      final byRank = _rank(a.clientName, q).compareTo(_rank(b.clientName, q));
      if (byRank != 0) return byRank;
      return a.clientName.toLowerCase().compareTo(b.clientName.toLowerCase());
    });

  final items = allItems.where((w) {
    return w.name.toLowerCase().contains(q) ||
        w.partNumber.toLowerCase().contains(q) ||
        (w.modelNumber ?? '').toLowerCase().contains(q) ||
        w.category.toLowerCase().contains(q) ||
        (w.barcode ?? '').toLowerCase().contains(q);
  }).toList()
    ..sort((a, b) {
      final byRank = _rank(a.name, q).compareTo(_rank(b.name, q));
      if (byRank != 0) return byRank;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

  return _Hits(
    clients: clients.take(20).toList(),
    jobs: jobs.take(20).toList(),
    items: items.take(20).toList(),
  );
}
