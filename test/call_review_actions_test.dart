import 'package:fix_appliance_crm/features/calls/call_review_page.dart';
import 'package:fix_appliance_crm/features/jobs/job_details/editors/call_recording_page.dart';
import 'package:fix_appliance_crm/services/message_translate_service.dart';
import 'package:fix_appliance_crm/services/twilio_service.dart';
import 'package:fix_appliance_crm/shared/widgets/call_transcript_chat.dart';
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

  test('English dialog with Russian speaker labels needs Russian and shorter Russian translation wins', () {
    const englishWithRuLabels =
        'ИИ: FixApplianceCA, this is Sarah. How can I help you?\n'
        'Клиент: Are they repaired?\n'
        'ИИ: Oh, are you calling about your oven repair scheduled for today at 452 Norwich Road?\n'
        'Клиент: Yeah, I might be home by five.';
    const russianTranslated =
        'ИИ: Это FixApplianceCA, Сара. Чем могу помочь?\n'
        'Клиент: Они уже починили?\n'
        'ИИ: Вы звоните по поводу ремонта духовки сегодня на 452 Norwich Road?\n'
        'Клиент: Да, я буду дома к пяти.';

    expect(russianTranslated.length, lessThan(englishWithRuLabels.length));
    expect(MessageTranslateService.isRussianDialog(englishWithRuLabels), isFalse);
    expect(MessageTranslateService.needsRussianDialog(englishWithRuLabels), isTrue);
    expect(MessageTranslateService.isRussianDialog(russianTranslated), isTrue);
    expect(MessageTranslateService.needsRussianDialog(russianTranslated), isFalse);

    expect(
      keepFullerTranscript(englishWithRuLabels, russianTranslated),
      equals(russianTranslated),
    );
    expect(
      keepFullerTranscript(russianTranslated, englishWithRuLabels),
      equals(russianTranslated),
    );
    expect(
      callTranscriptText({
        'transcription': englishWithRuLabels,
        'transcriptionRu': russianTranslated,
        'transcriptionEn': englishWithRuLabels,
      }),
      equals(russianTranslated),
    );
  });
}
