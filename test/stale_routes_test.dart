import 'package:fix_appliance_crm/shared/stale_routes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Card extends StatefulWidget {
  const _Card(this.label, {this.jobId = '', this.clientId = ''});

  final String label;
  final String jobId;
  final String clientId;

  @override
  State<_Card> createState() => _CardState();
}

class _CardState extends State<_Card> {
  @override
  void initState() {
    super.initState();
    StaleRoutes.watchJob(widget.jobId, this);
    StaleRoutes.watchClient(widget.clientId, this);
  }

  @override
  void dispose() {
    StaleRoutes.unwatchJob(widget.jobId, this);
    StaleRoutes.unwatchClient(widget.clientId, this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(widget.label);
}

void main() {
  late GlobalKey<NavigatorState> nav;

  Future<void> boot(WidgetTester tester) async {
    nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: nav, home: const Text('home')),
    );
  }

  Future<void> open(WidgetTester tester, Widget card) async {
    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => card));
    await tester.pumpAndSettle();
  }

  Future<List<String>> backToHome(WidgetTester tester) async {
    final seen = <String>[];
    while (nav.currentState!.canPop()) {
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      final top = tester.widgetList<Text>(find.byType(Text)).last.data!;
      seen.add(top);
    }
    return seen;
  }

  testWidgets('отменённая заявка исчезает из стека: Назад ведёт мимо неё', (
    tester,
  ) async {
    await boot(tester);
    await open(tester, const _Card('job A', jobId: 'a'));
    await open(tester, const _Card('client', clientId: 'c'));
    await open(tester, const _Card('job A again', jobId: 'a'));

    StaleRoutes.dropJob('a');
    await tester.pumpAndSettle();

    expect(find.text('client'), findsOneWidget);
    expect(find.text('job A'), findsNothing);
    expect(await backToHome(tester), ['home']);
  });

  testWidgets('удалённая запись в глубине стека снимается тихо', (
    tester,
  ) async {
    await boot(tester);
    await open(tester, const _Card('job A', jobId: 'a'));
    await open(tester, const _Card('job B', jobId: 'b'));

    StaleRoutes.dropJob('a');
    await tester.pumpAndSettle();

    expect(find.text('job B'), findsOneWidget);
    expect(await backToHome(tester), ['home']);
  });

  testWidgets('нет живых экранов — остаёмся на главном', (tester) async {
    await boot(tester);
    await open(tester, const _Card('client', clientId: 'c'));
    await open(tester, const _Card('client again', clientId: 'c'));

    StaleRoutes.dropClient('c');
    await tester.pumpAndSettle();

    expect(find.text('home'), findsOneWidget);
    expect(nav.currentState!.canPop(), isFalse);
  });
}
