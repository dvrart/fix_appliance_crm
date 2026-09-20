import 'package:fix_appliance_crm/shared/widgets/dirty_leave_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'form controllers outlive pop completion and are disposed after the reverse animation',
    (tester) async {
      final controller = TextEditingController(text: 'Test part');
      var disposed = false;
      var popped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () {
                  showDialog<void>(
                    context: context,
                    builder: (context) {
                      return DirtyLeaveScope(
                        dirty: false,
                        registerGate: false,
                        onSave: () async => true,
                        onDispose: () {
                          disposed = true;
                          controller.dispose();
                        },
                        child: AlertDialog(
                          content: TextField(controller: controller),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Close'),
                            ),
                          ],
                        ),
                      );
                    },
                  ).whenComplete(() => popped = true);
                },
                child: const Text('Open'),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close'));
      await tester.pump();
      expect(popped, isTrue);
      expect(disposed, isFalse);
      controller.text = 'Still alive while closing';
      await tester.pumpAndSettle();
      expect(disposed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
