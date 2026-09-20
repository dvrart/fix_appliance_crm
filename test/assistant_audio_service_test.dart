import 'dart:async';

import 'package:fix_appliance_crm/services/assistant_audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  group('Playback microphone ownership', () {
    late PlaybackMicrophoneGuard guard;

    setUp(() => guard = PlaybackMicrophoneGuard());
    tearDown(() => guard.dispose());

    test(
      'blocks synchronously and waits for physical microphone shutdown',
      () async {
        final stopped = Completer<void>();
        var mayPlay = false;
        guard.suspendMicrophone = () {
          expect(guard.isActive, isTrue);
          return stopped.future;
        };
        final owner = Object();
        final ready = guard.acquire(owner).then((_) => mayPlay = true);

        expect(guard.isActive, isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(mayPlay, isFalse);
        stopped.complete();
        await ready;
        expect(mayPlay, isTrue);
        expect(guard.isActive, isTrue);
        guard.release(owner);
        expect(guard.isActive, isFalse);
      },
    );

    test(
      'overlapping players share shutdown and release only their own hold',
      () async {
        final stopped = Completer<void>();
        var stops = 0;
        final changes = <bool>[];
        guard.addListener(() => changes.add(guard.isActive));
        guard.suspendMicrophone = () {
          stops++;
          return stopped.future;
        };
        final first = Object();
        final second = Object();
        final ready = Future.wait([
          guard.acquire(first),
          guard.acquire(second),
        ]);
        expect(stops, 1);
        stopped.complete();
        await ready;
        guard.release(first);
        guard.release(first);
        expect(guard.isActive, isTrue);
        guard.release(second);
        expect(guard.isActive, isFalse);
        expect(changes, [true, false]);
      },
    );

    test('a failed start never leaves the microphone blocked', () async {
      guard.suspendMicrophone = () async =>
          throw StateError('microphone stop failed');
      await expectLater(guard.acquire(Object()), throwsStateError);
      expect(guard.isActive, isFalse);
      guard.suspendMicrophone = () async {};
      final retry = Object();
      await guard.acquire(retry);
      expect(guard.isActive, isTrue);
      guard.release(retry);
    });

    test(
      'failure of a second player does not release the first player',
      () async {
        final first = Object();
        await guard.acquire(first);
        guard.suspendMicrophone = () async => throw StateError('failed');
        await expectLater(guard.acquire(Object()), throwsStateError);
        expect(guard.isActive, isTrue);
        guard.release(first);
        expect(guard.isActive, isFalse);
      },
    );

    test('disposal while waiting cannot resurrect a playback hold', () async {
      final stopped = Completer<void>();
      guard.suspendMicrophone = () => stopped.future;
      final owner = Object();
      final ready = guard.acquire(owner);
      guard.release(owner);
      stopped.complete();
      await ready;
      expect(guard.isActive, isFalse);
    });
  });

  group('Passive wake audio policy', () {
    const channel = MethodChannel('fix_appliance/device');
    const clear = {
      'mediaPlaying': false,
      'carConnected': false,
      'callActive': false,
    };
    late Object owner;
    late List<String> nativeCalls;
    late Future<dynamic> Function(MethodCall) nativeHandler;

    setUp(() {
      owner = Object();
      nativeCalls = [];
      nativeHandler = (_) async => clear;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) {
        nativeCalls.add(call.method);
        return nativeHandler(call);
      });
    });

    tearDown(() {
      AssistantAudioService.playback.release(owner);
      AssistantAudioService.playback.suspendMicrophone = null;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    test('idle phone permits wake listening', () async {
      expect(await AssistantAudioService.canListenForWake(), isTrue);
      expect(nativeCalls, ['assistantAudioState']);
    });

    for (final field in clear.keys) {
      test('$field blocks automatic microphone use', () async {
        nativeHandler = (_) async => {...clear, field: true};
        expect(await AssistantAudioService.canListenForWake(), isFalse);
        expect(nativeCalls, ['assistantAudioState']);
      });
    }

    test(
      'disconnecting the car permits listening again, without requesting focus',
      () async {
        nativeHandler = (_) async => {...clear, 'carConnected': true};
        expect(await AssistantAudioService.canListenForWake(), isFalse);
        nativeHandler = (_) async => clear;
        expect(await AssistantAudioService.canListenForWake(), isTrue);
        expect(nativeCalls, everyElement('assistantAudioState'));
      },
    );

    test(
      'local playback prevents native probing and assistant focus requests',
      () async {
        await AssistantAudioService.playback.acquire(owner);
        expect(await AssistantAudioService.canListenForWake(), isFalse);
        expect(await AssistantAudioService.requestFocus(), isFalse);
        expect(nativeCalls, isEmpty);
        AssistantAudioService.playback.release(owner);
        expect(await AssistantAudioService.canListenForWake(), isTrue);
      },
    );

    test('playback starting during a native query takes precedence', () async {
      final result = Completer<Map<String, bool>>();
      nativeHandler = (_) => result.future;
      final allowed = AssistantAudioService.canListenForWake();
      await AssistantAudioService.playback.acquire(owner);
      result.complete(clear);
      expect(await allowed, isFalse);
    });

    test('unavailable native audio state fails closed', () async {
      nativeHandler = (_) async => throw PlatformException(code: 'unavailable');
      expect(await AssistantAudioService.canListenForWake(), isFalse);
      nativeHandler = (_) async => null;
      expect(await AssistantAudioService.canListenForWake(), isFalse);
      nativeHandler = (_) async => {'mediaPlaying': false};
      expect(await AssistantAudioService.canListenForWake(), isFalse);
    });
  });
}
