import 'package:fix_appliance_crm/features/calls/call_review_page.dart';
import 'package:fix_appliance_crm/services/twilio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final testCall = CallRecord(
    id: 'CA123456789',
    callSid: 'CA123456789',
    fromNumber: '+14165551234',
    toNumber: '+16471234567',
    direction: 'inbound',
    startTime: DateTime(2026, 9, 25, 14, 30),
    answeredBy: 'ai',
  );

  testWidgets('CallReviewHeaderCard renders phone, call and message buttons', (tester) async {
    var callTapped = false;
    var messageTapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CallReviewHeaderCard(
            call: testCall,
            name: 'John Doe',
            phone: '+14165551234',
            onCall: () => callTapped = true,
            onMessage: () => messageTapped = true,
          ),
        ),
      ),
    );

    expect(find.text('John Doe'), findsOneWidget);
    expect(find.text('+14165551234'), findsOneWidget);
    expect(find.text('Позвонить'), findsOneWidget);
    expect(find.text('Написать'), findsOneWidget);

    await tester.tap(find.text('Позвонить'));
    expect(callTapped, isTrue);

    await tester.tap(find.text('Написать'));
    expect(messageTapped, isTrue);
  });

  testWidgets('CallReviewHeaderCard copies phone number on tap', (tester) async {
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall methodCall) async {
        if (methodCall.method == 'Clipboard.setData') {
          copiedText = (methodCall.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CallReviewHeaderCard(
            call: testCall,
            name: 'John Doe',
            phone: '+14165551234',
          ),
        ),
      ),
    );

    await tester.tap(find.text('+14165551234'));
    await tester.pump(const Duration(seconds: 3));
    expect(copiedText, equals('+14165551234'));
  });
}
