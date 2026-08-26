import 'package:flutter/material.dart';

import '../../core/app_feedback.dart';
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
                  onPageChanged: (value) {
                    if (_index == value) return;
                    AppFeedback.pleasant();
                    setState(() => _index = value);
                  },
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
        if (Job.isDocumentTrashed(doc)) continue;
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
        final paid = Job.documentPaid(row.doc);
        final due = (total - paid).clamp(0.0, double.infinity);
        final number = row.doc['number'];
        final title = number == null
            ? '${row.doc['type'] ?? 'Invoice'} #${row.index + 1}'
            : '${row.doc['type'] ?? 'Invoice'} #$number';
        final mark = row.isEstimate ? '' : Job.documentPayMark(row.doc);
        final look = _payLook(mark, estimate: row.isEstimate);
        return Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
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
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(width: 7, color: look.bar),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
                      child: Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: look.avatar,
                            child: Icon(look.icon, color: look.iconColor),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(row.job.clientName),
                                Text(
                                  Formatters.formatCurrency(total),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (mark.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  _PayChip(
                                    mark: mark,
                                    look: look,
                                    due: due,
                                    paid: paid,
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right, color: Colors.grey),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
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

class _PayLook {
  final Color bar;
  final Color avatar;
  final Color iconColor;
  final Color chipBg;
  final Color chipFg;
  final IconData icon;
  final String label;

  const _PayLook({
    required this.bar,
    required this.avatar,
    required this.iconColor,
    required this.chipBg,
    required this.chipFg,
    required this.icon,
    required this.label,
  });
}

_PayLook _payLook(String mark, {required bool estimate}) {
  if (estimate) {
    return _PayLook(
      bar: Colors.orange.shade400,
      avatar: Colors.orange.shade50,
      iconColor: Colors.orange.shade800,
      chipBg: Colors.orange.shade50,
      chipFg: Colors.orange.shade800,
      icon: Icons.description,
      label: 'Смета'.tr,
    );
  }
  switch (mark) {
    case 'paid':
      return _PayLook(
        bar: const Color(0xFF16A34A),
        avatar: const Color(0xFFDCFCE7),
        iconColor: const Color(0xFF15803D),
        chipBg: const Color(0xFFDCFCE7),
        chipFg: const Color(0xFF15803D),
        icon: Icons.check_circle,
        label: 'Оплачен'.tr,
      );
    case 'deposit':
      return _PayLook(
        bar: const Color(0xFFF59E0B),
        avatar: const Color(0xFFFEF3C7),
        iconColor: const Color(0xFFB45309),
        chipBg: const Color(0xFFFEF3C7),
        chipFg: const Color(0xFFB45309),
        icon: Icons.savings_outlined,
        label: 'Депозит'.tr,
      );
    default:
      return _PayLook(
        bar: const Color(0xFFEF4444),
        avatar: const Color(0xFFFEE2E2),
        iconColor: const Color(0xFFB91C1C),
        chipBg: const Color(0xFFFEE2E2),
        chipFg: const Color(0xFFB91C1C),
        icon: Icons.circle_outlined,
        label: 'Неоплачен'.tr,
      );
  }
}

class _PayChip extends StatelessWidget {
  final String mark;
  final _PayLook look;
  final double due;
  final double paid;

  const _PayChip({
    required this.mark,
    required this.look,
    required this.due,
    required this.paid,
  });

  @override
  Widget build(BuildContext context) {
    var text = look.label;
    if (mark == 'deposit' && paid > 0.009) {
      text = '${look.label} · ${Formatters.formatCurrency(paid)}';
    } else if (mark == 'unpaid' && due > 0.009) {
      text = '${look.label} · ${Formatters.formatCurrency(due)}';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: look.chipBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: look.chipFg,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }
}
