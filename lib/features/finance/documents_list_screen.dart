import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../core/utils/formatters.dart';
import '../../models/job.dart';
import '../../services/job_service.dart';
import '../jobs/job_details/job_details_screen.dart';

class DocumentsListScreen extends StatefulWidget {
  final int initialPage;

  const DocumentsListScreen({super.key, this.initialPage = 0});

  @override
  State<DocumentsListScreen> createState() => _DocumentsListScreenState();
}

class _DocumentsListScreenState extends State<DocumentsListScreen> {
  late final PageController _page;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _index = widget.initialPage.clamp(0, 1);
    _page = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  void _goTo(int index) {
    setState(() => _index = index);
    _page.animateToPage(
      index,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: Text(_index == 0 ? 'Счета'.tr : 'Сметы'.tr),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: 0,
                  icon: const Icon(Icons.receipt_long, size: 18),
                  label: Text('Счета'.tr),
                ),
                ButtonSegment(
                  value: 1,
                  icon: const Icon(Icons.description_outlined, size: 18),
                  label: Text('Сметы'.tr),
                ),
              ],
              selected: {_index},
              onSelectionChanged: (value) => _goTo(value.first),
            ),
          ),
          Expanded(
            child: StreamBuilder<List<Job>>(
              stream: JobService.streamAll(),
              builder: (context, snapshot) {
                final jobs = snapshot.data ?? const <Job>[];
                final invoices = _collect(jobs, estimates: false);
                final estimates = _collect(jobs, estimates: true);
                return PageView(
                  controller: _page,
                  onPageChanged: (value) => setState(() => _index = value),
                  children: [
                    _list(invoices, empty: 'Нет счетов'.tr),
                    _list(estimates, empty: 'Нет смет'.tr),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  List<_DocRow> _collect(List<Job> jobs, {required bool estimates}) {
    final rows = <_DocRow>[];
    for (final job in jobs) {
      for (var i = 0; i < job.documents.length; i++) {
        final doc = job.documents[i];
        final isEstimate = (doc['type'] ?? '') == 'Estimate';
        if (isEstimate != estimates) continue;
        rows.add(_DocRow(job: job, doc: doc, index: i));
      }
    }
    rows.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return rows;
  }

  Widget _list(List<_DocRow> rows, {required String empty}) {
    if (rows.isEmpty) {
      return Center(
        child: Text(empty, style: const TextStyle(color: Colors.grey)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: rows.length,
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final row = rows[i];
        final total = Job.documentTotal(row.doc);
        final number = row.doc['number'];
        final title = number == null
            ? '${row.doc['type'] ?? 'Invoice'} #${row.index + 1}'
            : '${row.doc['type'] ?? 'Invoice'} #$number';
        return Card(
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: row.isEstimate
                  ? Colors.orange.shade50
                  : Colors.green.shade50,
              child: Icon(
                row.isEstimate ? Icons.description : Icons.receipt_long,
                color: row.isEstimate ? Colors.orange : Colors.green.shade800,
              ),
            ),
            title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
            subtitle: Text(
              '${row.job.clientName}\n${Formatters.formatCurrency(total)}',
            ),
            isThreeLine: true,
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              final data = Map<String, dynamic>.from(row.job.toMap())
                ..remove('updatedAt');
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => JobDetailsScreen(
                    jobId: row.job.id,
                    clientId: row.job.clientId,
                    jobData: data,
                    initialTab: 1,
                    openDocumentIndex: row.index,
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _DocRow {
  final Job job;
  final Map<String, dynamic> doc;
  final int index;

  _DocRow({required this.job, required this.doc, required this.index});

  bool get isEstimate => (doc['type'] ?? '') == 'Estimate';

  DateTime get createdAt {
    final raw = doc['createdAt'];
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw) ?? DateTime(1970);
    return DateTime(1970);
  }
}
