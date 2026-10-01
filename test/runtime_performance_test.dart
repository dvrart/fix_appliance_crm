import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:fix_appliance_crm/features/ai/assistant/review_bell_button.dart';
import 'package:fix_appliance_crm/features/field/field_assistant_host.dart';
import 'package:fix_appliance_crm/features/finance/documents_list_screen.dart';
import 'package:fix_appliance_crm/features/warehouse/warehouse_screen.dart';
import 'package:fix_appliance_crm/features/messages/conversation_screen.dart';
import 'package:fix_appliance_crm/models/calendar_event.dart';
import 'package:fix_appliance_crm/models/job.dart';
import 'package:fix_appliance_crm/services/calendar_event_service.dart';
import 'package:fix_appliance_crm/services/on_the_way_service.dart';
import 'package:fix_appliance_crm/services/scheduled_message_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _WireValue {
  final int type;
  final Object? value;

  const _WireValue(this.type, this.value);
}

class _TestCodec extends StandardMessageCodec {
  const _TestCodec();

  @override
  void writeValue(WriteBuffer buffer, Object? value) {
    if (value is _WireValue) {
      buffer.putUint8(value.type);
      writeValue(buffer, value.value);
    } else {
      super.writeValue(buffer, value);
    }
  }
}

class _FirestoreBackend {
  final TestWidgetsFlutterBinding binding;
  final paths = <String, String>{};
  final active = <String>{};
  int _sequence = 0;
  Completer<void>? writes;
  Completer<void>? notificationInit;

  _FirestoreBackend(this.binding);

  static const codec = _TestCodec();
  static const metadata = _WireValue(140, [false, false]);
  static const emptySnapshot = _WireValue(143, [[], [], metadata]);
  static const api =
      'dev.flutter.pigeon.cloud_firestore_platform_interface.FirebaseFirestoreHostApi';

  Future<void> initialize() async {
    const options = _WireValue(129, [
      'synthetic-key',
      'synthetic-app',
      '123',
      'synthetic-project',
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
    ]);
    const app = _WireValue(130, [
      '[DEFAULT]',
      options,
      false,
      <String, Object?>{},
    ]);
    binding.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.firebase_core_platform_interface.FirebaseCoreHostApi.initializeCore',
      (_) async => codec.encodeMessage([
        [app],
      ]),
    );
    await Firebase.initializeApp();
  }

  void install() {
    binding.defaultBinaryMessenger.setMockMessageHandler('$api.querySnapshot', (
      message,
    ) async {
      final id = 'audit-${_sequence++}';
      paths[id] = 'query';
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel('plugins.flutter.io/firebase_firestore/query/$id'),
        (call) async {
          if (call.method == 'listen') active.add(id);
          if (call.method == 'cancel') active.remove(id);
          return null;
        },
      );
      return codec.encodeMessage([id]);
    });
    binding.defaultBinaryMessenger.setMockMessageHandler(
      '$api.queryGet',
      (_) async => codec.encodeMessage([emptySnapshot]),
    );
    binding.defaultBinaryMessenger.setMockMessageHandler(
      '$api.documentReferenceGet',
      (_) async => codec.encodeMessage([
        const _WireValue(141, ['companies/test/settings/config', {}, metadata]),
      ]),
    );
    for (final method in [
      'documentReferenceSet',
      'documentReferenceUpdate',
      'documentReferenceDelete',
      'writeBatchCommit',
    ]) {
      binding.defaultBinaryMessenger.setMockMessageHandler('$api.$method', (
        _,
      ) async {
        await writes?.future;
        return codec.encodeMessage([null]);
      });
    }
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (call) async {
        if (call.method == 'initialize') await notificationInit?.future;
        if (call.method == 'getNotificationAppLaunchDetails') {
          return {'notificationLaunchedApp': false};
        }
        if (call.method == 'pendingNotificationRequests' ||
            call.method == 'getActiveNotifications') {
          return [];
        }
        return true;
      },
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('fix_appliance/device'),
      (_) async => true,
    );
  }

  void emit(String id) {
    binding.channelBuffers.push(
      'plugins.flutter.io/firebase_firestore/query/$id',
      const StandardMethodCodec(codec).encodeSuccessEnvelope(emptySnapshot),
      (_) {},
    );
  }
}

class _StatefulProbe extends StatefulWidget {
  final VoidCallback onCreate;
  final VoidCallback onDispose;

  const _StatefulProbe({required this.onCreate, required this.onDispose});

  @override
  State<_StatefulProbe> createState() => _StatefulProbeState();
}

class _StatefulProbeState extends State<_StatefulProbe> {
  @override
  void initState() {
    super.initState();
    widget.onCreate();
  }

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('Draft'));
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final backend = _FirestoreBackend(binding);

  setUpAll(backend.initialize);
  setUp(() {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    SharedPreferences.setMockInitialValues({});
    backend.paths.clear();
    backend.active.clear();
    backend.writes = null;
    backend.notificationInit = null;
    backend.install();
  });
  tearDown(() {
    OnTheWayService.instance.pendingStatus = null;
    OnTheWayService.instance.pending = null;
  });

  testWidgets(
    'disposing during notification setup cannot create a late job listener',
    (tester) async {
      final init = backend.notificationInit = Completer<void>();
      await tester.pumpWidget(
        const MaterialApp(home: FieldAssistantHost(child: SizedBox())),
      );
      await tester.pumpWidget(const SizedBox());
      init.complete();
      await tester.pump();
      await tester.pump();
      expect(backend.paths, isEmpty);
    },
  );

  testWidgets(
    'inbox has no unused parts subscription and keeps streams on rebuild',
    (tester) async {
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return const Scaffold(body: ReviewBellButton());
            },
          ),
        ),
      );
      await tester.pump();
      expect(backend.paths.length, 6);
      final ids = backend.paths.keys.toList();
      for (final id in ids) {
        backend.emit(id);
        await tester.pump();
      }
      rebuild(() {});
      await tester.pump();
      expect(backend.paths.length, 6);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(backend.active, isEmpty);
    },
  );

  testWidgets('typing a message does not resubscribe to the entire inbox', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ConversationScreen(
          phoneNumber: '+14165550101',
          contactName: 'Synthetic client',
        ),
      ),
    );
    await tester.pump();
    final before = backend.paths.length;
    expect(before, 2);
    for (final id in backend.paths.keys.toList()) {
      backend.emit(id);
    }
    await tester.pump();
    await tester.tap(
      find.text('Пишите по-русски — клиенту уйдёт на английском'),
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.enterText(find.byType(TextField), 'Draft');
    await tester.pump();
    expect(backend.paths.length, before);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(backend.active, isEmpty);
  });

  testWidgets('warehouse search keeps its existing Firestore subscription', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: WarehouseScreen()));
    await tester.pump();
    expect(backend.paths.length, 1);
    backend.emit(backend.paths.keys.single);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'washer');
    await tester.pump();
    expect(backend.paths.length, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(backend.active, isEmpty);
  });

  testWidgets('switching invoices and estimates keeps the same job stream', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: DocumentsListScreen()));
    await tester.pump();
    expect(backend.paths.length, 1);
    backend.emit(backend.paths.keys.single);
    await tester.pump();
    await tester.tap(find.text('Сметы'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(backend.paths.length, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(backend.active, isEmpty);
  });

  testWidgets(
    'field banners preserve the open screen and late bootstrap stays disposed',
    (tester) async {
      final init = backend.notificationInit = Completer<void>();
      var created = 0;
      var disposed = 0;
      final child = _StatefulProbe(
        onCreate: () => created++,
        onDispose: () => disposed++,
      );
      Future<void> render() => tester.pumpWidget(
        MaterialApp(home: FieldAssistantHost(child: child)),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        if (!init.isCompleted) init.complete();
        await tester.pump();
      });
      await render();
      OnTheWayService.instance.pendingStatus = Job.fromMap({
        'clientName': 'Synthetic client',
        'status': 'Вызов',
      }, 'test-job');
      await render();
      expect(find.text('Нужно изменить статус заявки?'), findsOneWidget);
      expect(created, 1);
      expect(disposed, 0);
      OnTheWayService.instance.pendingStatus = null;
      await render();
      expect(created, 1);
      await tester.pumpWidget(const SizedBox());
      final before = backend.paths.length;
      init.complete();
      await tester.pump();
      await tester.pump();
      expect(backend.paths.length, before);
      expect(disposed, 1);
    },
  );

  testWidgets(
    'calendar save returns a locally queued id without server acknowledgement',
    (tester) async {
      final ack = backend.writes = Completer<void>();
      String? id;
      final result = CalendarEventService.save(
        CalendarEvent(
          id: '',
          title: 'Synthetic event',
          startAt: DateTime(2026, 10, 1, 10),
        ),
      ).then((value) => id = value);
      addTearDown(() {
        if (!ack.isCompleted) ack.complete();
      });
      unawaited(result);
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      expect(id, isNotNull);
    },
  );

  testWidgets('scheduled message save returns without server acknowledgement', (
    tester,
  ) async {
    final ack = backend.writes = Completer<void>();
    String? id;
    final result = ScheduledMessageService.schedule(
      channel: 'sms',
      to: '+14165550101',
      body: 'Synthetic message',
      sendAt: DateTime(2026, 10, 1, 10),
    ).then((value) => id = value);
    addTearDown(() {
      if (!ack.isCompleted) ack.complete();
    });
    unawaited(result);
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(id, isNotNull);
  });
}
