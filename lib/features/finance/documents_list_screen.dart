import 'package:flutter/material.dart';

import '../../core/app_feedback.dart';
import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../core/utils/formatters.dart';
import '../../models/job.dart';
import '../../services/client_service.dart';
import '../../services/job_service.dart';
import '../jobs/job_details/job_details_screen.dart';
import '../../shared/app_nav.dart';

class DocumentsListScreen extends StatefulWidget {
  final int initialPage;

  const DocumentsListScreen({super.key, this.initialPage = 0});

  @override
  State<DocumentsListScreen> createState() => _DocumentsListScreenState();
}

class _DocumentsListScreenState extends State<DocumentsListScreen> {
  late final PageController _page;
  late final _jobsStream = JobService.streamAll();
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
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        title: Text(_index == 0 ? 'Счета'.tr : 'Сметы'.tr),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
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
              stream: _jobsStream,
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
    rows.sort((a, b) => b.sortKey.compareTo(a.sortKey));
    return rows;
  }

  /// Индекс документа в заявке по типу и номеру — для перехода по связке
  /// «смета ↔ счёт».
  int _docIndexByTypeNumber(Job job, String type, dynamic number) {
    if (number == null) return -1;
    for (var i = 0; i < job.documents.length; i++) {
      final d = job.documents[i];
      final t = (d['type'] ?? 'Invoice').toString();
      if (type == 'Estimate' ? t != 'Estimate' : t == 'Estimate') continue;
      if (d['number'] == number) return i;
    }
    return -1;
  }

  void _openDocument(Job job, int index) {
    final data = Map<String, dynamic>.from(job.toMap())..remove('updatedAt');
    AppNav.openCard(
      context,
      key: AppNav.jobKey(job.id),
      builder: (_) => JobDetailsScreen(
        jobId: job.id,
        clientId: job.clientId,
        jobData: data,
        initialTab: 1,
        openDocumentIndex: index,
      ),
    );
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
        final stamp = Formatters.messageStamp(row.createdAt);
        final mark = row.isEstimate ? '' : Job.documentPayMark(row.doc);
        final look = _payLook(mark, estimate: row.isEstimate);
        final linkedNumber = row.isEstimate
            ? row.doc['convertedInvoiceNumber']
            : row.doc['fromEstimateNumber'];
        return Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
          InkWell(
            onTap: () => _openDocument(row.job, row.index),
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
                                Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.baseline,
                                  textBaseline: TextBaseline.alphabetic,
                                  children: [
                                    Expanded(
                                      child: Text(
                                        title,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 16,
                                        ),
                                      ),
                                    ),
                                    // Когда выставлен. По одному номеру не
                                    // понять, этот счёт вчерашний или
                                    // прошлогодний.
                                    if (stamp.isNotEmpty)
                                      Text(
                                        stamp,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.inkMuted,
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        (row.doc['billTo'] == 'tenant' &&
                                                (row.doc['billToName'] ?? '')
                                                    .toString()
                                                    .trim()
                                                    .isNotEmpty)
                                            ? '${row.doc['billToName']} (${context.tr('Арендатор', 'Tenant')})'
                                            : row.job.clientName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (row.job.clientIsRegular ||
                                        ClientService.isRegularClient(
                                          clientId: row.job.clientId,
                                          phone: row.job.clientPhone,
                                        ))
                                      const RegularClientStar(size: 16),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Text(
                                      Formatters.formatCurrency(total),
                                      style: TextStyle(
                                        fontWeight: FontWeight.w900,
                                        fontSize: 17,
                                        color: AppColors.primaryOnCard,
                                      ),
                                    ),
                                    if (mark.isNotEmpty) ...[
                                      const SizedBox(width: 8),
                                      _PayChip(
                                        mark: mark,
                                        look: look,
                                        due: due,
                                        paid: paid,
                                      ),
                                    ],
                                  ],
                                ),
                                if (mark.isNotEmpty && !row.isEstimate) ...[
                                  const SizedBox(height: 4),
                                  _PayMethodsLines(doc: row.doc),
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
          if (linkedNumber != null)
            _buildDocLinkStrip(
              estimate: !row.isEstimate,
              label:
                  '${row.isEstimate ? 'Счёт'.tr : 'Смета'.tr} #$linkedNumber',
              onTap: () {
                final idx = _docIndexByTypeNumber(
                  row.job,
                  row.isEstimate ? 'Invoice' : 'Estimate',
                  linkedNumber,
                );
                if (idx < 0) return;
                _openDocument(row.job, idx);
              },
            ),
            ],
          ),
        );
      },
    );
  }

  /// Нижняя строка-связка в объединённой карточке: из счёта ведёт к смете,
  /// из сметы — к созданному счёту.
  Widget _buildDocLinkStrip({
    required bool estimate,
    required String label,
    required VoidCallback onTap,
  }) {
    final color = estimate ? Colors.orange.shade800 : Colors.green.shade700;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.cardMuted,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          children: [
            Icon(
              estimate ? Icons.description_outlined : Icons.receipt_long,
              size: 16,
              color: color,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: Colors.grey.shade500),
          ],
        ),
      ),
    );
  }
}

class _DocRow {
  final Job job;
  final Map<String, dynamic> doc;
  final int index;

  _DocRow({required this.job, required this.doc, required this.index});

  bool get isEstimate => (doc['type'] ?? '') == 'Estimate';

  /// Дата самого документа. У давних счетов её может не быть — тогда в
  /// карточке даты нет, а в сортировке подставляется дата заявки, чтобы
  /// такой счёт не падал в 1970 год в самый низ списка.
  DateTime? get createdAt => Job.documentCreatedAt(doc);

  DateTime get sortKey => createdAt ?? job.createdAt;
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
    case 'refunded':
      return _PayLook(
        bar: const Color(0xFF64748B),
        avatar: const Color(0xFFF1F5F9),
        iconColor: const Color(0xFF475569),
        chipBg: const Color(0xFFF1F5F9),
        chipFg: const Color(0xFF475569),
        icon: Icons.undo,
        label: 'Возврат'.tr,
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

class _PayMethodsLines extends StatelessWidget {
  final Map<String, dynamic> doc;

  const _PayMethodsLines({required this.doc});

  @override
  Widget build(BuildContext context) {
    final methods = Job.documentPayMethods(doc);
    if (!methods.hasAny) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (methods.deposit.isNotEmpty)
          Text(
            '${'Депозит'.tr}: ${methods.deposit}',
            style: TextStyle(
              color: Colors.grey.shade700,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        if (methods.balance.isNotEmpty)
          Text(
            '${'Баланс'.tr}: ${methods.balance}',
            style: TextStyle(
              color: Colors.grey.shade700,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }
}
