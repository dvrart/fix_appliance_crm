import 'dart:async';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../../core/constants.dart';
import '../../services/ai_service.dart';
import 'job_preview_screen.dart';
import '../../core/l10n/app_locale.dart';

/// Экран для диктовки информации о звонке.
///
/// Поток максимально бесшовный: при открытии экрана микрофон сразу
/// начинает слушать, а как только человек замолкает — распознанный текст
/// автоматически отправляется в ИИ и открывается экран предпросмотра.
/// Никаких промежуточных нажатий «Диктовать» → «ИИ» не требуется.
class PostCallScreen extends StatefulWidget {
  const PostCallScreen({super.key});

  @override
  State<PostCallScreen> createState() => _PostCallScreenState();
}

class _PostCallScreenState extends State<PostCallScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _textController = TextEditingController();
  final stt.SpeechToText _speech = stt.SpeechToText();

  bool _isListening = false;
  bool _speechAvailable = false;
  bool _isProcessing = false;
  bool _autoStarted = false;
  // true, если текущая сессия прослушивания уже обработана (не даёт
  // сработать обработке два раза, если и ручной стоп, и onStatus от
  // платформы "выстрелят" почти одновременно — а также гарантирует,
  // что кнопка "Остановить" отработает мгновенно, даже если сам плагин
  // не пришлёт onStatus вовремя или вообще).
  bool _sessionHandled = true;
  String _statusText = 'Подготовка микрофона...'.tr;

  // Собственный таймер тишины: считаем, что человек закончил говорить,
  // только если он уже сказал хоть слово и после этого замолчал на
  // некоторое время. Это отличается от pauseFor плагина, который начинает
  // отсчёт с самого начала прослушивания — из-за чего сессия могла
  // прерваться до того, как человек успевал открыть рот.
  Timer? _silenceTimer;

  // Последний промежуточный (ещё не финальный) распознанный текст.
  // На случай, если сессия завершится раньше, чем плагин успеет прислать
  // финальный результат — используем этот текст как запасной вариант,
  // чтобы не терять последнюю фразу.
  String _pendingPartialText = '';

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _pulseController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _pulseController.reverse();
      } else if (status == AnimationStatus.dismissed && _isListening) {
        _pulseController.forward();
      }
    });

    _initSpeech();
  }

  Future<void> _initSpeech() async {
    _speechAvailable = await _speech.initialize(
      onStatus: _onSpeechStatus,
      onError: (error) {
        if (!mounted) return;
        setState(() {
          _isListening = false;
          _statusText = '${'Ошибка распознавания'.tr}: ${error.errorMsg}';
          _pulseController.stop();
        });
      },
    );

    if (!mounted) return;
    setState(() {
      _statusText = _speechAvailable
          ? 'Говорите — я слушаю и сам всё пойму'.tr
          : 'Распознавание речи недоступно. Введите текст вручную.'.tr;
    });

    // Автостарт: как только микрофон готов, сразу начинаем слушать —
    // пользователю достаточно было один раз нажать на иконку микрофона сверху.
    if (_speechAvailable && !_autoStarted) {
      _autoStarted = true;
      await Future.delayed(const Duration(milliseconds: 300));
      if (mounted) _startListening();
    }
  }

  void _onSpeechStatus(String status) {
    if (status != 'done' && status != 'notListening') return;
    // Плагин сообщил, что слушание завершилось само — это может произойти
    // до того, как человек успел сказать хоть слово (системный тайм-аут
    // Android на некоторых устройствах). В этом случае стоит попробовать
    // послушать ещё раз автоматически.
    _finishListeningSession(retryIfEmpty: true);
  }

  Future<void> _startListening() async {
    if (!_speechAvailable || _isListening || _isProcessing) return;

    _sessionHandled = false;
    _silenceTimer?.cancel();
    _pendingPartialText = '';
    setState(() {
      _isListening = true;
      _statusText = 'Слушаю... Говорите о клиенте и проблеме'.tr;
      _pulseController.forward();
    });

    try {
      await _speech.listen(
        onResult: (result) {
          final words = result.recognizedWords.trim();
          if (words.isNotEmpty) {
            // Человек говорит — откладываем момент завершения.
            _restartSilenceTimer();
          }
          if (result.finalResult) {
            _pendingPartialText = '';
            if (words.isNotEmpty) {
              setState(() {
                if (_textController.text.isNotEmpty) {
                  _textController.text += ' ';
                }
                _textController.text += words;
              });
            }
          } else {
            // Запоминаем последний промежуточный вариант — вдруг сессия
            // прервётся раньше, чем придёт финальный результат.
            _pendingPartialText = words;
          }
        },
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.dictation,
          partialResults: true,
          localeId: 'ru_RU',
          // Это лишь запасной предохранитель на случай, если наш собственный
          // таймер тишины не сработает — сами мы останавливаем раньше.
          pauseFor: const Duration(seconds: 20),
          listenFor: const Duration(minutes: 3),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText = '${'Не удалось начать слушать'.tr}: $e';
      });
      _finishListeningSession(autoProcess: false);
    }
  }

  /// Перезапускает таймер тишины: если после последнего распознанного
  /// слова пройдёт [_silenceDuration] без новых слов — считаем, что
  /// человек закончил, и останавливаем прослушивание.
  static const Duration _silenceDuration = Duration(seconds: 3);

  void _restartSilenceTimer() {
    _silenceTimer?.cancel();
    _silenceTimer = Timer(_silenceDuration, () {
      if (_isListening && !_isProcessing) {
        // Сюда попадаем только после того, как человек уже что-то сказал,
        // так что повторный автозапуск на пустом тексте здесь не нужен.
        _stopListening(retryIfEmpty: false);
      }
    });
  }

  /// Останавливает слушание по нажатию кнопки. Кнопка при этом сразу
  /// переходит в состояние "останавливаю" — не может "зависнуть", даже
  /// если плагин отвечает с задержкой или не отвечает вовсе: на этот
  /// случай стоит короткий таймаут.
  ///
  /// [retryIfEmpty] — если true и ничего не было распознано, слушание
  /// само перезапустится (используется для автоматических остановок, а
  /// не для явного нажатия кнопки пользователем).
  Future<void> _stopListening({bool retryIfEmpty = false}) async {
    if (!_isListening || _sessionHandled) return;
    setState(() => _statusText = 'Останавливаю...'.tr);
    try {
      await _speech.stop().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Не страшно — ниже мы всё равно завершим сессию сами.
    }
    // Даём плагину короткий шанс досказать последний финальный кусок
    // текста (иногда он приходит через мгновение после stop()).
    await Future.delayed(const Duration(milliseconds: 300));
    _finishListeningSession(retryIfEmpty: retryIfEmpty);
  }

  void _finishListeningSession({
    bool autoProcess = true,
    bool retryIfEmpty = false,
  }) {
    if (_sessionHandled) return;
    _sessionHandled = true;
    _silenceTimer?.cancel();

    // Если финальный результат так и не пришёл, но был промежуточный
    // текст — используем его, чтобы не терять последнюю фразу целиком.
    if (_pendingPartialText.trim().isNotEmpty) {
      if (_textController.text.isNotEmpty) {
        _textController.text += ' ';
      }
      _textController.text += _pendingPartialText.trim();
      _pendingPartialText = '';
    }

    if (!mounted) return;
    setState(() {
      _isListening = false;
      _pulseController.stop();
    });

    if (!autoProcess || _isProcessing) return;

    final text = _textController.text.trim();
    if (text.isNotEmpty) {
      _processWithAI();
      return;
    }

    if (retryIfEmpty) {
      // Скорее всего, не успели начать говорить (иногда система
      // останавливает слушание раньше, чем человек открыл рот) —
      // пробуем послушать ещё раз без нажатия кнопки.
      setState(() {
        _statusText = 'Не услышал речь, слушаю ещё раз...'.tr;
      });
      Future.delayed(const Duration(milliseconds: 400), () {
        if (mounted && !_isListening && !_isProcessing) {
          _startListening();
        }
      });
    } else {
      setState(() {
        _statusText = 'Не услышал речь. Нажмите на микрофон, чтобы попробовать снова.'.tr;
      });
    }
  }

  Future<void> _processWithAI() async {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Введите или надиктуйте информацию о звонке'.tr),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() {
      _isProcessing = true;
      _statusText = 'ИИ анализирует текст...'.tr;
    });

    try {
      final extractedData = await AiService.extractJobData(text);

      if (!mounted) return;

      if (extractedData.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Не удалось извлечь данные. Попробуйте добавить больше деталей.'.tr),
            backgroundColor: Colors.orange,
          ),
        );
        setState(() {
          _isProcessing = false;
          _statusText = 'Нажмите на микрофон и добавьте больше деталей'.tr;
        });
        return;
      }

      // Переходим на экран предпросмотра
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => JobPreviewScreen(
            extractedData: extractedData,
            originalText: text,
          ),
        ),
      );

      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _statusText = 'Готово! Можете надиктовать следующий звонок.'.tr;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${'Ошибка'.tr}: $e'),
          backgroundColor: Colors.red,
        ),
      );
      setState(() {
        _isProcessing = false;
        _statusText = 'Ошибка обработки. Нажмите на микрофон, чтобы попробовать снова.'.tr;
      });
    }
  }

  @override
  void dispose() {
    _silenceTimer?.cancel();
    _textController.dispose();
    _pulseController.dispose();
    _speech.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasText = _textController.text.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Новая заявка из звонка'.tr,
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // Инструкция
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: AppColors.accent.withOpacity(0.1),
            child: Column(
              children: [
                Icon(
                  Icons.tips_and_updates,
                  color: AppColors.primary,
                  size: 32,
                ),
                const SizedBox(height: 8),
                Text(
                  'Просто расскажите о звонке'.tr,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                  'Имя, телефон, адрес, техника, проблема, время визита.\nКак только замолчите — ИИ сам заполнит заявку'.tr,
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontSize: 14,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),

          // Текстовое поле
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _textController,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText:
                      'Пример: Звонил Иван Петров, телефон 416-555-1234, живёт на 123 Main Street, Торонто. У него сломалась стиральная машина Samsung, не сливает воду. Договорились на завтра в 10 утра.'.tr,
                  hintStyle: TextStyle(color: Colors.grey.shade400),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide(color: AppColors.primary, width: 2),
                  ),
                  filled: true,
                  fillColor: Colors.white,
                ),
              ),
            ),
          ),

          // Статус
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              _statusText,
              style: TextStyle(
                color: _isListening ? Colors.green : Colors.grey.shade600,
                fontWeight: _isListening ? FontWeight.bold : FontWeight.normal,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 16),

          // Кнопки
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // Кнопка очистки
                IconButton(
                  onPressed: _isProcessing
                      ? null
                      : () {
                          _textController.clear();
                          setState(() {
                            _statusText = _speechAvailable
                                ? 'Нажмите на микрофон и расскажите о звонке'.tr
                                : 'Распознавание речи недоступно. Введите текст вручную.'.tr;
                          });
                        },
                  icon: const Icon(Icons.clear),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.grey.shade200,
                    foregroundColor: Colors.grey.shade700,
                  ),
                ),
                const SizedBox(width: 12),

                // Главная кнопка: слушать / стоп (сама запускает ИИ по завершении)
                Expanded(
                  child: AnimatedBuilder(
                    animation: _pulseAnimation,
                    builder: (context, child) {
                      return Transform.scale(
                        scale: _isListening ? _pulseAnimation.value : 1.0,
                        child: ElevatedButton.icon(
                          onPressed: _isProcessing
                              ? null
                              : (_isListening ? _stopListening : _startListening),
                          icon: _isProcessing
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : Icon(
                                  _isListening ? Icons.stop : Icons.mic,
                                  size: 28,
                                ),
                          label: Text(
                            _isProcessing
                                ? 'Анализирую...'.tr
                                : (_isListening ? 'Остановить'.tr : 'Слушать'.tr),
                            style: const TextStyle(fontSize: 16),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _isProcessing
                                ? AppColors.primary.withOpacity(0.6)
                                : (_isListening ? Colors.red : AppColors.primary),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),

                // Кнопка ручной обработки — на случай, если текст введён с клавиатуры,
                // а не через диктовку.
                if (hasText && !_isListening) ...[
                  const SizedBox(width: 12),
                  IconButton(
                    onPressed: _isProcessing ? null : _processWithAI,
                    icon: const Icon(Icons.auto_awesome),
                    tooltip: 'Обработать введённый текст'.tr,
                    style: IconButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.all(14),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
