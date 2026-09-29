import 'package:fix_appliance_crm/services/error_log_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Прежний отчёт о вылете писал «на экране Склад» всегда, потому что метка
/// ставилась только на двух экранах и никогда не сбрасывалась. Месяц вылетов
/// из-за этого указывал не туда. Здесь закреплено, что отчёт честный.
void main() {
  final now = DateTime(2026, 9, 21, 12, 30);

  AppVitals vitals({
    required Duration ago,
    required int rssMb,
    int baselineMb = 176,
    int imgMb = 20,
    int imgCount = 12,
  }) {
    return AppVitals(
      at: now.subtract(ago),
      screen: 'Склад',
      rssBytes: rssMb * 1024 * 1024,
      baselineRssBytes: baselineMb * 1024 * 1024,
      imageCacheBytes: imgMb * 1024 * 1024,
      imageCount: imgCount,
    );
  }

  group('свежесть метки экрана', () {
    test('свежая метка называет экран прямо', () {
      final text = ErrorLogService.describeCrash(
        screen: 'Склад',
        screenAt: now.subtract(const Duration(seconds: 40)),
        last: vitals(ago: const Duration(seconds: 20), rssMb: 320),
        now: now,
      );

      expect(text, contains('на экране «Склад»'));
      expect(text, isNot(contains('верить')));
    });

    test('устаревшая метка честно помечена и её возраст указан', () {
      final text = ErrorLogService.describeCrash(
        screen: 'Склад',
        screenAt: now.subtract(const Duration(hours: 5)),
        last: vitals(ago: const Duration(seconds: 25), rssMb: 320),
        now: now,
      );

      expect(text, contains('верить ей нельзя'));
      expect(text, contains('5 ч'));
    });

    test('метки нет — так и сказано, экран не выдумывается', () {
      final text = ErrorLogService.describeCrash(
        screen: '',
        screenAt: null,
        last: vitals(ago: const Duration(seconds: 10), rssMb: 300),
        now: now,
      );

      expect(text, contains('экран неизвестен'));
      expect(text, isNot(contains('Склад')));
    });

    test('имя экрана без времени тоже не выдаётся за правду', () {
      final text = ErrorLogService.describeCrash(
        screen: 'Склад',
        screenAt: null,
        last: null,
        now: now,
      );
      expect(text, contains('экран неизвестен'));
    });
  });

  group('память в отчёте', () {
    test('рост памяти за сеанс помечается как нехватка памяти', () {
      final text = ErrorLogService.describeCrash(
        screen: 'Переписка',
        screenAt: now.subtract(const Duration(seconds: 30)),
        last: vitals(
          ago: const Duration(seconds: 15),
          rssMb: 420,
          baselineMb: 176,
          imgMb: 60,
        ),
        now: now,
      );

      expect(text, contains('память 420 МБ'));
      expect(text, contains('в начале сеанса 176 МБ'));
      expect(text, contains('+244 МБ'));
      expect(text, contains('картинки в кэше 60 МБ'));
      expect(text, contains('похоже на нехватку памяти'));
    });

    test('высокая, но не выросшая память не объявляется OOM', () {
      // Живой замер: ProcessInfo отдаёт ~176 МБ там, где dumpsys показывает
      // 460 МБ по тому же процессу. Любой фиксированный порог на этом врал бы.
      final text = ErrorLogService.describeCrash(
        screen: 'Заявки',
        screenAt: now.subtract(const Duration(seconds: 30)),
        last: vitals(
          ago: const Duration(seconds: 15),
          rssMb: 190,
          baselineMb: 176,
        ),
        now: now,
      );

      expect(text, contains('память 190 МБ'));
      expect(text, isNot(contains('нехватку памяти')));
    });

    test('признак считается по росту, а не по абсолютному числу', () {
      expect(
        vitals(
          ago: Duration.zero,
          rssMb: 176 + AppVitals.suspiciousGrowthMb,
          baselineMb: 176,
        ).looksLikeOutOfMemory,
        isTrue,
      );
      expect(
        vitals(
          ago: Duration.zero,
          rssMb: 176 + AppVitals.suspiciousGrowthMb - 1,
          baselineMb: 176,
        ).looksLikeOutOfMemory,
        isFalse,
      );
      // Без точки отсчёта по росту вывода не делаем.
      expect(
        vitals(ago: Duration.zero, rssMb: 900, baselineMb: 0, imgMb: 10)
            .looksLikeOutOfMemory,
        isFalse,
      );
    });

    test('забитый кэш картинок — второй признак, битмапы вне Dart-RSS', () {
      expect(
        vitals(
          ago: Duration.zero,
          rssMb: 180,
          baselineMb: 176,
          imgMb: AppVitals.saturatedImageCacheMb,
        ).looksLikeOutOfMemory,
        isTrue,
      );
      expect(
        vitals(
          ago: Duration.zero,
          rssMb: 180,
          baselineMb: 176,
          imgMb: AppVitals.saturatedImageCacheMb - 1,
        ).looksLikeOutOfMemory,
        isFalse,
      );
    });

    test('без замера отчёт это признаёт', () {
      final text = ErrorLogService.describeCrash(
        screen: 'Склад',
        screenAt: now.subtract(const Duration(seconds: 10)),
        last: null,
        now: now,
      );
      expect(text, contains('замера памяти нет'));
    });
  });

  group('замер переживает перезапуск', () {
    test('запись и чтение сохраняют всё', () {
      final source = vitals(
        ago: const Duration(seconds: 30),
        rssMb: 512,
        imgMb: 64,
        imgCount: 33,
      );

      final restored = AppVitals.tryParse(
        // ровно то, что кладётся в SharedPreferences
        '{"at":"${source.at.toIso8601String()}","screen":"Склад",'
        '"rss":${source.rssBytes},"base":${source.baselineRssBytes},'
        '"img":${source.imageCacheBytes},"imgCount":33}',
      );

      expect(restored, isNotNull);
      expect(restored!.rssMb, 512);
      expect(restored.baselineRssMb, 176);
      expect(restored.rssGrowthMb, 336);
      expect(restored.imageCacheMb, 64);
      expect(restored.imageCount, 33);
      expect(restored.at, source.at);
    });

    test('мусор и пустота не роняют старт приложения', () {
      expect(AppVitals.tryParse(null), isNull);
      expect(AppVitals.tryParse(''), isNull);
      expect(AppVitals.tryParse('не json'), isNull);
      expect(AppVitals.tryParse('{"rss":1}'), isNull);
    });
  });
}
