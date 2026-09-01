import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../models/job.dart';
import 'job_service.dart';
import 'local_notification_service.dart';
import 'settings_service.dart';
import 'warehouse_service.dart';
import '../core/l10n/app_locale.dart';

/// Уведомления: утром в 7:00 про сегодняшний день, вечером в 19:00 про завтра.
class MorningBriefingService {
  static String buildBody(List<Job> jobs, [DateTime? day]) {
    if (jobs.isEmpty) return '';
    final target = day ?? DateTime.now();
    final timeFormat = DateFormat('H:mm');
    final buffer = StringBuffer();
    for (final job in jobs) {
      final visitTime = job.visitOn(target)?.startAt ?? job.scheduledAt;
      final time = visitTime != null ? timeFormat.format(visitTime) : '';
      final who = job.contactName.trim().isEmpty ? 'Клиент'.tr : job.contactName.trim();
      buffer.writeln('$time — $who, ${trAny(job.applianceType)}'.trim());
      final packing = job.packingList;
      if (packing.isNotEmpty) {
        buffer.writeln('  ${'Взять'.tr}: ${packing.take(6).join(', ')}');
      }
    }
    return buffer.toString().trim();
  }

  static Future<void> refresh([List<Job>? allJobs]) async {
    final config = await SettingsService.loadConfig();
    final morningHour = SettingsService.readMorningBriefingHour(config);
    final eveningHour = SettingsService.readEveningBriefingHour(config);
    if (!SettingsService.boolFlag(config, 'morningBriefingEnabled')) {
      await LocalNotificationService.cancelMorning(hour: morningHour);
      await LocalNotificationService.cancelEvening(hour: eveningHour);
      return;
    }

    final jobs = allJobs ?? await JobService.loadAllOnce();

    final lowStock = SettingsService.boolFlag(config, 'lowStockAlertEnabled')
        ? await _lowStockLine()
        : '';

    final morningWhen = LocalNotificationService.nextAtHour(morningHour);
    final todayJobs = JobService.activeForDay(jobs, morningWhen);
    if (todayJobs.isEmpty && lowStock.isEmpty) {
      await LocalNotificationService.cancelMorning(hour: morningHour);
    } else {
      final body = [
        if (todayJobs.isNotEmpty) buildBody(todayJobs, morningWhen),
        if (lowStock.isNotEmpty) lowStock,
      ].join('\n\n');
      await LocalNotificationService.scheduleMorning(
        title: todayJobs.isEmpty
            ? 'Запчасти на исходе'.tr
            : _jobCountTitle(todayJobs.length, tomorrow: false),
        body: body,
        hour: morningHour,
      );
    }

    final eveningWhen = LocalNotificationService.nextAtHour(eveningHour);
    final tomorrow = DateTime(
      eveningWhen.year,
      eveningWhen.month,
      eveningWhen.day,
    ).add(const Duration(days: 1));
    final tomorrowJobs = JobService.activeForDay(jobs, tomorrow);
    if (tomorrowJobs.isEmpty) {
      await LocalNotificationService.cancelEvening(hour: eveningHour);
    } else {
      await LocalNotificationService.scheduleEvening(
        title: _jobCountTitle(tomorrowJobs.length, tomorrow: true),
        body: buildBody(tomorrowJobs, tomorrow),
        hour: eveningHour,
      );
    }

    await LocalNotificationService.scheduleVisitAlerts(jobs);
  }

  /// Строка «что заканчивается» для утреннего уведомления.
  static Future<String> _lowStockLine() async {
    try {
      final low = await WarehouseService.getLowStock();
      if (low.isEmpty) return '';
      final names = low.take(5).map((item) {
        final min = item.minQuantity ?? 0;
        return '${item.name} — ${item.quantity}/$min';
      }).toList();
      final more = low.length - names.length;
      return [
        '${'Заканчивается'.tr}:',
        ...names.map((line) => '  $line'),
        if (more > 0) '  +$more',
      ].join('\n');
    } catch (error) {
      debugPrint('Low stock line: $error');
      return '';
    }
  }

  static String _jobCountTitle(int count, {required bool tomorrow}) {
    if (AppLocale.instance.isEn) {
      final noun = count == 1 ? 'job' : 'jobs';
      return tomorrow ? 'Tomorrow: $count $noun' : 'Today: $count $noun';
    }
    final mod10 = count % 10;
    final mod100 = count % 100;
    final word = (mod10 == 1 && mod100 != 11)
        ? 'заявка'
        : (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14))
            ? 'заявки'
            : 'заявок';
    return tomorrow ? 'Завтра $count $word' : 'Сегодня $count $word';
  }
}
