import 'package:fix_appliance_crm/core/sms_text.dart';
import 'package:fix_appliance_crm/features/messages/conversation_screen.dart';
import 'package:fix_appliance_crm/features/settings/pages/message_templates_page.dart';
import 'package:fix_appliance_crm/models/document_settings.dart';
import 'package:fix_appliance_crm/services/settings_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ComposeMessageSheet renders text field without template button', (tester) async {
    String changedText = '';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComposeMessageSheet(
            initialText: '',
            channel: ConversationChannel.sms,
            sending: false,
            onChanged: (val) => changedText = val,
            onSend: () async {},
          ),
        ),
      ),
    );

    expect(find.text('Сообщение'), findsOneWidget);
    expect(find.text('Выбрать шаблон'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Test message');
    expect(changedText, equals('Test message'));
  });

  test('Unified built-in template catalog covers all 11 templates', () {
    final defaults = SettingsService.defaultSmsTemplates();
    final specKeys = SettingsService.builtinSmsSpecs.map((s) => s.key).toList();
    expect(specKeys.length, 11);
    for (final key in specKeys) {
      expect(defaults.containsKey(key), isTrue, reason: 'Missing default for $key');
      expect(defaults[key]!.trim().isNotEmpty, isTrue, reason: 'Empty default for $key');
    }
  });

  test('Case-insensitive placeholders and custom paySms without {amount} work', () {
    final rendered = DocumentSettings.stripePaySms(
      deposit: false,
      dollars: '150.00',
      url: 'https://pay.example.com/123',
      company: 'Fix Appliance',
      clientName: 'John',
      template: 'Hi {NAME}! Pay link for {COMPANY}: {URL}',
    );
    expect(rendered, 'Hi John! Pay link for Fix Appliance: https://pay.example.com/123');

    final docRendered = DocumentSettings.defaults.applyPlaceholders(
      'Hello {Name}, total is {TOTAL}, link: {URL}',
      clientName: 'Sarah',
      total: 200,
      due: 100,
      paid: 100,
      items: const [],
      url: 'https://doc.example.com/pdf',
    );
    expect(docRendered, 'Hello Sarah, total is \$200.00, link: https://doc.example.com/pdf');
  });

  testWidgets('PlaceholderGuideContent displays all placeholder explanations', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PlaceholderGuideContent(),
          ),
        ),
      ),
    );

    for (final item in SmsText.placeholderGuide) {
      expect(find.text(item.tag), findsOneWidget);
    }
  });
}
