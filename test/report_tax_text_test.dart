import 'package:fix_appliance_crm/features/reports/report_breakdown_page.dart';
import 'package:fix_appliance_crm/services/job_reminder_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('«HST и налоги» выключено', () {
    test('пометка «без HST» убирается, остальное остаётся', () {
      expect(ReportTaxText.clean('Грязными (без HST)'), 'Грязными');
      expect(ReportTaxText.clean('Грязными без HST: \$5.00'), 'Грязными: \$5.00');
      expect(ReportTaxText.clean('= Грязными (выручка без HST)'), '= Грязными (выручка)');
      expect(ReportTaxText.clean('Gross (excl. HST)'), 'Gross');
    });

    test('строки про сам налог распознаются', () {
      expect(ReportTaxText.mentionsTax('− HST в счетах'), isTrue);
      expect(ReportTaxText.mentionsTax('Счета с HST'), isTrue);
      expect(ReportTaxText.mentionsTax('из них HST (налог CRA)'), isTrue);
      expect(ReportTaxText.mentionsTax('Грязными (без HST)'), isFalse);
      expect(ReportTaxText.mentionsTax('Запчасти мне'), isFalse);
    });

    test('в составной подписи уходят только куски про налог', () {
      expect(
        ReportTaxText.plain(
          'Грязными без HST: \$100.00 (с HST \$113.00) · С HST: \$113.00 · Запчасти мне: \$20.00',
        ),
        'Грязными: \$100.00 · Запчасти мне: \$20.00',
      );
      expect(
        ReportTaxText.plain('С HST: \$113.00\nПришло: \$50.00'),
        'Пришло: \$50.00',
      );
    });
  });

  group('напоминание о карточке', () {
    test('текст и файлы переживают сохранение', () {
      final entry = JobReminderEntry(
        jobId: 'job-1',
        clientId: 'c1',
        clientName: 'Amelia',
        applianceType: 'Washer',
        city: 'Simcoe',
        description: '',
        remindAt: DateTime(2026, 11, 5, 10),
        note: 'Позвонить насчёт насоса',
        files: const [
          JobReminderFile(path: '/data/r/1_pump.jpg', name: 'pump.jpg'),
          JobReminderFile(path: '/data/r/2_order.pdf', name: 'order.pdf'),
        ],
      );
      final back = JobReminderEntry.fromJson(entry.toJson());
      expect(back.note, 'Позвонить насчёт насоса');
      expect(back.files.map((f) => f.name), ['pump.jpg', 'order.pdf']);
      expect(back.files.first.isImage, isTrue);
      expect(back.files.last.isImage, isFalse);
      expect(back.hasContent, isTrue);
      expect(back.seen, isFalse);
    });

    test('старая запись без текста читается как раньше', () {
      final back = JobReminderEntry.fromJson({
        'jobId': 'job-2',
        'remindAt': '2026-11-05T10:00:00.000',
        'fired': true,
      });
      expect(back.note, '');
      expect(back.files, isEmpty);
      expect(back.hasContent, isFalse);
      expect(back.fired, isTrue);
    });
  });
}
