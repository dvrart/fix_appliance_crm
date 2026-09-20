import 'dart:async';
import 'dart:convert';

import 'package:fix_appliance_crm/features/ai/assistant/wake_word_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

void main() {
  testWidgets('stop waits for a delayed native STT start and cancels it', (
    tester,
  ) async {
    await _withWake(tester, (h) async {
      h.listenGate = Completer<void>();
      final starting = h.service.start();
      await _pump(tester);
      expect(h.listenCount, 1);

      var stopped = false;
      final stopping = h.service.stop().then((_) => stopped = true);
      await _pump(tester);
      final stoppedBeforeNativeStart = stopped;

      h.listenGate!.complete();
      await _pump(tester);
      await Future.wait([starting, stopping]);

      expect(stoppedBeforeNativeStart, isFalse);
      expect(h.microphoneOpen, isFalse);
      expect(h.events, contains('stt.cancel'));
      expect(h.events, isNot(contains('stt.stop')));
      expect(h.service.isArmed, isFalse);
      await _pump(tester, const Duration(seconds: 1));
      expect(h.listenCount, 1);
    });
  });

  testWidgets('stop during locale lookup prevents a later STT listen', (
    tester,
  ) async {
    await _withWake(tester, (h) async {
      h.localesGate = Completer<void>();
      final starting = h.service.start();
      await _pump(tester);
      expect(h.events, contains('stt.locales'));
      expect(h.listenCount, 0);

      final stopping = h.service.stop();
      await _pump(tester);
      h.localesGate!.complete();
      await _pump(tester);
      await Future.wait([starting, stopping]);

      expect(h.listenCount, 0);
      expect(h.microphoneOpen, isFalse);
      expect(h.service.isArmed, isFalse);
    });
  });

  testWidgets('stop cancels the delayed FIRE callback', (tester) async {
    await _withWake(tester, (h) async {
      var wakes = 0;
      h.service.onWake = () => wakes++;
      await h.service.start();
      await h.result('fix appliance');
      await _pump(tester);
      expect(h.microphoneOpen, isFalse);

      await _pump(tester, const Duration(milliseconds: 100));
      await h.service.stop();
      await _pump(tester, const Duration(milliseconds: 400));

      expect(wakes, 0);
      expect(h.listenCount, 1);
      expect(h.service.isRunning, isFalse);
    });
  });

  testWidgets(
    'stop invalidates starts that have not reached the native queue',
    (tester) async {
      await _withWake(tester, (h) async {
        final first = h.service.start();
        final second = h.service.start();
        final stopping = h.service.stop();
        await _pump(tester);
        await Future.wait([first, second, stopping]);

        expect(h.listenCount, 0);
        expect(h.events, isNot(contains('stt.initialize')));
        expect(h.events, isNot(contains('pcm.start')));
        expect(h.service.isRunning, isFalse);
      });
    },
  );

  for (final phase in [
    'audio guard',
    'permission',
    'initialize',
    'beep mute',
  ]) {
    testWidgets('stop during $phase prevents a native listen', (tester) async {
      await _withWake(tester, (h) async {
        final gate = Completer<void>();
        switch (phase) {
          case 'audio guard':
            h.audioGate = gate;
          case 'permission':
            h.permissionGate = gate;
          case 'initialize':
            h.initializeGate = gate;
          case 'beep mute':
            h.muteGate = gate;
        }
        final starting = h.service.start();
        expect(h.service.isRunning, isTrue);
        await _pump(tester);
        expect(h.listenCount, 0);
        expect(h.service.isArmed, isFalse);
        expect(h.service.isRunning, isTrue);

        final stopping = h.service.stop();
        await _pump(tester);
        gate.complete();
        await _pump(tester);
        await Future.wait([starting, stopping]);

        expect(h.listenCount, 0);
        expect(h.events, isNot(contains('pcm.start')));
        expect(h.service.isRunning, isFalse);
      });
    });
  }

  testWidgets('stop also waits for an in-flight STT reconnect', (tester) async {
    await _withWake(tester, (h) async {
      await h.service.start();
      h.listenGate = Completer<void>();
      await h.status('notListening');
      await _pump(tester, const Duration(milliseconds: 450));
      expect(h.listenCount, 2);

      var stopped = false;
      final stopping = h.service.stop().then((_) => stopped = true);
      await _pump(tester);
      expect(stopped, isFalse);
      h.listenGate!.complete();
      await _pump(tester);
      await stopping;

      expect(h.microphoneOpen, isFalse);
      await _pump(tester, const Duration(seconds: 1));
      expect(h.listenCount, 2);
    });
  });

  testWidgets('a new explicit start waits for the preceding native cancel', (
    tester,
  ) async {
    await _withWake(tester, (h) async {
      await h.service.start();
      h.cancelGate = Completer<void>();
      final stopping = h.service.stop();
      final restarting = h.service.start();
      await _pump(tester);
      expect(h.listenCount, 1);

      h.cancelGate!.complete();
      await _pump(tester);
      await Future.wait([stopping, restarting]);
      expect(h.listenCount, 2);
      expect(h.microphoneOpen, isTrue);
      expect(h.service.isArmed, isTrue);
      expect(h.service.isRunning, isTrue);
    });
  });

  for (final state in ['mediaPlaying', 'carConnected', 'callActive']) {
    testWidgets('$state blocks initial start and resumes only after clearing', (
      tester,
    ) async {
      await _withWake(tester, (h) async {
        h.audioState[state] = true;
        await h.service.start();
        await _pump(tester, const Duration(milliseconds: 500));

        expect(h.listenCount, 0);
        expect(h.events, isNot(contains('stt.initialize')));
        expect(h.events, isNot(contains('pcm.start')));
        expect(h.service.isArmed, isFalse);
        expect(h.service.isRunning, isTrue);

        h.audioState[state] = false;
        await _pump(tester, const Duration(milliseconds: 500));
        expect(h.listenCount, 1);
        expect(h.microphoneOpen, isTrue);
        expect(h.service.isArmed, isTrue);
      });
    });

    testWidgets('$state blocks STT reconnect until clearing', (tester) async {
      await _withWake(tester, (h) async {
        await h.service.start();
        h.audioState[state] = true;
        await h.status('notListening');
        await _pump(tester, const Duration(milliseconds: 450));
        await _pump(tester, const Duration(milliseconds: 450));

        expect(h.listenCount, 1);
        expect(h.microphoneOpen, isFalse);
        expect(h.service.isArmed, isFalse);

        h.audioState[state] = false;
        await _pump(tester, const Duration(milliseconds: 450));
        expect(h.listenCount, 2);
        expect(h.microphoneOpen, isTrue);
      });
    });

    testWidgets('$state acquired during locale lookup prevents listening', (
      tester,
    ) async {
      await _withWake(tester, (h) async {
        h.localesGate = Completer<void>();
        final starting = h.service.start();
        await _pump(tester);
        expect(h.events, contains('stt.locales'));

        h.audioState[state] = true;
        h.localesGate!.complete();
        await _pump(tester);
        await starting;
        expect(h.listenCount, 0);
        expect(h.microphoneOpen, isFalse);
      });
    });
  }

  testWidgets('media acquired during native STT start cancels the opened mic', (
    tester,
  ) async {
    await _withWake(tester, (h) async {
      h.listenGate = Completer<void>();
      final starting = h.service.start();
      await _pump(tester);
      expect(h.listenCount, 1);

      h.audioState['mediaPlaying'] = true;
      h.listenGate!.complete();
      await _pump(tester);
      await starting;
      expect(h.microphoneOpen, isFalse);
      expect(h.service.isArmed, isFalse);
      expect(h.events, contains('stt.cancel'));
      await _pump(tester, const Duration(milliseconds: 500));
      expect(h.listenCount, 1);
    });
  });

  testWidgets('FIRE rechecks media before delivering the wake', (tester) async {
    await _withWake(tester, (h) async {
      var wakes = 0;
      h.service.onWake = () => wakes++;
      await h.service.start();
      await h.result('fix appliance');
      await _pump(tester);
      expect(h.service.isRunning, isTrue);
      h.audioState['carConnected'] = true;
      await _pump(tester, const Duration(milliseconds: 280));

      expect(wakes, 0);
      expect(h.service.isRunning, isFalse);
      expect(h.microphoneOpen, isFalse);
    });
  });

  testWidgets('stop invalidates FIRE already awaiting the audio guard', (
    tester,
  ) async {
    await _withWake(tester, (h) async {
      var wakes = 0;
      h.service.onWake = () => wakes++;
      await h.service.start();
      await h.result('fix appliance');
      await _pump(tester);
      h.audioGate = Completer<void>();
      await _pump(tester, const Duration(milliseconds: 280));
      await h.service.stop();
      h.audioGate!.complete();
      await _pump(tester);

      expect(wakes, 0);
      expect(h.microphoneOpen, isFalse);
    });
  });

  testWidgets('an allowed wake fires once after microphone cleanup', (
    tester,
  ) async {
    await _withWake(tester, (h) async {
      var wakes = 0;
      h.service.onWake = () {
        expectSync(h.microphoneOpen, isFalse);
        expectSync(h.recorder.recording, isFalse);
        wakes++;
      };
      await h.service.start();
      await h.result('fix appliance');
      await _pump(tester);
      expect(wakes, 0);
      await _pump(tester, const Duration(milliseconds: 280));
      expect(wakes, 1);
      await _pump(tester, const Duration(seconds: 1));
      expect(wakes, 1);
      expect(h.listenCount, 1);
    });
  });

  testWidgets('STT initialization failure reaches the PCM permission path', (
    tester,
  ) async {
    await _withWake(tester, (h) async {
      h.sttAvailable = false;
      await h.service.start();

      expect(
        h.events.where((event) => event == 'permission.request').length,
        2,
      );
      expect(h.listenCount, 0);
    });
  });

  testWidgets(
    'stop waits for a pending PCM start before stopping the recorder',
    (tester) async {
      await _withWake(tester, (h) async {
        h.sttAvailable = false;
        h.recorder.startGate = Completer<void>();
        final starting = h.service.start();
        await _pump(tester);
        if (!_hasPcm(h)) return;

        var stopped = false;
        final stopping = h.service.stop().then((_) => stopped = true);
        await _pump(tester);
        expect(stopped, isFalse);
        h.recorder.startGate!.complete();
        await _pump(tester);
        await Future.wait([starting, stopping]);

        expect(h.recorder.recording, isFalse);
        expect(h.service.isRunning, isFalse);
        final lastStart = h.events.lastIndexOf('pcm.start');
        expect(h.events.lastIndexOf('pcm.stop'), greaterThan(lastStart));
        await _pump(tester, const Duration(seconds: 9));
        expect(h.events.where((event) => event == 'pcm.start').length, 1);
      });
    },
  );

  testWidgets('media acquired during PCM start closes the mic', (tester) async {
    await _withWake(tester, (h) async {
      h.sttAvailable = false;
      h.recorder.startGate = Completer<void>();
      final starting = h.service.start();
      await _pump(tester);
      if (!_hasPcm(h)) return;

      h.audioState['mediaPlaying'] = true;
      h.recorder.startGate!.complete();
      await _pump(tester);
      await starting;
      expect(h.recorder.recording, isFalse);
      expect(h.service.isArmed, isFalse);
      await _pump(tester, const Duration(seconds: 8));
      expect(h.events.where((event) => event == 'pcm.start').length, 1);
    });
  });

  for (final state in ['mediaPlaying', 'carConnected', 'callActive']) {
    testWidgets('$state blocks PCM reconnect until clearing', (tester) async {
      await _withWake(tester, (h) async {
        h.sttAvailable = false;
        await h.service.start();
        if (!_hasPcm(h)) return;
        expect(h.recorder.recording, isTrue);

        h.audioState[state] = true;
        h.recorder.stream.addError(StateError('microphone disconnected'));
        await _pump(tester);
        expect(h.recorder.recording, isFalse);
        await _pump(tester, const Duration(seconds: 8));
        expect(h.events.where((event) => event == 'pcm.start').length, 1);

        h.audioState[state] = false;
        await _pump(tester, const Duration(seconds: 8));
        expect(h.events.where((event) => event == 'pcm.start').length, 2);
        expect(h.recorder.recording, isTrue);
      });
    });
  }

  testWidgets(
    'dispose waits for pending start and native cleanup without notify',
    (tester) async {
      await _withWake(tester, (h) async {
        var notifications = 0;
        h.service.addListener(() => notifications++);
        h.listenGate = Completer<void>();
        h.cancelGate = Completer<void>();
        final starting = h.service.start();
        await _pump(tester);
        expect(h.listenCount, 1);

        h.service.dispose();
        final notificationsAtDispose = notifications;
        await _pump(tester);
        expect(h.events, isNot(contains('pcm.dispose')));
        expect(h.events, isNot(contains('stt.cancel')));

        h.listenGate!.complete();
        await _pump(tester);
        expect(h.events, contains('stt.cancel'));
        expect(h.events, isNot(contains('pcm.dispose')));
        h.cancelGate!.complete();
        await _pump(tester);
        await starting;
        await h.service.stop();

        expect(h.microphoneOpen, isFalse);
        expect(h.recorder.disposed, isTrue);
        expect(h.events.last, 'pcm.dispose');
        expect(notifications, notificationsAtDispose);
        expect(tester.takeException(), isNull);
        await h.service.start();
        expect(h.listenCount, 1);
      });
    },
  );
}

bool _hasPcm(_WakeHarness h) {
  if (h.events.contains('pcm.start')) return true;
  expect(
    h.blockedReasons,
    contains('Не настроен ключ Gemini — wake-слово не работает.'),
  );
  markTestSkipped('PCM capture requires a configured application Gemini key.');
  return false;
}

Future<void> _pump(
  WidgetTester tester, [
  Duration duration = Duration.zero,
]) async {
  await tester.pump(duration);
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

Future<void> _withWake(
  WidgetTester tester,
  Future<void> Function(_WakeHarness) body,
) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  final h = _WakeHarness();
  try {
    await body(h);
  } finally {
    for (final gate in [
      h.audioGate,
      h.permissionGate,
      h.initializeGate,
      h.localesGate,
      h.muteGate,
      h.listenGate,
      h.cancelGate,
      h.recorder.startGate,
    ]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    await _pump(tester);
    final stopping = h.service.stop();
    await _pump(tester);
    await stopping;
    await h.speech.cancel();
    h.service.dispose();
    await _pump(tester);
    await h.service.stop();
    await _pump(tester, const Duration(seconds: 3));
    h.removeMocks();
    debugDefaultTargetPlatformOverride = null;
  }
}

class _WakeHarness {
  static const speechChannel = MethodChannel(
    'plugin.csdcorp.com/speech_to_text',
  );
  static const permissionChannel = MethodChannel(
    'flutter.baseflow.com/permissions/methods',
  );
  static const deviceChannel = MethodChannel('fix_appliance/device');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final speech = stt.SpeechToText.withMethodChannel();
  final events = <String>[];
  final blockedReasons = <String>[];
  final audioState = <String, bool>{
    'mediaPlaying': false,
    'carConnected': false,
    'callActive': false,
  };
  late final _FakeRecorder recorder;
  late final WakeWordService service;
  Completer<void>? audioGate;
  Completer<void>? permissionGate;
  Completer<void>? initializeGate;
  Completer<void>? localesGate;
  Completer<void>? muteGate;
  Completer<void>? listenGate;
  Completer<void>? cancelGate;
  bool microphoneOpen = false;
  bool sttAvailable = true;

  _WakeHarness() {
    recorder = _FakeRecorder(events);
    messenger.setMockMethodCallHandler(speechChannel, _speechCall);
    messenger.setMockMethodCallHandler(permissionChannel, (call) async {
      if (call.method == 'requestPermissions') {
        events.add('permission.request');
        await permissionGate?.future;
        return {for (final id in call.arguments as List) id: 1};
      }
      return 1;
    });
    messenger.setMockMethodCallHandler(deviceChannel, (call) async {
      if (call.method == 'assistantAudioState') {
        events.add('audio.state');
        final state = Map<String, bool>.of(audioState);
        await audioGate?.future;
        return state;
      }
      if (call.method == 'muteRecognitionBeeps' && call.arguments == true) {
        events.add('audio.mute');
        await muteGate?.future;
      }
      if (call.method == 'hasCarAudio') return audioState['carConnected'];
      return true;
    });
    service = WakeWordService(recorder: recorder, speech: speech)
      ..onBlocked = blockedReasons.add;
  }

  int get listenCount => events.where((event) => event == 'stt.listen').length;

  Future<Object?> _speechCall(MethodCall call) async {
    events.add('stt.${call.method}');
    switch (call.method) {
      case 'initialize':
        await initializeGate?.future;
        return sttAvailable;
      case 'locales':
        await localesGate?.future;
        return ['ru_RU:Russian', 'en_US:English'];
      case 'listen':
        await listenGate?.future;
        microphoneOpen = true;
        await status('listening');
        return true;
      case 'cancel':
      case 'stop':
        await cancelGate?.future;
        microphoneOpen = false;
        await status('notListening');
        return true;
      default:
        throw MissingPluginException(call.method);
    }
  }

  Future<void> status(String value) async {
    if (value == 'notListening' || value == 'done') microphoneOpen = false;
    await messenger.handlePlatformMessage(
      speechChannel.name,
      speechChannel.codec.encodeMethodCall(MethodCall('notifyStatus', value)),
      null,
    );
  }

  Future<void> result(String words) async {
    await messenger.handlePlatformMessage(
      speechChannel.name,
      speechChannel.codec.encodeMethodCall(
        MethodCall(
          'textRecognition',
          jsonEncode({
            'alternates': [
              {'recognizedWords': words, 'confidence': 1.0},
            ],
            'resultType': 0,
          }),
        ),
      ),
      null,
    );
  }

  void removeMocks() {
    messenger.setMockMethodCallHandler(speechChannel, null);
    messenger.setMockMethodCallHandler(permissionChannel, null);
    messenger.setMockMethodCallHandler(deviceChannel, null);
  }
}

class _FakeRecorder implements AudioRecorder {
  final List<String> events;
  final stream = StreamController<Uint8List>.broadcast();
  Completer<void>? startGate;
  bool recording = false;
  bool disposed = false;

  _FakeRecorder(this.events);

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    events.add('pcm.start');
    await startGate?.future;
    if (disposed) throw StateError('Recorder already disposed');
    recording = true;
    return stream.stream;
  }

  @override
  Future<bool> isRecording() async => recording;

  @override
  Future<String?> stop() async {
    events.add('pcm.stop');
    recording = false;
    return null;
  }

  @override
  Future<void> dispose() async {
    events.add('pcm.dispose');
    disposed = true;
    await stream.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
