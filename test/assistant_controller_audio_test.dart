import 'dart:async';

import 'package:fix_appliance_crm/features/ai/assistant/assistant_controller.dart';
import 'package:fix_appliance_crm/services/assistant_audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';

void main() {
  testWidgets(
    'denied audio focus never requests permission or starts the mic',
    (tester) async {
      await _withAssistant(tester, (h) async {
        h.focusGranted = false;
        await h.controller.open();

        expect(h.controller.isOpen, isFalse);
        expect(h.controller.isConnecting, isFalse);
        expect(h.controller.errorText, isNotNull);
        expect(h.events, isNot(contains('permission.request')));
        expect(h.recorder.startCount, 0);
        expect(h.events, contains('focus.release'));
      });
    },
  );

  testWidgets('missing native focus support fails closed', (tester) async {
    await _withAssistant(tester, (h) async {
      h.messenger.setMockMethodCallHandler(
        _AssistantHarness.deviceChannel,
        (_) async => throw MissingPluginException('Audio focus unavailable'),
      );
      await h.controller.open();

      expect(h.controller.isOpen, isFalse);
      expect(h.events, isNot(contains('permission.request')));
      expect(h.recorder.startCount, 0);
    });
  });

  testWidgets('close waits for pending native focus before releasing it', (
    tester,
  ) async {
    await _withAssistant(tester, (h) async {
      h.focusGate = Completer<void>();
      final opening = h.controller.open();
      await _pump(tester);
      expect(h.events, contains('focus.request'));

      var closed = false;
      final closing = h.controller.close().then((_) => closed = true);
      await _pump(tester);
      expect(closed, isFalse);
      expect(h.events, isNot(contains('focus.release')));

      h.focusGate!.complete();
      await _pump(tester);
      await Future.wait([opening, closing]);

      expect(h.controller.isOpen, isFalse);
      expect(h.events, isNot(contains('permission.request')));
      expect(h.recorder.startCount, 0);
      expect(
        h.events.indexOf('focus.granted'),
        lessThan(h.events.indexOf('focus.release')),
      );
    });
  });

  testWidgets(
    'close does not wait for permission and rejects its stale result',
    (tester) async {
      await _withAssistant(tester, (h) async {
        h.permissionGranted = true;
        h.permissionGate = Completer<void>();
        final firstOpening = h.controller.open();
        await _pump(tester);
        expect(h.events, contains('permission.request'));

        await h.controller.close();
        expect(h.permissionGate!.isCompleted, isFalse);
        expect(h.controller.isOpen, isFalse);

        h.focusGranted = false;
        h.focusGate = Completer<void>();
        final secondOpening = h.controller.open();
        await _pump(tester);
        final status = h.controller.statusText;
        expect(h.controller.isOpen, isTrue);

        h.permissionGate!.complete();
        await _pump(tester);
        await firstOpening;
        expect(h.controller.isOpen, isTrue);
        expect(h.controller.isConnecting, isTrue);
        expect(h.controller.statusText, status);
        expect(h.controller.errorText, isNull);
        expect(h.recorder.startCount, 0);

        h.focusGate!.complete();
        await _pump(tester);
        await secondOpening;
        expect(h.controller.isOpen, isFalse);
        expect(
          h.events.where((event) => event == 'permission.request'),
          hasLength(1),
        );
      });
    },
  );

  testWidgets('playback blocks both opening and resuming the assistant', (
    tester,
  ) async {
    await _withAssistant(tester, (h) async {
      await h.acquirePlayback();
      await h.controller.open();
      expect(h.controller.isOpen, isFalse);
      expect(h.events, isNot(contains('focus.request')));

      h.markPaused();
      await h.controller.togglePause();
      expect(h.controller.isPaused, isTrue);
      expect(h.recorder.startCount, 0);
    });
  });

  testWidgets(
    'playback and concurrent closes wait for a delayed native mic start',
    (tester) async {
      await _withAssistant(tester, (h) async {
        h.markPaused();
        h.recorder.startGate = Completer<void>();
        final resuming = h.controller.togglePause();
        await _pump(tester);
        expect(h.recorder.startCount, 1);

        AssistantAudioService.playback.suspendMicrophone = h.controller.close;
        var playbackReady = false;
        final acquiring = h.acquirePlayback().then((_) {
          playbackReady = true;
          h.events.add('playback.ready');
        });
        final closing = h.controller.close();
        expect(identical(closing, h.controller.close()), isTrue);
        await _pump(tester);
        expect(playbackReady, isFalse);
        expect(h.controller.isOpen, isFalse);
        expect(h.events, isNot(contains('focus.release')));

        await h.controller.open();
        await h.controller.togglePause();
        expect(h.recorder.startCount, 1);

        h.recorder.startGate!.complete();
        await _pump(tester);
        await _settle(tester, Future.wait([resuming, closing, acquiring]));

        expect(playbackReady, isTrue);
        expect(h.recorder.microphoneOpen, isFalse);
        expect(h.controller.statusText, isEmpty);
        expect(
          h.events.indexOf('mic.started'),
          lessThan(h.events.indexOf('mic.stopped')),
        );
        expect(
          h.events.lastIndexOf('mic.stopped'),
          lessThan(h.events.indexOf('focus.release')),
        );
        expect(
          h.events.indexOf('focus.release'),
          lessThan(h.events.indexOf('playback.ready')),
        );
        final stopCount = h.recorder.stopCount;
        await h.controller.close();
        expect(h.recorder.stopCount, stopCount);
      });
    },
  );

  testWidgets(
    'playback arriving during native start stops the returned stream',
    (tester) async {
      await _withAssistant(tester, (h) async {
        h.markPaused();
        h.recorder.startGate = Completer<void>();
        final resuming = h.controller.togglePause();
        await _pump(tester);
        expect(h.recorder.startCount, 1);

        await h.acquirePlayback();
        h.recorder.startGate!.complete();
        await _pump(tester);
        await resuming;

        expect(h.recorder.microphoneOpen, isFalse);
        expect(h.events, contains('mic.stopped'));
      });
    },
  );

  testWidgets(
    'closing during recorder state lookup prevents a later mic start',
    (tester) async {
      await _withAssistant(tester, (h) async {
        h.markPaused();
        h.recorder.stateGate = Completer<void>();
        final resuming = h.controller.togglePause();
        await _pump(tester);
        expect(h.events, contains('mic.isRecording'));

        final closing = h.controller.close();
        h.recorder.stateGate!.complete();
        await _pump(tester);
        await _settle(tester, Future.wait([resuming, closing]));

        expect(h.recorder.startCount, 0);
        expect(h.recorder.microphoneOpen, isFalse);
        expect(h.controller.isOpen, isFalse);
      });
    },
  );

  testWidgets(
    'overlapping pause toggles cannot restart while native stop waits',
    (tester) async {
      await _withAssistant(tester, (h) async {
        h.markPaused();
        await h.controller.togglePause();
        expect(h.recorder.microphoneOpen, isTrue);

        h.recorder.stopGate = Completer<void>();
        final pausing = h.controller.togglePause();
        await _pump(tester);
        expect(h.controller.isPaused, isTrue);
        await h.controller.togglePause();
        expect(h.recorder.startCount, 1);
        expect(h.controller.isPaused, isTrue);

        h.recorder.stopGate!.complete();
        await _pump(tester);
        await pausing;
        expect(h.recorder.microphoneOpen, isFalse);
        expect(h.controller.isPaused, isTrue);
      });
    },
  );

  testWidgets('dispose also waits for native start and closes the microphone', (
    tester,
  ) async {
    await _withAssistant(tester, (h) async {
      h.markPaused();
      h.recorder.startGate = Completer<void>();
      final resuming = h.controller.togglePause();
      await _pump(tester);
      h.disposeController();
      await _pump(tester);
      expect(h.recorder.disposed.isCompleted, isFalse);

      h.recorder.startGate!.complete();
      await _pump(tester);
      await resuming;
      await _settle(tester, h.recorder.disposed.future);
      expect(h.recorder.microphoneOpen, isFalse);
      expect(
        h.events.lastIndexOf('mic.stopped'),
        lessThan(h.events.indexOf('mic.dispose')),
      );
    });
  });
}

Future<void> _pump(WidgetTester tester) async {
  for (var turn = 0; turn < 4; turn++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  await tester.pump();
}

Future<T> _settle<T>(WidgetTester tester, Future<T> operation) async {
  var complete = false;
  final result = operation.whenComplete(() => complete = true);
  for (var turn = 0; !complete && turn < 30; turn++) {
    await _pump(tester);
  }
  expect(complete, isTrue, reason: 'Native audio operation did not settle');
  return result;
}

Future<void> _withAssistant(
  WidgetTester tester,
  Future<void> Function(_AssistantHarness) body,
) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  final h = _AssistantHarness();
  try {
    await body(h);
  } finally {
    final closing = h.controller.close();
    for (final gate in [
      h.focusGate,
      h.permissionGate,
      h.recorder.startGate,
      h.recorder.stateGate,
      h.recorder.stopGate,
    ]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    await _pump(tester);
    await _settle(tester, closing);
    h.disposeController();
    await _pump(tester);
    await _settle(tester, h.recorder.disposed.future);
    await _pump(tester);
    h.removeMocks();
    debugDefaultTargetPlatformOverride = null;
  }
}

class _AssistantHarness {
  static const deviceChannel = MethodChannel('fix_appliance/device');
  static const pcmChannel = MethodChannel('flutter_pcm_sound/methods');
  static const permissionChannel = MethodChannel(
    'flutter.baseflow.com/permissions/methods',
  );

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final previousRecorder = RecordPlatform.instance;
  final previousSuspend = AssistantAudioService.playback.suspendMicrophone;
  final playbackOwner = Object();
  final events = <String>[];
  late final _FakeRecorderPlatform recorder;
  late final AssistantController controller;
  Completer<void>? focusGate;
  Completer<void>? permissionGate;
  bool focusGranted = true;
  bool permissionGranted = false;
  bool controllerDisposed = false;

  _AssistantHarness() {
    recorder = _FakeRecorderPlatform(events);
    RecordPlatform.instance = recorder;
    AssistantAudioService.playback.suspendMicrophone = null;
    messenger.setMockMethodCallHandler(pcmChannel, (_) async => null);
    messenger.setMockMethodCallHandler(deviceChannel, (call) async {
      if (call.method == 'requestAssistantAudioFocus') {
        events.add('focus.request');
        await focusGate?.future;
        if (focusGranted) events.add('focus.granted');
        return focusGranted;
      }
      if (call.method == 'releaseAssistantAudioFocus') {
        events.add('focus.release');
        return null;
      }
      throw MissingPluginException(call.method);
    });
    messenger.setMockMethodCallHandler(permissionChannel, (call) async {
      if (call.method == 'requestPermissions') {
        events.add('permission.request');
        await permissionGate?.future;
        return {
          for (final id in call.arguments as List)
            id: permissionGranted ? 1 : 0,
        };
      }
      throw MissingPluginException(call.method);
    });
    controller = AssistantController();
  }

  void markPaused() {
    controller.isOpen = true;
    controller.isPaused = true;
  }

  Future<void> acquirePlayback() =>
      AssistantAudioService.playback.acquire(playbackOwner);

  void disposeController() {
    if (controllerDisposed) return;
    controllerDisposed = true;
    controller.dispose();
  }

  void removeMocks() {
    AssistantAudioService.playback.release(playbackOwner);
    AssistantAudioService.playback.suspendMicrophone = previousSuspend;
    RecordPlatform.instance = previousRecorder;
    messenger.setMockMethodCallHandler(deviceChannel, null);
    messenger.setMockMethodCallHandler(pcmChannel, null);
    messenger.setMockMethodCallHandler(permissionChannel, null);
  }
}

class _FakeRecorderPlatform extends RecordPlatform {
  final List<String> events;
  final stream = StreamController<Uint8List>.broadcast();
  final disposed = Completer<void>();
  Completer<void>? startGate;
  Completer<void>? stateGate;
  Completer<void>? stopGate;
  bool microphoneOpen = false;
  int startCount = 0;
  int stopCount = 0;

  _FakeRecorderPlatform(this.events);

  @override
  Future<void> create(String recorderId) async {}

  @override
  Stream<RecordState> onStateChanged(String recorderId) => const Stream.empty();

  @override
  Future<Stream<Uint8List>> startStream(
    String recorderId,
    RecordConfig config,
  ) async {
    startCount++;
    events.add('mic.start');
    await startGate?.future;
    microphoneOpen = true;
    events.add('mic.started');
    return stream.stream;
  }

  @override
  Future<bool> isRecording(String recorderId) async {
    events.add('mic.isRecording');
    await stateGate?.future;
    return microphoneOpen;
  }

  @override
  Future<String?> stop(String recorderId) async {
    stopCount++;
    events.add('mic.stop');
    await stopGate?.future;
    microphoneOpen = false;
    events.add('mic.stopped');
    return null;
  }

  @override
  Future<void> dispose(String recorderId) async {
    events.add('mic.dispose');
    microphoneOpen = false;
    await stream.close();
    disposed.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
