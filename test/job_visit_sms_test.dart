import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fix_appliance_crm/core/constants.dart';
import 'package:fix_appliance_crm/services/network_status_service.dart';
import 'package:fix_appliance_crm/models/job.dart';
import 'package:fix_appliance_crm/services/app_time_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final startAt = DateTime.utc(2026, 1, 15, 14, 30);
  const slotKey = '2026-01-15T09:30';
  late Map<String, dynamic> previousConfig;

  setUp(() {
    previousConfig = {
      'timeSource': AppTimeService.timeSource,
      'timeZoneId': AppTimeService.timeZoneId,
      'timeZoneName': AppTimeService.timeZoneName,
      'timeOffsetSeconds': AppTimeService.offsetSeconds,
    };
    AppTimeService.applyConfig(const {});
  });

  tearDown(() {
    AppTimeService.applyConfig(previousConfig);
  });

  group('Job active visits', () {
    final now = DateTime.utc(2026, 9, 8, 16);

    Job jobWith({
      String status = JobStatuses.call,
      List<JobVisit> visits = const [],
      DateTime? scheduledAt,
      DateTime? deletedAt,
      int durationMinutes = kDefaultVisitMinutes,
    }) => Job(
      id: 'job',
      clientId: 'client',
      clientName: 'Test Client',
      clientPhone: '',
      clientAddress: '',
      createdAt: DateTime.utc(2025, 1, 1),
      status: status,
      visits: visits,
      scheduledAt: scheduledAt,
      deletedAt: deletedAt,
      durationMinutes: durationMinutes,
    );

    test('an imported Canceled job keeps its old visit only as history', () {
      final job = Job.fromMap({
        'status': 'Canceled',
        'createdAt': '2025-10-10T12:00:00Z',
        'visits': [
          {
            'id': 'imported',
            'startAt': '2025-10-11T04:00:00Z',
            'outcome': JobVisit.scheduled,
          },
        ],
      }, 'imported-job');

      expect(job.activeVisits, isEmpty);
      expect(job.nextActiveVisit(now: now), isNull);
      expect(job.coalescedVisits.single.id, 'imported');
      expect(job.coalescedVisits.single.outcome, JobVisit.scheduled);
      expect(job.scheduledAt, DateTime.utc(2025, 10, 11, 4));
    });

    for (final status in [
      'Canceled',
      ' CANCELLED ',
      'cancel',
      JobStatuses.cancelled,
      'Отмена',
      'Отменён',
      JobStatuses.completed,
      'Готово',
      'готов',
      'готова',
      ' Completed ',
      'READY',
    ]) {
      test('closed alias $status excludes even a future scheduled visit', () {
        final visit = JobVisit(
          id: 'future',
          startAt: now.add(const Duration(days: 1)),
        );
        final job = jobWith(status: status, visits: [visit]);

        expect(job.activeVisits, isEmpty);
        expect(job.nextActiveVisit(now: now), isNull);
        expect(job.coalescedVisits, [visit]);
      });
    }

    test('elapsed active visits stay in history but are not upcoming', () {
      final visit = JobVisit(
        id: 'elapsed',
        startAt: now.subtract(const Duration(hours: 3)),
      );
      final job = jobWith(visits: [visit]);

      expect(job.activeVisits, [visit]);
      expect(job.nextActiveVisit(now: now), isNull);
      expect(job.nextActiveVisit(now: visit.endAt), isNull);
      expect(
        job.nextActiveVisit(
          now: visit.endAt.subtract(const Duration(microseconds: 1)),
        ),
        same(visit),
      );
    });

    test('SMS-only cancellation never falls back to the scheduled date', () {
      final visit = JobVisit(
        id: 'sms-cancelled',
        startAt: now.add(const Duration(hours: 1)),
        outcome: JobVisit.scheduled,
        smsConfirmStatus: JobVisit.confirmCancelled,
      );
      final job = jobWith(visits: [visit], scheduledAt: visit.startAt);

      expect(visit.isScheduled, isTrue);
      expect(job.activeVisits, isEmpty);
      expect(job.nextActiveVisit(now: now), isNull);
      expect(job.coalescedVisits, [visit]);
    });

    test('selects the earliest ongoing or future active visit, not the latest', () {
      final ongoing = JobVisit(
        id: 'ongoing',
        startAt: now.subtract(const Duration(minutes: 30)),
        durationMinutes: 60,
      );
      final next = JobVisit(
        id: 'next',
        startAt: now.add(const Duration(hours: 1)),
      );
      final latest = JobVisit(
        id: 'latest',
        startAt: now.add(const Duration(days: 2)),
      );
      final elapsed = JobVisit(
        id: 'elapsed',
        startAt: now.subtract(const Duration(days: 1)),
      );
      final done = JobVisit(
        id: 'done',
        startAt: now.add(const Duration(minutes: 10)),
        outcome: JobVisit.done,
      );
      final cancelled = JobVisit(
        id: 'cancelled',
        startAt: now.add(const Duration(minutes: 15)),
        outcome: JobVisit.cancelled,
      );
      final smsCancelled = JobVisit(
        id: 'sms-cancelled',
        startAt: now.add(const Duration(minutes: 20)),
        smsConfirmStatus: JobVisit.confirmCancelled,
      );
      final visits = [
        latest,
        smsCancelled,
        next,
        done,
        elapsed,
        cancelled,
        ongoing,
      ];
      final job = jobWith(visits: visits, scheduledAt: latest.startAt);

      expect(job.activeVisits, [elapsed, ongoing, next, latest]);
      expect(job.nextActiveVisit(now: now), same(ongoing));
      expect(job.nextActiveVisit(now: ongoing.endAt), same(next));
      expect(job.nextActiveVisit(now: next.endAt), same(latest));
      expect(job.nextActiveVisit(now: latest.endAt), isNull);
      expect(job.visits, visits);
      expect(job.visits.first, same(latest));
      expect(job.coalescedVisits.length, visits.length);
      expect(job.scheduledAt, latest.startAt);
      expect(JobVisit.syncFields(job.coalescedVisits)['scheduledAt'], latest.startAt);
    });

    test('deleted jobs retain visit history without active slots', () {
      final visit = JobVisit(
        id: 'future',
        startAt: now.add(const Duration(days: 1)),
      );
      final job = jobWith(visits: [visit], deletedAt: now);

      expect(job.activeVisits, isEmpty);
      expect(job.nextActiveVisit(now: now), isNull);
      expect(job.coalescedVisits, [visit]);
    });

    test('an open legacy scheduledAt supplies its slot and duration', () {
      final scheduledAt = now.add(const Duration(hours: 1));
      final job = jobWith(scheduledAt: scheduledAt, durationMinutes: 90);
      final visit = job.nextActiveVisit(now: now);

      expect(job.visits, isEmpty);
      expect(job.activeVisits.single.id, 'legacy');
      expect(visit?.id, 'legacy');
      expect(visit?.startAt, scheduledAt);
      expect(visit?.durationMinutes, 90);
      expect(job.nextActiveVisit(now: scheduledAt), isNotNull);
      expect(
        job.nextActiveVisit(now: scheduledAt.add(const Duration(minutes: 90))),
        isNull,
      );
      expect(job.copyWith(status: 'Canceled').activeVisits, isEmpty);
      expect(job.copyWith(deletedAt: now).activeVisits, isEmpty);
    });

    test('legacy timestamp and scheduledDate imports use the same active rule', () {
      final scheduledAt = now.add(const Duration(hours: 1));
      for (final field in ['scheduledAt', 'scheduledDate']) {
        final job = Job.fromMap({
          field: Timestamp.fromDate(scheduledAt),
          'durationMinutes': 90,
        }, 'legacy-job');

        expect(job.activeVisits.single.id, 'legacy');
        expect(job.nextActiveVisit(now: now)?.startAt.toUtc(), scheduledAt);
        expect(job.nextActiveVisit(now: now)?.durationMinutes, 90);
      }
    });

    test('an unscheduled open job has no next visit', () {
      final job = jobWith();

      expect(job.activeVisits, isEmpty);
      expect(job.nextActiveVisit(now: now), isNull);
    });

    test('elapsed checks use instants across the Toronto DST clock rollback', () {
      final during = DateTime.utc(2026, 11, 1, 5, 45);
      final visit = JobVisit(
        id: 'dst-ongoing',
        startAt: DateTime.utc(2026, 11, 1, 5, 30),
        durationMinutes: 60,
      );
      final job = jobWith(visits: [visit]);
      AppTimeService.applyConfig({
        'timeSource': AppTimeService.sourceGeolocation,
        'timeZoneId': 'Asia/Tokyo',
        'timeOffsetSeconds': 9 * 60 * 60,
      });

      expect(
        AppTimeService.bookingWallClock(visit.endAt)
            .isBefore(AppTimeService.bookingWallClock(during)),
        isTrue,
      );
      expect(job.nextActiveVisit(now: during), same(visit));
      expect(job.nextActiveVisit(now: during.toLocal()), same(visit));
      expect(
        job.copyWith(visits: [visit.copyWith(startAt: visit.startAt.toLocal())])
            .nextActiveVisit(now: during)?.id,
        visit.id,
      );
      expect(job.nextActiveVisit(now: visit.endAt.toLocal()), isNull);
    });
  });

  group('JobVisit booking SMS metadata', () {
    test('defaults to an empty nested record', () {
      final visit = JobVisit(id: 'visit', startAt: startAt);

      expect(visit.smsBooking, isEmpty);
      expect(visit.toMap()['smsBooking'], isEmpty);
      expect(visit.bookingSmsState, isEmpty);
      expect(visit.bookingSmsInProgress, isFalse);
    });

    test('round trips and copies preserve all nested metadata', () {
      final metadata = <dynamic, dynamic>{
        'state': 'error',
        'slotKey': slotKey,
        'requestId': 'request-test',
        'messageSid': 'SM-test',
        'error': {'code': 'provider-error', 'message': 'Delivery failed'},
        'attempts': 2,
        'approvedAt': Timestamp.fromDate(startAt),
        'otherMetadata': {
          'history': ['approved', 'sending', 'error'],
          'retryable': true,
        },
      };
      final visit = JobVisit.fromMap({
        'id': 'visit',
        'startAt': Timestamp.fromDate(startAt),
        'smsBooking': metadata,
      });

      expect(visit.smsBooking, metadata);
      expect(identical(visit.smsBooking, metadata), isFalse);
      expect(visit.toMap()['smsBooking'], metadata);
      expect(JobVisit.fromMap(visit.toMap()).smsBooking, metadata);
      expect(visit.copyWith(note: 'Updated note').smsBooking, metadata);
      expect(visit.copyWith(clearSmsDialog: true).smsBooking, metadata);
      expect(
        visit.withManualConfirm(JobVisit.confirmConfirmed).smsBooking,
        metadata,
      );

      final replacement = {...visit.smsBooking, 'state': 'sent'};
      final updated = visit.copyWith(smsBooking: replacement);
      expect(updated.smsBooking, replacement);
      expect(updated.bookingSmsState, 'sent');
      expect(visit.bookingSmsState, 'error');

      metadata['requestId'] = 'changed-source-request';
      expect(visit.smsBooking['requestId'], 'request-test');
    });

    test('ignores absent or non-map nested records', () {
      for (final raw in <dynamic>[null, 'invalid', 42, true, <dynamic>[]]) {
        final visit = JobVisit.fromMap({
          'id': 'visit',
          'startAt': startAt,
          'smsBooking': raw,
        });

        expect(visit.smsBooking, isEmpty, reason: 'Input: $raw');
        expect(visit.bookingSmsState, isEmpty);
      }
    });

    test('clearSms resets nested and legacy state even with an override', () {
      final metadata = <String, dynamic>{
        'state': 'approved',
        'slotKey': slotKey,
        'requestId': 'request-test',
        'messageSid': 'SM-test',
        'error': 'previous-error',
      };
      final visit = JobVisit(
        id: 'visit',
        startAt: startAt,
        smsBooking: metadata,
        smsBookingDayKey: '2026-01-15',
        smsBookingSlotKey: slotKey,
        smsBookingSentAt: startAt,
        smsBookingPendingAt: startAt,
        smsReminderSentAt: startAt,
        smsConfirmStatus: JobVisit.confirmConfirmed,
        smsDialog: 'Confirmed',
        smsBookingPending: true,
        smsBookingSentSms: true,
        smsBookingSentEmail: true,
        smsBookingVia: 'both',
      );
      final cleared = visit.copyWith(clearSms: true, smsBooking: metadata);

      expect(cleared.smsBooking, isEmpty);
      expect(cleared.toMap()['smsBooking'], isEmpty);
      expect(cleared.bookingSmsState, isEmpty);
      expect(cleared.bookingSmsInProgress, isFalse);
      expect(cleared.smsBookingDayKey, isEmpty);
      expect(cleared.smsBookingSlotKey, isEmpty);
      expect(cleared.smsBookingSentAt, isNull);
      expect(cleared.smsBookingPendingAt, isNull);
      expect(cleared.smsReminderSentAt, isNull);
      expect(cleared.smsConfirmStatus, isEmpty);
      expect(cleared.smsDialog, isEmpty);
      expect(cleared.smsBookingPending, isFalse);
      expect(cleared.smsBookingSentSms, isFalse);
      expect(cleared.smsBookingSentEmail, isFalse);
      expect(cleared.smsBookingVia, isEmpty);
      expect(visit.smsBooking, metadata);
      expect(visit.bookingSmsState, 'approved');
    });
  });

  group('JobVisit booking SMS state', () {
    for (final state in [
      'pending',
      'approved',
      'sending',
      'sent',
      'error',
      'rejected',
    ]) {
      test('keeps matching nested $state state authoritative', () {
        final visit = JobVisit(
          id: 'visit',
          startAt: startAt,
          smsBooking: {'state': state, 'slotKey': slotKey},
          smsBookingPending: true,
          smsBookingSlotKey: slotKey,
          smsBookingSentAt: startAt,
          smsBookingSentSms: true,
        );
        final roundTrip = JobVisit.fromMap(visit.toMap());

        expect(roundTrip.bookingSmsState, state);
        expect(
          roundTrip.bookingSmsInProgress,
          state == 'approved' || state == 'sending',
        );
      });
    }

    test('normalizes nested space-separated slot keys', () {
      final visit = JobVisit(
        id: 'visit',
        startAt: startAt,
        smsBooking: {
          'state': 'approved',
          'slotKey': ' 2026-01-15 09:30 ',
        },
      );

      expect(visit.bookingSmsState, 'approved');
      expect(visit.bookingSmsInProgress, isTrue);
    });

    test('a real start change invalidates state without deleting metadata', () {
      final visit = JobVisit(
        id: 'visit',
        startAt: startAt,
        smsBooking: {
          'state': 'approved',
          'slotKey': slotKey,
          'requestId': 'request-test',
        },
      );
      final sameInstant = visit.copyWith(startAt: startAt.toLocal());
      final moved = visit.copyWith(
        startAt: startAt.add(const Duration(hours: 1)),
      );

      expect(sameInstant.bookingSmsState, 'approved');
      expect(moved.smsBooking, visit.smsBooking);
      expect(moved.bookingSmsState, isEmpty);
      expect(moved.bookingSmsInProgress, isFalse);
    });

    test('stale or missing nested slot keys never fall back to legacy', () {
      for (final nestedSlot in [null, '', '2026-01-15 08:30']) {
        final visit = JobVisit(
          id: 'visit',
          startAt: startAt,
          smsBooking: {'state': 'sending', 'slotKey': nestedSlot},
          smsBookingSlotKey: slotKey,
          smsBookingPending: true,
          smsBookingSentAt: startAt,
          smsBookingSentSms: true,
        );

        expect(visit.bookingSmsState, isEmpty);
        expect(visit.bookingSmsInProgress, isFalse);
        expect(visit.copyWith(smsBookingPending: false).bookingSmsState, isEmpty);
      }
    });

    test('a nested record without state does not fall back to legacy', () {
      final visit = JobVisit(
        id: 'visit',
        startAt: startAt,
        smsBooking: {'slotKey': slotKey, 'requestId': 'request-test'},
        smsBookingSlotKey: slotKey,
        smsBookingPending: true,
      );

      expect(visit.bookingSmsState, isEmpty);
    });

    for (final legacySlot in [null, '', slotKey, '2026-01-15 09:30', '2026-01-15  09:30']) {
      test('accepts legacy pending slot key $legacySlot', () {
        final visit = JobVisit.fromMap({
          'id': 'visit',
          'startAt': startAt,
          'smsBookingPending': true,
          if (legacySlot != null) 'smsBookingSlotKey': legacySlot,
        });

        expect(visit.bookingSmsState, 'pending');
        expect(visit.bookingSmsInProgress, isFalse);
      });

      test('accepts legacy sent slot key $legacySlot with SMS evidence', () {
        for (final smsFields in <Map<String, dynamic>>[
          {},
          {'smsBookingVia': ''},
          {'smsBookingSentSms': true},
          {'smsBookingVia': 'sms'},
          {'smsBookingVia': 'both'},
          {'smsBookingVia': ' SMS '},
        ]) {
          final visit = JobVisit.fromMap({
            'id': 'visit',
            'startAt': startAt,
            'smsBookingSentAt': startAt,
            if (legacySlot != null) 'smsBookingSlotKey': legacySlot,
            ...smsFields,
          });

          expect(visit.bookingSmsState, 'sent');
          expect(visit.bookingSmsInProgress, isFalse);
        }
      });
    }

    test('requires a timestamp and excludes explicit email-only delivery', () {
      for (final fields in <Map<String, dynamic>>[
        {'smsBookingSentAt': startAt, 'smsBookingVia': 'email'},
        {'smsBookingSentSms': true},
        {'smsBookingVia': 'sms'},
        {'smsBookingVia': 'both'},
      ]) {
        final visit = JobVisit.fromMap({
          'id': 'visit',
          'startAt': startAt,
          'smsBookingSlotKey': slotKey,
          ...fields,
        });

        expect(visit.bookingSmsState, isEmpty, reason: 'Fields: $fields');
      }
    });

    test('does not reuse pending or sent legacy state for a different slot', () {
      for (final staleSlot in ['2026-01-15T08:30', '2026-01-15 08:30']) {
        final visit = JobVisit(
          id: 'visit',
          startAt: startAt,
          smsBookingSlotKey: staleSlot,
          smsBookingPending: true,
          smsBookingSentAt: startAt,
          smsBookingSentSms: true,
          smsBookingVia: 'sms',
        );

        expect(visit.bookingSmsState, isEmpty);
        expect(visit.copyWith(smsBookingPending: false).bookingSmsState, isEmpty);
      }
    });

    test('matching legacy pending state takes precedence over a sent timestamp', () {
      final visit = JobVisit(
        id: 'visit',
        startAt: startAt,
        smsBookingSlotKey: slotKey,
        smsBookingPending: true,
        smsBookingSentAt: startAt,
        smsBookingSentSms: true,
      );

      expect(visit.bookingSmsState, 'pending');
    });
  });

  group('Booking send waits for saved visits', () {
    test('does not pass the barrier before the server acknowledges writes', () async {
      final pending = Completer<void>();
      var canSend = false;
      final result = waitForWriteAcknowledgement(pending.future).then((ready) => canSend = ready);
      await Future<void>.delayed(Duration.zero);
      expect(canSend, isFalse);
      pending.complete();
      expect(await result, isTrue);
    });

    test('offline writes time out without permitting an SMS send', () async {
      final pending = Completer<void>();
      final ready = await waitForWriteAcknowledgement(
        pending.future,
        wait: const Duration(milliseconds: 10),
      );
      expect(ready, isFalse);
      pending.complete();
    });

    test('write rejection prevents proceeding to SMS', () async {
      await expectLater(
        waitForWriteAcknowledgement(Future<void>.error(StateError('rejected'))),
        throwsStateError,
      );
    });
  });

  group('AppTimeService booking time', () {
    test('uses the exact Toronto winter wall clock and slot key', () {
      final utc = DateTime.utc(2026, 1, 5, 14, 5, 42);

      expect(
        AppTimeService.bookingWallClock(utc),
        DateTime(2026, 1, 5, 9, 5, 42),
      );
      expect(AppTimeService.bookingSlotKey(utc), '2026-01-05T09:05');
      expect(AppTimeService.bookingSlotKey(utc.toLocal()), '2026-01-05T09:05');
    });

    test('uses the exact Toronto summer wall clock and slot key', () {
      final utc = DateTime.utc(2026, 7, 5, 14, 5, 42);

      expect(
        AppTimeService.bookingWallClock(utc),
        DateTime(2026, 7, 5, 10, 5, 42),
      );
      expect(AppTimeService.bookingSlotKey(utc), '2026-07-05T10:05');
      expect(AppTimeService.bookingSlotKey(utc.toLocal()), '2026-07-05T10:05');
    });

    test('uses the Toronto date when UTC is on the following day', () {
      expect(
        AppTimeService.bookingSlotKey(DateTime.utc(2026, 1, 6, 2, 7)),
        '2026-01-05T21:07',
      );
      expect(
        AppTimeService.bookingSlotKey(DateTime.utc(2026, 7, 6, 2, 7)),
        '2026-07-05T22:07',
      );
    });

    for (final source in [
      AppTimeService.sourceManual,
      AppTimeService.sourceGeolocation,
    ]) {
      test('ignores the configured display timezone for $source booking keys', () {
        AppTimeService.applyConfig({
          'timeSource': source,
          'timeZoneId': 'Asia/Tokyo',
          'timeZoneName': 'Tokyo',
          'timeOffsetSeconds': 9 * 60 * 60,
        });
        final winter = DateTime.utc(2026, 1, 5, 14, 5);
        final summer = DateTime.utc(2026, 7, 5, 14, 5);

        expect(
          AppTimeService.format(winter, "yyyy-MM-dd'T'HH:mm"),
          '2026-01-05T23:05',
        );
        expect(AppTimeService.bookingSlotKey(winter), '2026-01-05T09:05');
        expect(AppTimeService.bookingSlotKey(summer), '2026-07-05T10:05');
        expect(
          AppTimeService.bookingWallClock(winter),
          DateTime(2026, 1, 5, 9, 5),
        );
        expect(
          JobVisit(
            id: 'visit',
            startAt: startAt,
            smsBooking: {'state': 'approved', 'slotKey': slotKey},
          ).bookingSmsState,
          'approved',
        );
      });
    }
  });
}
