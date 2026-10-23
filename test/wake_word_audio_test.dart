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

  for (final state in ['mediaPlaying', 'callActive']) {
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
      h.audioState['mediaPlaying'] = true;
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

  testWidgets('STT initialization failure does not bounce back to PCM', (
    tester,
  ) async {
    // PCM — основной путь, STT — запасной. Возврат из запасного в основной
    // крутил бы оба микрофонных тракта по кругу.
    await _withWake(tester, (h) async {
      h.sttAvailable = false;
      await h.service.start();

      expect(h.events, isNot(contains('pcm.start')));
      expect(h.listenCount, 0);
      expect(h.service.isArmed, isFalse);
    });
  });

  testWidgets('the wake word listens on PCM without touching STT', (
    tester,
  ) async {
    await _withWake(tester, (h) async {
      await h.service.start();
      if (!_hasPcm(h)) return;

      expect(h.recorder.recording, isTrue);
      expect(h.service.isArmed, isTrue);
      expect(h.events, isNot(contains('stt.initialize')));
      expect(h.listenCount, 0);
    }, preferStt: false);
  });

  testWidgets('the PCM microphone is not reopened while it keeps running', (
    tester,
  ) async {
    // Из-за чего всё и затевалось: STT закрывал сессию по тишине и каждые
    // пару секунд щёлкал микрофоном. Поток PCM открывается один раз.
    await _withWake(tester, (h) async {
      await h.service.start();
      if (!_hasPcm(h)) return;

      await _pump(tester, const Duration(seconds: 9));
      await _pump(tester, const Duration(seconds: 9));

      expect(h.events.where((event) => event == 'pcm.start').length, 1);
      expect(h.events, isNot(contains('pcm.stop')));
      expect(h.recorder.recording, isTrue);
      expect(h.service.isArmed, isTrue);
    }, preferStt: false);
  });

  testWidgets(
    'stop waits for a pending PCM start before stopping the recorder',
    (tester) async {
      await _withWake(tester, (h) async {
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
      }, preferStt: false);
    },
  );

  testWidgets('media acquired during PCM start closes the mic', (tester) async {
    await _withWake(tester, (h) async {
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
    }, preferStt: false);
  });

  for (final state in ['mediaPlaying', 'callActive']) {
    testWidgets('$state blocks PCM reconnect until clearing', (tester) async {
      await _withWake(tester, (h) async {
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
      }, preferStt: false);
    });
  }

  testWidgets('car connection routes PCM wake listening to the car microphone', (
    tester,
  ) async {
    await _withWake(
      tester,
      (h) async {
        h.audioState['carConnected'] = true;
        h.carInputDevice = const {'id': '99', 'label': 'KIA MOTORS'};
        final starting = h.service.start();
        await _pump(tester);
        await starting;

        expect(h.recorder.recording, isTrue);
        expect(h.recorder.lastConfig?.device?.id, '99');
        expect(h.recorder.lastConfig?.device?.label, 'KIA MOTORS');
        expect(
          h.recorder.lastConfig?.androidConfig.audioSource,
          AndroidAudioSource.voiceCommunication,
        );
        expect(h.events, contains('audio.carMic'));

        final stopping = h.service.stop();
        await _pump(tester);
        await stopping;
        expect(h.events, contains('audio.releaseWakeCar'));
      },
      preferStt: false,
      analyzer: (_) async => (text: '', wake: false),
    );
  });

  test('ordinary work talk does not wake the assistant', () {
    // Жалоба FIX 13.10.2026: «мордочка сама включается». Будило одиночное
    // «fix», а мастер произносит его весь день.
    final service = WakeWordService(
      recorder: _FakeRecorder(<String>[]),
      speech: stt.SpeechToText.withMethodChannel(),
      preferStt: true,
    );
    addTearDown(service.dispose);
    service.applyPhrases(
      word: 'FIX-Appliance',
      aliases: const [
        'fix appliance',
        'fix-appliance',
        'fixappliance',
        'фикс апплаенс',
        'фиксапплаенс',
      ],
    );
    for (final heard in [
      'fix',
      'I fixed the dryer',
      'we can fix it tomorrow',
      'фиксирую заявку',
      'фикс',
      'six appliance stores',
      'the fixture is broken',
      // Имя фирмы внутри разговора с клиентом — не обращение к ассистенту.
      'thank you for calling fix appliance',
      'hi this is Artem from fix appliance',
      'я из фикс апплаенс, мы договаривались на три',
      'я из фикс-аплаянс, буду к трём',
      'you can book fix appliance for tomorrow',
      'алло, фикс-аплаянс',
      'здравствуйте, фикс-аплаянс',
      'это фикс-аплаянс',
      'компания фикс-аплаянс',
      'из фикс-аплаянс',
      'да, фикс-аплаянс',
      'фикс-аплаянс, здравствуйте',
      'фикс-аплаянс, слушаю вас',
      'фикс-аплаянс, чем могу помочь',
      'фикс-аплаянс, добрый день',
      'фикс-аплаянс, это Артём',
      'Fix Appliance, how can I help you',
      'Fix Appliance, this is Artem',
      'Fix Appliance speaking',
      'Fix Appliance gives a ninety day warranty on every repair',
      'I fix appliances',
      'we fix appliances',
    ]) {
      expect(service.matchesWake(heard), isFalse, reason: heard);
    }
    for (final heard in [
      'Фикс-аплаянс',
      'фикс-аплаянс',
      'фикс аплаянс',
      'фиксаплаянс',
      'Эй, Фикс-аплаянс',
      'Слушай, Фикс-аплаянс',
      'Окей, Фикс-аплаянс',
      'Привет, Фикс-аплаянс',
      'Фикс-аплаянс, открой заявку',
      'fix appliance',
      'FX Appliance',
      'FX Alliance',
      'Эфикс, Аплайанс, покажи расписание',
      'FIX-Appliance, open the job',
      'hey fixappliance',
      'фикс апплаенс',
      'fiks appliance',
    ]) {
      expect(service.matchesWake(heard), isTrue, reason: heard);
    }
  });

  test('blind transcription prompt never hints the wake word to Gemini', () {
    // Промпт с именем «Фикс-аплаянс» заставлял Gemini додумывать его в белом
    // шуме и тишине (25 ложных пробуждений 19.10.2026 в assistant_wake_log,
    // включая «Эй, Фикс-аплаянс, запусти стирку»). Расшифровка должна быть
    // полностью слепой.
    final lower = WakeWordService.blindTranscribePrompt.toLowerCase();
    for (final forbidden in [
      'фикс',
      'аплаянс',
      'апплаенс',
      'fix',
      'appliance',
      'assistant',
      'technician',
    ]) {
      expect(lower, isNot(contains(forbidden)), reason: forbidden);
    }
  });

  testWidgets(
    'PCM capture ignores silence and short clicks, then wakes on full «Фикс-аплаянс»',
    (tester) async {
      final probedLengths = <int>[];
      await _withWake(
        tester,
        (h) async {
          var wakes = 0;
          h.service.onWake = () => wakes++;
          await h.service.start();
          expect(h.recorder.recording, isTrue);

          // 1 с тишины комнаты, короткий щелчок (120 мс) и тихий шорох
          // (peak ~0.018, как в logcat 19.10) — в Gemini не идём.
          _emitPcm(h, ms: 1000, sample: 40);
          _emitPcm(h, ms: 120, sample: 2500);
          _emitPcm(h, ms: 500, sample: 40);
          _emitPcm(h, ms: 900, sample: 600);
          _emitPcm(h, ms: 500, sample: 40);
          await _pump(tester);
          expect(probedLengths, isEmpty);
          expect(wakes, 0);

          // «Фикс» (400 мс) + пауза 200 мс + «аплаянс» (650 мс) + пауза 500 мс.
          _emitPcm(h, ms: 400, sample: 2800);
          _emitPcm(h, ms: 200, sample: 30);
          _emitPcm(h, ms: 650, sample: 2800);
          _emitPcm(h, ms: 500, sample: 30);
          await _pump(tester);
          await _pump(tester, const Duration(milliseconds: 280));

          expect(probedLengths, hasLength(1));
          // Полная фраза с пре-роллом, без обрезки начала до 1 секунды.
          expect(probedLengths.single, greaterThan(45000));
          expect(wakes, 1);
          expect(h.service.lastHeard, 'Фикс-аплаянс');
          expect(h.service.lastHeardSource, 'pcm');
        },
        preferStt: false,
        analyzer: (pcm) async {
          probedLengths.add(pcm.length);
          return (text: 'Фикс-аплаянс', wake: true);
        },
      );
    },
  );

  testWidgets(
    'an utterance finishing while a previous probe is in flight is queued, not dropped',
    (tester) async {
      final firstProbeGate = Completer<void>();
      var callCount = 0;
      await _withWake(
        tester,
        (h) async {
          var wakes = 0;
          h.service.onWake = () => wakes++;
          await h.service.start();

          // Первая фраза запускает пробу, которая ждёт сети.
          _emitPcm(h, ms: 700, sample: 2500);
          _emitPcm(h, ms: 500, sample: 30);
          await _pump(tester);
          expect(callCount, 1);

          // Пока первая проба в полёте, мастер произносит «Фикс-аплаянс».
          _emitPcm(h, ms: 900, sample: 2800);
          _emitPcm(h, ms: 500, sample: 30);
          await _pump(tester);
          expect(wakes, 0);

          firstProbeGate.complete();
          await _pump(tester);
          await _pump(tester, const Duration(milliseconds: 280));
          expect(callCount, 2);
          expect(wakes, 1);
        },
        preferStt: false,
        analyzer: (pcm) async {
          callCount++;
          if (callCount == 1) {
            await firstProbeGate.future;
            return (text: 'проверка насоса', wake: false);
          }
          return (text: 'Фикс-аплаянс', wake: true);
        },
      );
    },
  );

  testWidgets(
    'a long continuous sentence is not sliced into a new wake utterance mid-speech',
    (tester) async {
      var callCount = 0;
      await _withWake(
        tester,
        (h) async {
          var wakes = 0;
          h.service.onWake = () => wakes++;
          await h.service.start();

          // Непрерывный разговор 4 с без паузы — проверяется только начало,
          // середина предложения не режется на второе обращение.
          _emitPcm(h, ms: 4000, sample: 2600);
          _emitPcm(h, ms: 500, sample: 30);
          await _pump(tester);
          expect(callCount, 1);
          expect(wakes, 0);

          // После настоящей паузы (500 мс) отдельное обращение «Фикс-аплаянс»
          // снова ловится штатно.
          _emitPcm(h, ms: 900, sample: 2800);
          _emitPcm(h, ms: 500, sample: 30);
          await _pump(tester);
          await _pump(tester, const Duration(milliseconds: 280));
          expect(callCount, 2);
          expect(wakes, 1);
        },
        preferStt: false,
        analyzer: (pcm) async {
          callCount++;
          if (callCount == 1) {
            return (text: 'здравствуйте меня зовут Артём', wake: false);
          }
          return (text: 'Фикс-аплаянс', wake: true);
        },
      );
    },
  );

  testWidgets('a partial STT result with a work phrase stays silent', (
    tester,
  ) async {
    await _withWake(tester, (h) async {
      var wakes = 0;
      h.service.onWake = () => wakes++;
      await h.service.start();
      await h.result('I fixed the washer');
      await _pump(tester, const Duration(milliseconds: 400));
      expect(wakes, 0);
      expect(h.service.isRunning, isTrue);
    });
  });

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
  // Без ключа Gemini разбирать поток нечем, и служба честно уходит на STT.
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

void _emitPcm(_WakeHarness h, {required int ms, required int sample}) {
  const chunkSamples = 640; // 40 мс при 16 кГц
  final totalSamples = ms * 16;
  var sent = 0;
  while (sent < totalSamples) {
    final count = (totalSamples - sent).clamp(0, chunkSamples);
    final bytes = Uint8List(count * 2);
    final bd = ByteData.sublistView(bytes);
    for (var i = 0; i < count; i++) {
      bd.setInt16(i * 2, i.isEven ? sample : -sample, Endian.little);
    }
    h.recorder.stream.add(bytes);
    sent += count;
  }
}

/// [preferStt] — поднять службу сразу на запасном Android STT. Боевой путь
/// (`preferStt: false`) — непрерывный PCM, и он зависит от ключа Gemini,
/// которого в CI нет; поэтому старые проверки запасного пути просят STT явно.
Future<void> _withWake(
  WidgetTester tester,
  Future<void> Function(_WakeHarness) body, {
  bool preferStt = true,
  Future<({String text, bool wake})> Function(Uint8List pcm)? analyzer,
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  final h = _WakeHarness(preferStt: preferStt, analyzer: analyzer);
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
  Map<String, String>? carInputDevice;
  bool microphoneOpen = false;
  bool sttAvailable = true;

  _WakeHarness({
    bool preferStt = true,
    Future<({String text, bool wake})> Function(Uint8List pcm)? analyzer,
  }) {
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
      if (call.method == 'preferredAssistantInputDevice') {
        events.add('audio.carMic');
        return carInputDevice;
      }
      if (call.method == 'releaseWakeCarAudio') {
        events.add('audio.releaseWakeCar');
        return true;
      }
      if (call.method == 'hasCarAudio') return audioState['carConnected'];
      return true;
    });
    service = WakeWordService(
      recorder: recorder,
      speech: speech,
      preferStt: preferStt,
      analyzer: analyzer,
    )..onBlocked = blockedReasons.add;
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
  RecordConfig? lastConfig;
  bool recording = false;
  bool disposed = false;

  _FakeRecorder(this.events);

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    lastConfig = config;
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
