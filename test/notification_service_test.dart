import 'package:fix_appliance_crm/services/notification_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final shown = <Map<dynamic, dynamic>>[];
  const device = MethodChannel('fix_appliance/device');
  const notifications = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    SharedPreferences.setMockInitialValues({});
    shown.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(device, (
      call,
    ) async {
      if (call.method == 'showShadeNotification') {
        shown.add(Map<dynamic, dynamic>.from(call.arguments as Map));
      }
      return true;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(notifications, (
      call,
    ) async {
      if (call.method == 'getNotificationAppLaunchDetails') {
        return {'notificationLaunchedApp': false};
      }
      return true;
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(device, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      notifications,
      null,
    );
    debugDefaultTargetPlatformOverride = null;
  });

  test('raw native peer and legacy from resolve to the same phone card', () {
    expect(
      NotificationService.tagFor({
        'type': 'call',
        'peer': '+1 (416) 555-0101',
        'callSid': 'CA-test-1',
      }),
      NotificationService.tagFor({
        'type': 'call',
        'from': '4165550101',
        'callSid': 'CA-test-1',
      }),
    );
  });

  test('an email containing ten digits is still an email card', () {
    expect(
      NotificationService.shadeTag(
        type: 'email',
        from: '4165550101@example.test',
      ),
      'crm_inbox_4165550101@example.test',
    );
  });

  test('long email addresses keep separate cards', () {
    const prefix = 'long.customer.address.with.a.shared.prefix';
    expect(
      NotificationService.shadeTag(
        type: 'email',
        from: '$prefix@first.example.test',
      ),
      isNot(
        NotificationService.shadeTag(
          type: 'email',
          from: '$prefix@second.example.test',
        ),
      ),
    );
  });

  test(
    'unknown caller tags match the server call identity instead of a display name',
    () {
      expect(
        NotificationService.tagFor({
          'type': 'call',
          'from': 'Unknown',
          'callSid': 'CA-test-unknown',
        }),
        'crm_call_CA-test-unknown',
      );
    },
  );

  test('repeated delivery of one call is shown only once', () async {
    final data = {
      'type': 'call',
      'from': '+14165550102',
      'callSid': 'CA-test-repeat',
      'title': 'Пропущенный звонок',
      'body': 'Synthetic call',
    };
    await NotificationService.showRemoteData(data);
    await NotificationService.showRemoteData({...data});
    expect(shown, hasLength(1));
    expect(shown.single['eventId'], 'call:CA-test-repeat');
  });

  test('a separate new call from the same phone is not suppressed', () async {
    for (final sid in ['CA-test-next-1', 'CA-test-next-2']) {
      await NotificationService.showRemoteData({
        'type': 'call',
        'from': '+14165550103',
        'callSid': sid,
        'title': 'Пропущенный звонок',
        'body': 'Synthetic call',
      });
    }
    expect(shown, hasLength(2));
    expect(shown[0]['tag'], shown[1]['tag']);
    expect(shown[0]['eventId'], isNot(shown[1]['eventId']));
  });

  test(
    'native peer payload retains the phone in the notification tap data',
    () async {
      await NotificationService.showRemoteData({
        'type': 'sms',
        'peer': '+14165550104',
        'messageId': 'SM-test-peer',
        'title': 'SMS',
        'body': 'Synthetic message',
      });
      expect(shown.single['from'], '+14165550104');
      expect(shown.single['tag'], 'crm_inbox_4165550104');
    },
  );

  test('an SMS and its extracted repair offer cannot alert twice', () async {
    final data = {
      'type': 'sms',
      'from': '+14165550105',
      'messageId': 'SM-test-offer',
      'title': 'SMS',
      'body': 'Synthetic message',
    };
    await NotificationService.showRemoteData(data);
    await NotificationService.showRemoteData({
      ...data,
      'title': 'SMS: ждёт заявку',
    });
    expect(shown, hasLength(1));
  });
}
