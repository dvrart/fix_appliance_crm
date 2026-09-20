import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:fix_appliance_crm/features/jobs/job_details/editors/call_recording_page.dart';
import 'package:fix_appliance_crm/services/assistant_audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const playerChannel = MethodChannel('xyz.luan/audioplayers');
  const deviceChannel = MethodChannel('fix_appliance/device');
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const globalChannel = MethodChannel('xyz.luan/audioplayers.global');
  const globalEvents = MethodChannel('xyz.luan/audioplayers.global/events');
  late Directory temporary;
  late List<MethodCall> calls;
  late List<MethodChannel> eventChannels;
  late String playerId;
  late int position;
  late bool failResume;
  late bool callActive;

  Future<void> emit(String event, [Object? value]) async {
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      'xyz.luan/audioplayers/events/$playerId',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'event': event,
        'value': ?value,
      }),
      (_) {},
    );
  }

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('crm-audio-test-');
    calls = [];
    eventChannels = [];
    position = 0;
    failResume = false;
    callActive = false;
    AssistantAudioService.playback.suspendMicrophone = () async {};
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      globalChannel,
      (_) async => null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      globalEvents,
      (_) async => null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      (_) async => temporary.path,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      deviceChannel,
      (_) async => {
        'mediaPlaying': false,
        'carConnected': false,
        'callActive': callActive,
      },
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(playerChannel, (
      call,
    ) async {
      calls.add(call);
      final args = Map<String, dynamic>.from(call.arguments as Map);
      playerId = args['playerId'] as String;
      switch (call.method) {
        case 'create':
          final events = MethodChannel(
            'xyz.luan/audioplayers/events/$playerId',
          );
          eventChannels.add(events);
          binding.defaultBinaryMessenger.setMockMethodCallHandler(
            events,
            (_) async => null,
          );
        case 'setSourceUrl':
        case 'setSourceBytes':
          await emit('audio.onPrepared', true);
          await emit('audio.onDuration', 60000);
        case 'getDuration':
          return 60000;
        case 'getCurrentPosition':
          return position;
        case 'resume':
          expect(AssistantAudioService.playback.isActive, isTrue);
          if (failResume) throw PlatformException(code: 'playback_failed');
        case 'stop':
          position = 0;
        case 'seek':
          position = args['position'] as int;
          await emit('audio.onSeekComplete');
      }
      return null;
    });
    await AudioPlayer.global.ensureInitialized();
  });

  tearDown(() async {
    AssistantAudioService.playback.suspendMicrophone = null;
    expect(AssistantAudioService.playback.isActive, isFalse);
    for (final channel in [
      playerChannel,
      deviceChannel,
      pathChannel,
      globalChannel,
      globalEvents,
      ...eventChannels,
    ]) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    }
    await temporary.delete(recursive: true);
  });

  Future<void> mountPlayer(WidgetTester tester) async {
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: CallAudioPlayer(
                url: 'https://example.invalid/recording.wav',
                attachment: {},
              ),
            ),
          ),
        );
        for (var attempt = 0; attempt < 80; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          if (find.byIcon(Icons.play_arrow).evaluate().isNotEmpty) break;
        }
      },
      () => MockClient(
        (_) async => http.Response.bytes(
          Uint8List.fromList([0x52, 0x49, 0x46, 0x46, ...List.filled(100, 0)]),
          200,
          headers: {'content-type': 'audio/wav'},
        ),
      ),
    );
    expect(
      find.byIcon(Icons.play_arrow),
      findsOneWidget,
      reason: 'Native calls: ${calls.map((call) => call.method).join(', ')}',
    );
    expect(calls.where((call) => call.method == 'resume'), isEmpty);
  }

  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> disposePlayer(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
    expect(
      calls.where((call) => call.method == 'dispose'),
      hasLength(1),
      reason: 'Native calls: ${calls.map((call) => call.method).join(', ')}',
    );
  }

  testWidgets(
    'playback waits for the microphone and releases it on completion',
    (tester) async {
      final stopped = Completer<void>();
      AssistantAudioService.playback.suspendMicrophone = () => stopped.future;
      await mountPlayer(tester);
      await tester.tap(find.byIcon(Icons.play_arrow));
      await flush(tester);
      expect(AssistantAudioService.playback.isActive, isTrue);
      expect(calls.where((call) => call.method == 'resume'), isEmpty);
      stopped.complete();
      await flush(tester);
      expect(find.byIcon(Icons.pause), findsOneWidget);
      expect(calls.where((call) => call.method == 'resume'), hasLength(1));
      final context =
          calls.lastWhere((call) => call.method == 'setAudioContext').arguments
              as Map;
      expect(context['usageType'], AndroidUsageType.media.value);
      expect(context['audioMode'], AndroidAudioMode.normal.value);
      expect(context['audioFocus'], AndroidAudioFocus.gainTransient.value);
      await emit('audio.onComplete');
      await flush(tester);
      expect(AssistantAudioService.playback.isActive, isFalse);
      await disposePlayer(tester);
    },
  );

  testWidgets(
    'pause releases audio focus, resumes at the same position, and re-blocks the mic',
    (tester) async {
      var microphoneStops = 0;
      AssistantAudioService.playback.suspendMicrophone = () async =>
          microphoneStops++;
      await mountPlayer(tester);
      await tester.tap(find.byIcon(Icons.play_arrow));
      await flush(tester);
      position = 12345;
      await tester.tap(find.byIcon(Icons.pause));
      await flush(tester);
      expect(AssistantAudioService.playback.isActive, isFalse);
      expect(calls.where((call) => call.method == 'stop'), hasLength(1));
      expect(find.text('00:12 / 01:00'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.play_arrow));
      await flush(tester);
      expect(AssistantAudioService.playback.isActive, isTrue);
      expect(microphoneStops, 2);
      final seek =
          calls.lastWhere((call) => call.method == 'seek').arguments as Map;
      expect(seek['position'], 12345);
      expect(find.byIcon(Icons.pause), findsOneWidget);
      await disposePlayer(tester);
      expect(AssistantAudioService.playback.isActive, isFalse);
    },
  );

  testWidgets(
    'closing the page during microphone shutdown does not start audio later',
    (tester) async {
      final stopped = Completer<void>();
      AssistantAudioService.playback.suspendMicrophone = () => stopped.future;
      await mountPlayer(tester);
      await tester.tap(find.byIcon(Icons.play_arrow));
      await flush(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      stopped.complete();
      await flush(tester);
      expect(calls.where((call) => call.method == 'resume'), isEmpty);
      expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
      expect(AssistantAudioService.playback.isActive, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'playback errors stop the player and return microphone ownership',
    (tester) async {
      failResume = true;
      await mountPlayer(tester);
      await tester.tap(find.byIcon(Icons.play_arrow));
      await flush(tester);
      expect(calls.where((call) => call.method == 'stop'), isNotEmpty);
      expect(AssistantAudioService.playback.isActive, isFalse);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      await disposePlayer(tester);
    },
  );

  testWidgets(
    'a real call prevents changing the media audio context or starting playback',
    (tester) async {
      callActive = true;
      await mountPlayer(tester);
      await tester.tap(find.byIcon(Icons.play_arrow));
      await flush(tester);
      expect(calls.where((call) => call.method == 'resume'), isEmpty);
      expect(calls.where((call) => call.method == 'setAudioContext'), isEmpty);
      expect(AssistantAudioService.playback.isActive, isFalse);
      await disposePlayer(tester);
    },
  );
}
