import 'package:fix_appliance_crm/services/twilio_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the outcome of another call cannot disconnect the current caller', () {
    expect(
      TwilioService.isStaleIncomingRecord({
        'callSid': 'CA-previous',
        'status': 'completed',
        'answeredBy': 'ai',
      }, expectedCallSid: 'CA-current'),
      isFalse,
    );
  });

  test('a missing call identity never authorizes disconnecting', () {
    expect(
      TwilioService.isStaleIncomingRecord({
        'status': 'completed',
      }, expectedCallSid: ''),
      isFalse,
    );
  });

  test(
    'ringing for more than 40 seconds is allowed by the 60-second pickup setting',
    () {
      expect(
        TwilioService.isStaleIncomingRecord({
          'callSid': 'CA-current',
          'status': 'ringing',
          'startTime': DateTime.now().subtract(const Duration(seconds: 55)),
        }, expectedCallSid: 'CA-current'),
        isFalse,
      );
    },
  );

  test('an answered master call is not stale while Flutter catches up', () {
    expect(
      TwilioService.isStaleIncomingRecord({
        'callSid': 'CA-current',
        'status': 'in-progress',
        'answeredBy': 'master',
      }, expectedCallSid: 'CA-current'),
      isFalse,
    );
  });

  test('a matching call handed to the secretary clears the old ringing UI', () {
    expect(
      TwilioService.isStaleIncomingRecord({
        'callSid': 'CA-current',
        'status': 'in-progress',
        'answeredBy': 'ai',
      }, expectedCallSid: 'CA-current'),
      isTrue,
    );
  });

  for (final status in [
    'completed',
    'canceled',
    'cancelled',
    'no-answer',
    'busy',
    'failed',
  ]) {
    test('a matching $status call clears the old ringing UI', () {
      expect(
        TwilioService.isStaleIncomingRecord({
          'callSid': 'CA-current',
          'status': status,
        }, expectedCallSid: 'CA-current'),
        isTrue,
      );
    });
  }
}
