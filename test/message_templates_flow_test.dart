import 'package:fix_appliance_crm/features/messages/conversation_screen.dart';
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
}
