import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../core/motion.dart';
import '../../core/ui_scale.dart';
import '../../core/utils/formatters.dart';
import '../../models/job.dart';
import '../../models/technician.dart';
import '../../models/technician_payout.dart';
import '../../services/error_log_service.dart';
import '../../services/job_service.dart';
import '../../services/technician_service.dart';
import '../../services/warehouse_service.dart';
import '../../shared/widgets/confirm_action_sheet.dart';
import '../../shared/widgets/dispose_on_close.dart';
import '../../shared/widgets/keyboard_safe.dart';
import '../settings/pages/technicians_settings_page.dart';
import 'technician_earnings_screen.dart';

/// Экран владельца «Расчёт с мастерами»:
/// сводка долей чистой прибыли, сколько денег каждый мастер должен сдать,
/// кнопка «Принял расчёт» и переход в заказы/чеки каждого мастера.
class TechnicianSettlementsScreen extends StatefulWidget {
  const TechnicianSettlementsScreen({super.key});

  @override
  State<TechnicianSettlementsScreen> createState() =>
      _TechnicianSettlementsScreenState();
}

class _TechnicianSettlementsScreenState
    extends State<TechnicianSettlementsScreen> {
  late final Stream<List<TechnicianProfile>> _techStream =
      TechnicianService.streamAll();
  late final Stream<List<Job>> _jobsStream = JobService.streamAll();
  late final Stream<List<TechnicianSettlement>> _settlementsStream =
      TechnicianService.streamAllSettlements();

  @override
  void initState() {
    super.initState();
    ErrorLogService.markScreen('Расчёт с мастерами');
  }

  String _money(double value) => Formatters.formatCurrency(value);

  Future<void> _showSettleSheet(TechnicianBalanceSummary summary) async {
    final initial = summary.balanceDueToOwner > 0.009
        ? summary.balanceDueToOwner.toStringAsFixed(2)
        : '';
    final amountCtrl = TextEditingController(text: initial);
    final noteCtrl = TextEditingController();
    var inlineError = '';
    var saving = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      sheetAnimationStyle: AppMotion.sheet,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return DisposeOnClose(
          disposables: [amountCtrl, noteCtrl],
          child: StatefulBuilder(
            builder: (ctx, setSheet) {
              return KeyboardAvoidingSheet(
                padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${context.tr('Принял расчёт', 'Record settlement')} · ${summary.technician.displayName}',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: AppColors.ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${context.tr('Текущий остаток за мастером', 'Current balance due')}: ${_money(summary.balanceDueToOwner)}',
                      style: TextStyle(fontSize: 13, color: AppColors.inkMuted),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: amountCtrl,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: context.tr('Полученная сумма', 'Amount received'),
                        prefixText: '\$ ',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: noteCtrl,
                      decoration: InputDecoration(
                        labelText: context.tr(
                          'Заметка (наличные / перевод)',
                          'Note (cash / e-Transfer)',
                        ),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    if (inlineError.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        inlineError,
                        style: const TextStyle(
                          color: Color(0xFFE53935),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 46,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF22C55E),
                          foregroundColor: Colors.white,
                        ),
                        onPressed: saving
                            ? null
                            : () async {
                                final parsed = double.tryParse(
                                  amountCtrl.text.trim().replaceAll(',', '.'),
                                );
                                if (parsed == null || parsed <= 0) {
                                  setSheet(() {
                                    inlineError = context.tr(
                                      'Введите сумму больше 0',
                                      'Enter an amount greater than 0',
                                    );
                                  });
                                  return;
                                }
                                setSheet(() {
                                  saving = true;
                                  inlineError = '';
                                });
                                await TechnicianService.recordSettlement(
                                  technicianId: summary.technician.uid,
                                  technicianName:
                                      summary.technician.displayName,
                                  amount: parsed,
                                  note: noteCtrl.text.trim(),
                                  jobIds: [
                                    for (final j in summary.jobs)
                                      if (j.hasPaidActivity) j.job.id,
                                  ],
                                );
                                if (sheetContext.mounted) {
                                  Navigator.pop(sheetContext);
                                }
                              },
                        icon: const Icon(Icons.check_rounded),
                        label: Text(
                          context.tr('Подтвердить получение', 'Confirm receipt'),
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _deleteSettlement(TechnicianSettlement s) async {
    final ok = await showConfirmCancelSheet(
      context,
      title: context.tr('Удалить запись о расчёте?', 'Delete settlement entry?'),
      message: '${s.technicianName} · ${_money(s.amount)}',
      confirmLabel: context.tr('Удалить', 'Delete'),
    );
    if (!ok || !mounted) return;
    await TechnicianService.deleteSettlement(s.id);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        AppLocale.instance,
        AppUiSettings.instance,
      ]),
      builder: (context, _) {
        return Scaffold(
          backgroundColor: AppColors.surface,
          appBar: AppBar(
            title: Text(
              context.tr('Расчёт с мастерами', 'Technician settlements'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            actions: [
              IconButton(
                tooltip: context.tr('Профили мастеров', 'Manage technicians'),
                icon: const Icon(Icons.manage_accounts_outlined),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const TechniciansSettingsPage(),
                    ),
                  );
                },
              ),
            ],
          ),
          body: StreamBuilder<List<TechnicianProfile>>(
            stream: _techStream,
            builder: (context, techSnap) {
              final techs = techSnap.data ?? const <TechnicianProfile>[];
              return StreamBuilder<List<Job>>(
                stream: _jobsStream,
                builder: (context, jobsSnap) {
                  final jobs = jobsSnap.data ?? const <Job>[];
                  return StreamBuilder<List<TechnicianSettlement>>(
                    stream: _settlementsStream,
                    builder: (context, setSnap) {
                      final settlements =
                          setSnap.data ?? const <TechnicianSettlement>[];
                      final summaries = [
                        for (final t in techs)
                          TechnicianPayoutCalculator.forTechnician(
                            technician: t,
                            jobs: jobs,
                            settlements: settlements,
                            warehouseCosts: WarehouseService.latestCosts,
                          ),
                      ];
                      return _buildContent(context, summaries, settlements);
                    },
                  );
                },
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildContent(
    BuildContext context,
    List<TechnicianBalanceSummary> summaries,
    List<TechnicianSettlement> allSettlements,
  ) {
    final totalOwnerProfit = summaries.fold<double>(
      0.0,
      (sum, s) => sum + s.totalOwnerProfit,
    );
    final totalDue = summaries.fold<double>(
      0.0,
      (sum, s) => sum + s.balanceDueToOwner,
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.tr('Должны сдать мастера', 'Total due from techs'),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _money(totalDue),
                      style: const TextStyle(
                        color: Color(0xFFFCC520),
                        fontSize: 25,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    context.tr('Моя доля прибыли', 'My profit share'),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _money(totalOwnerProfit),
                    style: const TextStyle(
                      color: Color(0xFF22C55E),
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (summaries.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                Text(
                  context.tr(
                    'Мастера ещё не добавлены.',
                    'No technicians added yet.',
                  ),
                  style: TextStyle(color: AppColors.inkMuted),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const TechniciansSettingsPage(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.person_add_alt_1),
                  label: Text(context.tr('Добавить мастера', 'Add technician')),
                ),
              ],
            ),
          )
        else
          for (final s in summaries) _buildTechnicianCard(context, s),
        if (allSettlements.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text(
            context.tr('Принятые расчёты', 'Recorded settlements'),
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: AppColors.ink,
            ),
          ),
          const SizedBox(height: 8),
          for (final entry in allSettlements.take(30))
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListTile(
                dense: true,
                leading: const Icon(
                  Icons.payments_outlined,
                  color: Color(0xFF22C55E),
                ),
                title: Text(
                  '${entry.technicianName.isEmpty ? context.tr('Мастер', 'Tech') : entry.technicianName} · ${_money(entry.amount)}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  entry.note.isEmpty
                      ? Formatters.formatDate(entry.createdAt)
                      : '${Formatters.formatDate(entry.createdAt)} · ${entry.note}',
                ),
                trailing: IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    color: Color(0xFFE53935),
                    size: 20,
                  ),
                  onPressed: () => _deleteSettlement(entry),
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildTechnicianCard(
    BuildContext context,
    TechnicianBalanceSummary summary,
  ) {
    final tech = summary.technician;
    final due = summary.balanceDueToOwner;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) =>
                  TechnicianEarningsScreen(previewTechnician: tech),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: tech.color,
                    child: Text(
                      tech.initials,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                tech.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15.5,
                                  color: AppColors.ink,
                                ),
                              ),
                            ),
                            if (!tech.active) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFE53935)
                                      .withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  context.tr('Отключён', 'Blocked'),
                                  style: const TextStyle(
                                    color: Color(0xFFE53935),
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        Text(
                          '${context.tr('Мастеру', 'Tech')} ${tech.clampedTechPercent.toStringAsFixed(0)}% / ${context.tr('Мне', 'Me')} ${tech.ownerSharePercent.toStringAsFixed(0)}% · ${context.tr('оплачено заказов', 'paid jobs')}: ${summary.paidJobsCount}',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.inkMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
              if (summary.totalTechUnverifiedPartsCost > 0.009) ...[
                const SizedBox(height: 8),
                Text(
                  '${context.tr('Без фото чека запчасти на', 'Parts missing receipt')}: ${_money(summary.totalTechUnverifiedPartsCost)}',
                  style: const TextStyle(
                    color: Color(0xFFE53935),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              const Divider(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.tr('Должен сдать тебе', 'Due to you'),
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.inkMuted,
                          ),
                        ),
                        Text(
                          _money(due),
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w900,
                            color: due > 0.009
                                ? const Color(0xFFE65100)
                                : const Color(0xFF22C55E),
                          ),
                        ),
                        if (summary.totalOwnerPartsCost > 0.009)
                          Text(
                            '${context.tr('в т.ч. твои запчасти', 'incl. your parts')}: ${_money(summary.totalOwnerPartsCost)}',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.inkMuted,
                            ),
                          ),
                      ],
                    ),
                  ),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF22C55E),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () => _showSettleSheet(summary),
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: Text(
                      context.tr('Принял расчёт', 'Settle'),
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
