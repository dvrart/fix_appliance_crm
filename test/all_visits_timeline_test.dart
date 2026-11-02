import 'package:fix_appliance_crm/core/utils/formatters.dart';
import 'package:fix_appliance_crm/features/jobs/active_jobs_screen.dart';
import 'package:fix_appliance_crm/models/job.dart';
import 'package:fix_appliance_crm/services/status_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Правая шторка «Все визиты»: время идёт снизу вверх и внутри дня —
/// раннее внизу, позднее наверху, красная линия «сейчас» между уже
/// начавшимися (ниже) и будущими (выше) визитами.
void main() {
  var phone = 0;
  Job visitAt(String name, DateTime startAt) => Job(
        id: 'job-$name',
        clientId: 'c-$name',
        clientName: name,
        clientPhone: '+141655501${(phone++).toString().padLeft(2, '0')}',
        clientAddress: '1 King St',
        createdAt: DateTime(2026, 10, 1),
        visits: [
          JobVisit(id: 'v-$name', startAt: startAt, durationMinutes: 60),
        ],
      );

  testWidgets('внутри дня позднее сверху, линия «сейчас» между прошедшими и будущими', (
    tester,
  ) async {
    final now = DateTime(2026, 10, 19, 13, 0);
    final jobs = [
      visitAt('Early Morning', DateTime(2026, 10, 19, 10, 0)),
      visitAt('Late Morning', DateTime(2026, 10, 19, 11, 30)),
      visitAt('Early Afternoon', DateTime(2026, 10, 19, 14, 0)),
      visitAt('Late Afternoon', DateTime(2026, 10, 19, 15, 30)),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: AllVisitsScreen(
          jobsStream: Stream<List<Job>>.value(jobs),
          statusesStream: const Stream<List<JobStatusDef>>.empty(),
          referenceNow: now,
          showStatusFilters: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    final nowLine = top(Formatters.formatTime(now));

    expect(top('Late Afternoon'), lessThan(top('Early Afternoon')));
    expect(top('Early Afternoon'), lessThan(nowLine));
    expect(nowLine, lessThan(top('Late Morning')));
    expect(top('Late Morning'), lessThan(top('Early Morning')));
  });

  testWidgets(
    'заявка с переносом показывается один раз по последнему визиту без старых дублей',
    (tester) async {
      final now = DateTime(2026, 10, 25, 12, 0);
      final jobs = [
        Job(
          id: 'job-rescheduled',
          clientId: 'c-monique',
          clientName: 'Monique',
          clientPhone: '+19056647543',
          clientAddress: '1343 Windham Rd',
          status: 'Позвонить',
          createdAt: DateTime(2026, 9, 24),
          visits: [
            JobVisit(
              id: 'v-old',
              startAt: DateTime(2026, 9, 28, 15, 0),
              durationMinutes: 120,
              outcome: JobVisit.done,
            ),
            JobVisit(
              id: 'v-new',
              startAt: DateTime(2026, 10, 23, 10, 0),
              durationMinutes: 120,
              outcome: JobVisit.done,
            ),
          ],
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: AllVisitsScreen(
            jobsStream: Stream<List<Job>>.value(jobs),
            statusesStream: const Stream<List<JobStatusDef>>.empty(),
            referenceNow: now,
            showStatusFilters: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Monique'), findsOneWidget);
      expect(find.text('Позвонить'), findsOneWidget);
      expect(find.text('Перенос'), findsNothing);
    },
  );
}
