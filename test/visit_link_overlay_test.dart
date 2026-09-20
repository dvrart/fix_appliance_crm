import 'package:fix_appliance_crm/features/calendar/visit_link_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _ReadLinksPainter extends CustomPainter {
  _ReadLinksPainter(this.hub, this.overlay) : super(repaint: hub);
  final VisitLinkHub hub;
  final GlobalKey overlay;

  @override
  void paint(Canvas canvas, Size size) {
    hub.visibleRects(overlay);
  }

  @override
  bool shouldRepaint(_ReadLinksPainter oldDelegate) => true;
}

Widget reporter(VisitLinkHub hub, String key) => VisitLinkReporter(
  key: ValueKey(key),
  hub: hub,
  appointmentId: 'job-1::visit-1',
  jobId: 'job-1',
  startAt: DateTime(2026, 9, 18, 10),
  color: Colors.green,
  enabled: true,
  child: const SizedBox(width: 100, height: 70),
);

Widget frame(VisitLinkHub hub, GlobalKey overlay, List<Widget> children) =>
    MaterialApp(
      home: CustomPaint(
        key: overlay,
        foregroundPainter: _ReadLinksPainter(hub, overlay),
        child: Column(children: children),
      ),
    );

void main() {
  testWidgets(
    'removing a calendar card does not query an inactive element during paint',
    (tester) async {
      final hub = VisitLinkHub();
      final overlay = GlobalKey();
      await tester.pumpWidget(frame(hub, overlay, [reporter(hub, 'first')]));
      await tester.pump();
      expect(hub.visibleRects(overlay), contains('job-1::visit-1'));
      await tester.pumpWidget(frame(hub, overlay, []));
      expect(tester.takeException(), isNull);
      expect(hub.visibleRects(overlay), isEmpty);
      await tester.pumpWidget(const SizedBox());
      hub.dispose();
    },
  );

  testWidgets(
    'disposing an old card cannot unregister its visible replacement',
    (tester) async {
      final hub = VisitLinkHub();
      final overlay = GlobalKey();
      final replacement = reporter(hub, 'replacement');
      await tester.pumpWidget(
        frame(hub, overlay, [reporter(hub, 'old'), replacement]),
      );
      await tester.pump();
      await tester.pumpWidget(frame(hub, overlay, [replacement]));
      expect(tester.takeException(), isNull);
      expect(hub.visibleRects(overlay), contains('job-1::visit-1'));
      await tester.pumpWidget(const SizedBox());
      hub.dispose();
    },
  );

  testWidgets(
    'moving a reporter to another hub releases the old registration',
    (tester) async {
      final first = VisitLinkHub();
      final second = VisitLinkHub();
      final overlay = GlobalKey();
      await tester.pumpWidget(frame(first, overlay, [reporter(first, 'same')]));
      await tester.pump();
      await tester.pumpWidget(
        frame(second, overlay, [reporter(second, 'same')]),
      );
      expect(first.visibleRects(overlay), isEmpty);
      expect(second.visibleRects(overlay), contains('job-1::visit-1'));
      await tester.pumpWidget(const SizedBox());
      first.dispose();
      second.dispose();
    },
  );
}
