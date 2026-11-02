import 'package:flutter/material.dart';

import '../../core/l10n/app_locale.dart';
import '../../features/jobs/job_details/job_details_screen.dart';
import '../../models/job.dart';
import '../../core/constants.dart';
import '../../services/client_service.dart';
import '../../services/job_service.dart';
import '../app_nav.dart';

/// Кнопка «это звонок (письмо, SMS) вот по этой заявке» в шапке экрана.
///
/// Звонок и переписка сами по себе не отвечают на вопрос «а что у нас с этим
/// человеком в работе»: мастер видел текст разговора, но не видел, к какой
/// заявке он относится, и искал её руками в списке. Сначала это была плашка
/// над лентой, но она съедала верх экрана — по просьбе FIX (21.10.2026) она
/// стала значком в правом верхнем углу, рядом с кнопкой контакта.
///
/// Заявки нет — кнопки нет. Если передан [onCreateJob], вместо пустоты
/// показывается кнопка «Создать заявку»: в переписке с неизвестным номером
/// это единственный путь завести карточку клиента и заявку.
class JobLinkButton extends StatefulWidget {
  /// Заявка, привязанная напрямую (`call.createdJobId`, `message.jobId`).
  final String? jobId;

  /// Запасной путь: заявки клиента или заявки по номеру телефона.
  final String? clientId;
  final String phone;

  /// Что делать, когда заявки не нашлось. Пусто — кнопка не рисуется вовсе.
  final VoidCallback? onCreateJob;

  /// Кнопка занята: ИИ разбирает переписку перед созданием заявки.
  /// Вместо значка показывается индикатор.
  final bool busy;

  const JobLinkButton({
    super.key,
    this.jobId,
    this.clientId,
    this.phone = '',
    this.onCreateJob,
    this.busy = false,
  });

  /// Заявка, к которой относится разговор: сперва прямая привязка, потом
  /// карточка клиента, потом номер телефона. Из нескольких берётся живая
  /// и самая свежая — закрытая показывается, только если живой нет.
  static Future<Job?> resolve({
    String jobId = '',
    String clientId = '',
    String phone = '',
  }) async {
    final id = jobId.trim();
    if (id.isNotEmpty) {
      final job = await JobService.getById(id);
      if (job != null && !job.isDeleted) return job;
    }

    final candidates = <Job>[];
    if (clientId.trim().isNotEmpty) {
      candidates.addAll(await JobService.streamByClient(clientId.trim()).first);
    }
    final digits = ClientService.normalizePhone(phone);
    if (candidates.isEmpty && digits.length >= 10) {
      for (final job in await JobService.loadAllOnce()) {
        final phones = [
          ClientService.normalizePhone(job.clientPhone),
          ClientService.normalizePhone(job.contactPhone),
          ClientService.normalizePhone(job.jobSitePhone ?? ''),
        ];
        if (phones.contains(digits)) candidates.add(job);
      }
    }

    Job? best;
    for (final job in candidates) {
      if (job.isDeleted || job.isMergedDuplicate) continue;
      if (best == null) {
        best = job;
        continue;
      }
      final bestOpen = !JobStatuses.isClosed(best.status);
      final jobOpen = !JobStatuses.isClosed(job.status);
      if (jobOpen != bestOpen) {
        if (jobOpen) best = job;
        continue;
      }
      if (_sortTime(job).isAfter(_sortTime(best))) best = job;
    }
    return best;
  }

  static DateTime _sortTime(Job job) =>
      job.latestVisit?.startAt ?? job.scheduledAt ?? job.createdAt;

  @override
  State<JobLinkButton> createState() => _JobLinkButtonState();
}

class _JobLinkButtonState extends State<JobLinkButton> {
  Job? _job;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant JobLinkButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.jobId != widget.jobId ||
        oldWidget.clientId != widget.clientId ||
        oldWidget.phone != widget.phone) {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final job = await JobLinkButton.resolve(
        jobId: widget.jobId ?? '',
        clientId: widget.clientId ?? '',
        phone: widget.phone,
      );
      if (!mounted) return;
      setState(() => _job = job);
    } catch (_) {}
  }

  Future<void> _open(Job job) async {
    await AppNav.openCard(
      context,
      rootNavigator: true,
      key: AppNav.jobKey(job.id),
      builder: (_) => JobDetailsScreen(
        jobId: job.id,
        clientId: job.clientId,
        jobData: job.toMap(),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final job = _job;
    if (job == null) {
      final create = widget.onCreateJob;
      if (create == null) return const SizedBox.shrink();
      // Заметная кнопка, как у звонка в шапке: в переписке с незнакомым
      // номером мастер ищет именно её — «как завести заявку». Пока ИИ
      // разбирает переписку, горит индикатор; повторные нажатия гасит
      // сам обработчик.
      return IconButton.filled(
        visualDensity: VisualDensity.compact,
        icon: widget.busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.black,
                ),
              )
            : const Icon(Icons.add_task, size: 20),
        tooltip: context.tr('Создать заявку', 'Create job'),
        style: IconButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.black,
        ),
        onPressed: create,
      );
    }
    final appliance =
        (job.primaryAppliance?.displayName ?? job.applianceType).trim();
    return IconButton(
      visualDensity: VisualDensity.compact,
      icon: const Icon(
        Icons.assignment_outlined,
        color: Colors.white,
        size: 22,
      ),
      // Подсказка говорит, какая именно заявка откроется: иконка одна,
      // а заявок у клиента может быть несколько.
      tooltip: [
        context.tr('Заявка клиента', 'Client job'),
        if (appliance.isNotEmpty) appliance,
        job.status,
      ].join(' · '),
      onPressed: () => _open(job),
    );
  }
}
