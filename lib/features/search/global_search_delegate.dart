import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../models/models.dart';
import '../../services/services.dart';
import '../../shared/widgets/highlight_text.dart';
import '../clients/client_details_screen.dart';
import '../jobs/job_details/job_details_screen.dart';
import '../warehouse/warehouse_screen.dart';

/// Глобальный поиск по всему приложению: клиенты, заявки, склад
class GlobalSearchDelegate extends SearchDelegate<void> {
  GlobalSearchDelegate()
      : super(searchFieldLabel: 'Поиск клиентов, заявок, склада...'.tr);

  @override
  List<Widget> buildActions(BuildContext context) {
    return [
      if (query.isNotEmpty)
        IconButton(
          icon: const Icon(Icons.clear),
          onPressed: () => query = '',
        ),
    ];
  }

  @override
  Widget buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed: () => close(context, null),
    );
  }

  @override
  Widget buildResults(BuildContext context) => _buildBody(context);

  @override
  Widget buildSuggestions(BuildContext context) => _buildBody(context);

  Widget _buildBody(BuildContext context) {
    final q = query.trim().toLowerCase();
    if (q.length < 2) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Введите минимум 2 символа\nдля поиска по клиентам, заявкам и складу'.tr,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    return FutureBuilder<_SearchResults>(
      future: _search(q),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          );
        }

        final results = snapshot.data;
        if (results == null || results.isEmpty) {
          return Center(
            child: Text('Ничего не найдено'.tr, style: TextStyle(color: Colors.grey)),
          );
        }

        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            if (results.clients.isNotEmpty) ...[
              _sectionHeader('Клиенты'.tr, Icons.people, Colors.blue),
              ...results.clients.map((c) => _clientTile(context, c)),
            ],
            if (results.jobs.isNotEmpty) ...[
              _sectionHeader('Заявки'.tr, Icons.list_alt, AppColors.primary),
              ...results.jobs.map((j) => _jobTile(context, j)),
            ],
            if (results.items.isNotEmpty) ...[
              _sectionHeader('Склад'.tr, Icons.inventory_2, Colors.orange),
              ...results.items.map((w) => _warehouseTile(context, w)),
            ],
          ],
        );
      },
    );
  }

  Future<_SearchResults> _search(String q) async {
    final clientsFuture = ClientService.streamAll().first;
    final jobsFuture = JobService.streamAll().first;
    final itemsFuture = WarehouseService.streamAll().first;

    final allClients = await clientsFuture;
    final allJobs = await jobsFuture;
    final allItems = await itemsFuture;

    final clients = allClients.where((c) {
      return ClientService.matchesClient(c, query);
    }).take(15).toList();

    final jobs = allJobs.where((j) {
      return j.clientName.toLowerCase().contains(q) ||
          ClientService.queryMatchesPhone(j.clientPhone, query) ||
          j.description.toLowerCase().contains(q) ||
          j.applianceType.toLowerCase().contains(q) ||
          j.applianceBrand.toLowerCase().contains(q) ||
          j.workAddress.toLowerCase().contains(q) ||
          j.status.toLowerCase().contains(q);
    }).take(15).toList();

    final items = allItems.where((w) {
      return w.name.toLowerCase().contains(q) ||
          w.partNumber.toLowerCase().contains(q) ||
          (w.modelNumber ?? '').toLowerCase().contains(q) ||
          w.category.toLowerCase().contains(q) ||
          (w.barcode ?? '').toLowerCase().contains(q);
    }).take(15).toList();

    return _SearchResults(clients: clients, jobs: jobs, items: items);
  }

  Widget _sectionHeader(String title, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
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

  Widget _clientTile(BuildContext context, Client c) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Colors.blue.shade50,
        child: Text(
          c.initials,
          style: const TextStyle(color: Colors.blue, fontWeight: FontWeight.bold),
        ),
      ),
      title: HighlightText(
        c.fullName,
        query: query,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: HighlightText(
        c.phone.isNotEmpty ? c.phone : c.address,
        query: query,
      ),
      onTap: () {
        close(context, null);
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ClientDetailsScreen(
              clientId: c.id,
              clientData: {
                'fullName': c.fullName,
                'phone': c.phone,
                'address': c.address,
                'companyName': c.companyName,
              },
            ),
          ),
        );
      },
    );
  }

  Widget _jobTile(BuildContext context, Job j) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: j.statusColor.withOpacity(0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(j.applianceIcon, color: j.statusColor),
      ),
      title: HighlightText(
        '${trAny(j.applianceType)} — ${j.clientName}',
        query: query,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: HighlightText(
        '${trAny(j.status)} • ${j.workAddress}',
        query: query,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () {
        close(context, null);
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => JobDetailsScreen(
              jobId: j.id,
              clientId: j.clientId,
              jobData: {
                'clientName': j.clientName,
                'clientPhone': j.clientPhone,
                'clientAddress': j.clientAddress,
                'applianceType': j.applianceType,
                'brand': j.applianceBrand,
                'status': j.status,
                'priority': j.priority,
                'description': j.description,
              },
            ),
          ),
        );
      },
    );
  }

  Widget _warehouseTile(BuildContext context, WarehouseItem w) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.orange.withOpacity(0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.build, color: Colors.orange),
      ),
      title: HighlightText(
        w.name,
        query: query,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: HighlightText(
        '${w.partNumber} • ${'Остаток'.tr}: ${w.quantity}',
        query: query,
      ),
      trailing: Text(
        '\$${w.price.toStringAsFixed(2)}',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      onTap: () {
        close(context, null);
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const WarehouseScreen()),
        );
      },
    );
  }
}

class _SearchResults {
  final List<Client> clients;
  final List<Job> jobs;
  final List<WarehouseItem> items;

  _SearchResults({
    required this.clients,
    required this.jobs,
    required this.items,
  });

  bool get isEmpty => clients.isEmpty && jobs.isEmpty && items.isEmpty;
}
