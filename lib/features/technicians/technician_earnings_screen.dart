import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../core/ui_scale.dart';
import '../../core/utils/formatters.dart';
import '../../models/job.dart';
import '../../models/technician.dart';
import '../../models/technician_payout.dart';
import '../../services/error_log_service.dart';
import '../../services/job_service.dart';
import '../../services/technician_service.dart';
import '../../shared/app_nav.dart';
import '../jobs/job_details/job_details_screen.dart';
import '../jobs/job_details/widgets/full_screen_gallery.dart';

/// Экран мастера «Моя прибыль и баланс»:
/// показывает чистую прибыль мастера по каждой заявке и сумму к передаче в офис.
class TechnicianEarningsScreen extends StatefulWidget {
  /// Если передан — режим просмотра карточки конкретного мастера у владельца.
  final TechnicianProfile? previewTechnician;

  const TechnicianEarningsScreen({super.key, this.previewTechnician});

  @override
  State<TechnicianEarningsScreen> createState() =>
      _TechnicianEarningsScreenState();
}

class _TechnicianEarningsScreenState extends State<TechnicianEarningsScreen> {
  late final Stream<List<Job>> _jobsStream = JobService.streamAll();

  @override
  void initState() {
    super.initState();
    ErrorLogService.markScreen('Прибыль мастера');
  }

  String _money(double value) => Formatters.formatCurrency(value);

  void _openJob(Job job) {
    AppNav.openCard(
      context,
      key: AppNav.jobKey(job.id),
      builder: (_) => JobDetailsScreen(
        jobId: job.id,
        clientId: job.clientId,
        jobData: job.toMap(),
        initialTab: 1,
      ),
    );
  }

  void _openReceipt(String url) {
    if (url.trim().isEmpty) return;
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => FullScreenGallery(images: [
          {'url': url},
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        AppLocale.instance,
        AppUiSettings.instance,
        TechnicianService.selfProfile,
      ]),
      builder: (context, _) {
        final tech = widget.previewTechnician ??
            TechnicianService.selfProfile.value ??
            TechnicianProfile(
              uid: TechnicianService.currentUid,
              name: context.tr('Мастер', 'Technician'),
              email: '',
            );
        final settlementsStream =
            TechnicianService.streamSettlementsFor(tech.uid);

        return Scaffold(
          backgroundColor: AppColors.surface,
          appBar: AppBar(
            title: Text(
              widget.previewTechnician != null
                  ? tech.displayName
                  : context.tr('Моя прибыль', 'My earnings'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            automaticallyImplyLeading: widget.previewTechnician != null,
          ),
          body: StreamBuilder<List<Job>>(
            stream: _jobsStream,
            builder: (context, jobsSnap) {
              final jobs = jobsSnap.data ?? const <Job>[];
              return StreamBuilder<List<TechnicianSettlement>>(
                stream: settlementsStream,
                builder: (context, setSnap) {
                  final settlements =
                      setSnap.data ?? const <TechnicianSettlement>[];
                  final summary = TechnicianPayoutCalculator.forTechnician(
                    technician: tech,
                    jobs: jobs,
                    settlements: settlements,
                  );
                  return _buildBody(context, tech, summary);
                },
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildBody(
    BuildContext context,
    TechnicianProfile tech,
    TechnicianBalanceSummary summary,
  ) {
    final due = summary.balanceDueToOwner;
    final duePositive = due > 0.009;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.tr('Моя чистая прибыль', 'My net profit'),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _money(summary.totalTechProfit),
                          style: const TextStyle(
                            color: Color(0xFF22C55E),
                            fontSize: 26,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${tech.clampedTechPercent.toStringAsFixed(tech.clampedTechPercent % 1 == 0 ? 0 : 1)}%',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
              const Divider(color: Colors.white24, height: 22),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    context.tr('К передаче в офис', 'Due to office'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    _money(due),
                    style: TextStyle(
                      color: duePositive
                          ? const Color(0xFFFCC520)
                          : Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 20,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${context.tr('Оплачено клиентами без налога', 'Paid excl. tax')}: ${_money(summary.totalRevenueExTax)} · '
                '${context.tr('Передано ранее', 'Already settled')}: ${_money(summary.totalSettled)}',
                style: const TextStyle(color: Colors.white70, fontSize: 11.5),
              ),
            ],
          ),
        ),
        if (summary.totalTechUnverifiedPartsCost > 0.009) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFCC520).withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFFCC520)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.receipt_long_outlined,
                  color: Color(0xFFE65100),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    context.tr(
                      'Есть запчасти без фото чека (${_money(summary.totalTechUnverifiedPartsCost)}). Прикрепите чек в счёте, чтобы сумма вычлась из прибыли.',
                      'Parts without receipt photo (${_money(summary.totalTechUnverifiedPartsCost)}). Attach the receipt in the invoice to deduct cost.',
                    ),
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppColors.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 18),
        Text(
          '${context.tr('Заявки', 'Jobs')} (${summary.jobs.length})',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: AppColors.ink,
          ),
        ),
        const SizedBox(height: 8),
        if (summary.jobs.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              context.tr(
                'Назначенных заявок пока нет.',
                'No assigned jobs yet.',
              ),
              style: TextStyle(color: AppColors.inkMuted),
            ),
          )
        else
          for (final item in summary.jobs) _buildJobCard(context, item),
        if (summary.settlements.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text(
            '${context.tr('История переданных расчётов', 'Settlement history')} (${summary.settlements.length})',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: AppColors.ink,
            ),
          ),
          const SizedBox(height: 8),
          for (final s in summary.settlements)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.check_circle,
                    color: Color(0xFF22C55E),
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          Formatters.formatDate(s.createdAt),
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: AppColors.ink,
                          ),
                        ),
                        if (s.note.isNotEmpty)
                          Text(
                            s.note,
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.inkMuted,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Text(
                    _money(s.amount),
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF22C55E),
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildJobCard(BuildContext context, TechnicianJobPayout item) {
    final job = item.job;
    final title = job.contactName.trim().isNotEmpty
        ? job.contactName
        : job.applianceType;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openJob(job),
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '$title · ${job.applianceType}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14.5,
                        color: AppColors.ink,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: job.statusColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      job.status,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: job.statusColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (!item.hasPaidActivity)
                Text(
                  item.invoicedTotal > 0.009
                      ? '${context.tr('Ожидает оплаты клиента', 'Awaiting client payment')}: ${_money(item.invoicedTotal)}'
                      : context.tr('Счёт ещё не выставлен', 'No invoice yet'),
                  style: TextStyle(fontSize: 12.5, color: AppColors.inkMuted),
                )
              else ...[
                Wrap(
                  spacing: 10,
                  runSpacing: 4,
                  children: [
                    Text(
                      '${context.tr('Выручка без налога', 'Excl. tax')}: ${_money(item.revenueExTax)}',
                      style: TextStyle(fontSize: 12, color: AppColors.inkMuted),
                    ),
                    if (item.recognizedPartsCost > 0.009)
                      Text(
                        '${context.tr('Запчасти', 'Parts')}: −${_money(item.recognizedPartsCost)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.inkMuted,
                        ),
                      ),
                    Text(
                      '${context.tr('Чистая прибыль', 'Net')}: ${_money(item.netProfit)}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.ink,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${context.tr('Мне', 'My share')}: ${_money(item.techProfit)}',
                      style: const TextStyle(
                        color: Color(0xFF22C55E),
                        fontWeight: FontWeight.w800,
                        fontSize: 13.5,
                      ),
                    ),
                    Text(
                      '${context.tr('В офис', 'To office')}: ${_money(item.dueToOwner)}',
                      style: TextStyle(
                        color: AppColors.primaryOnCard,
                        fontWeight: FontWeight.w800,
                        fontSize: 13.5,
                      ),
                    ),
                  ],
                ),
              ],
              if (item.parts.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final p in item.parts)
                      InkWell(
                        onTap: p.hasReceipt
                            ? () => _openReceipt(p.receiptUrl)
                            : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: !p.costRecognized
                                ? const Color(0xFFE53935).withValues(alpha: 0.12)
                                : AppColors.primary.withValues(alpha: 0.09),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                p.providedByOwner
                                    ? Icons.inventory_2_outlined
                                    : (p.hasReceipt
                                        ? Icons.receipt_outlined
                                        : Icons.warning_amber_rounded),
                                size: 13,
                                color: !p.costRecognized
                                    ? const Color(0xFFE53935)
                                    : AppColors.primaryOnCard,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${p.name}: ${_money(p.rawCostTotal)} (${p.providedByOwner ? context.tr('офис', 'office') : (p.hasReceipt ? context.tr('чек', 'receipt') : context.tr('нет чека', 'no receipt'))})',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: !p.costRecognized
                                      ? const Color(0xFFE53935)
                                      : AppColors.ink,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
