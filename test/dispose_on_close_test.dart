import 'package:fix_appliance_crm/shared/widgets/dispose_on_close.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _TrackedController extends TextEditingController {
  _TrackedController() : super(text: '12');

  bool disposed = false;

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

/// Красный экран в Отчётах (24.10.2026): поле окна уничтожали сразу после
/// `await showModalBottomSheet`, а окно ещё уезжало и перестраивалось, пока
/// пряталась клавиатура. `DisposeOnClose` ждёт, пока окно уйдёт из дерева.
void main() {
  testWidgets('поле окна живо, пока окно уезжает, и уничтожается после', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final ctrl = _TrackedController();
    var afterAwait = '';

    Future<void> open(BuildContext context) async {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (sheetCtx) => DisposeOnClose(
          disposables: [ctrl],
          child: StatefulBuilder(
            builder: (ctx, setSheet) => Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(ctx).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(controller: ctrl, autofocus: true),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(sheetCtx),
                    child: const Text('save'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      // Сразу после `await` текст ещё читается, а окно ещё на экране.
      afterAwait = ctrl.text;
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => open(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();

    await tester.tap(find.text('save'));
    await tester.pump();
    expect(afterAwait, '12');
    expect(ctrl.disposed, isFalse);

    // Клавиатура прячется, пока окно уезжает: поле перестраивается.
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump(const Duration(milliseconds: 50));
    expect(ctrl.disposed, isFalse);

    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsNothing);
    expect(ctrl.disposed, isTrue);
  });
}
