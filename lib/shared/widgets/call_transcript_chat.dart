import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../core/utils/formatters.dart';
import '../../services/message_translate_service.dart';
import 'linked_text.dart';

class _SpeakerLine {
  final bool isShop;
  final String speaker;
  final String text;

  const _SpeakerLine({
    required this.isShop,
    required this.speaker,
    required this.text,
  });
}

final _speakerLineRe = RegExp(
  r'^(ИИ|AI|Assistant|Secretary|Секретарь|Me|Master|Мастер|Моё|Мое|Technician|FixApplianceCA|Клиент|Client|User|Caller|Customer)\s*:\s*(.*)$',
  caseSensitive: false,
);

bool _isShopSpeaker(String label) {
  final t = label.toLowerCase();
  return t == 'ии' ||
      t == 'ai' ||
      t == 'assistant' ||
      t == 'secretary' ||
      t == 'секретарь' ||
      t == 'me' ||
      t == 'моё' ||
      t == 'мое' ||
      t == 'master' ||
      t == 'мастер' ||
      t == 'technician' ||
      t == 'fixapplianceca';
}

String _speakerTitle(
  String label,
  String answeredBy, {
  String clientLabel = '',
}) {
  if (_isShopSpeaker(label)) {
    if (answeredBy == 'master' ||
        label.toLowerCase() == 'me' ||
        label.toLowerCase() == 'моё' ||
        label.toLowerCase() == 'мое' ||
        label.toLowerCase() == 'master' ||
        label.toLowerCase() == 'мастер') {
      return 'Моё'.tr;
    }
    return 'ИИ'.tr;
  }
  if (clientLabel.trim().isNotEmpty) return clientLabel.trim();
  return 'Клиент'.tr;
}

List<_SpeakerLine> parseCallTranscript(String text) {
  final lines = <_SpeakerLine>[];
  bool? currentIsShop;
  var currentSpeaker = 'Клиент';
  final buffer = StringBuffer();

  void flush() {
    final value = buffer.toString().trim();
    final shop = currentIsShop;
    if (value.isEmpty || shop == null) {
      buffer.clear();
      return;
    }
    lines.add(
      _SpeakerLine(isShop: shop, speaker: currentSpeaker, text: value),
    );
    buffer.clear();
  }

  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final match = _speakerLineRe.firstMatch(line);
    if (match != null) {
      flush();
      final label = match.group(1) ?? '';
      currentIsShop = _isShopSpeaker(label);
      currentSpeaker = label;
      buffer.write(match.group(2) ?? '');
    } else if (currentIsShop != null) {
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(line);
    } else {
      lines.add(
        _SpeakerLine(isShop: false, speaker: 'Клиент', text: line),
      );
    }
  }
  flush();
  return lines;
}

int transcriptSpeakerTurns(String text) => parseCallTranscript(text).length;

String keepFullerTranscript(
  String current,
  String candidate, {
  bool preferRussian = true,
}) {
  final next = candidate.trim();
  if (next.isEmpty) return current;
  final now = current.trim();
  if (now.isEmpty) return next;
  final nextIsRu = MessageTranslateService.isRussianDialog(next);
  final nowIsRu = MessageTranslateService.isRussianDialog(now);
  final nextTurns = transcriptSpeakerTurns(next);
  final nowTurns = transcriptSpeakerTurns(now);
  if (nextTurns > 0 && nowTurns > 0) {
    if (nextTurns < (nowTurns * 0.9).floor() && nowTurns >= 2) {
      if (preferRussian &&
          nextIsRu &&
          !nowIsRu &&
          nextTurns >= (nowTurns * 0.7).floor()) {
        return next;
      }
      return current;
    }
    if (nowTurns < (nextTurns * 0.9).floor() && nextTurns >= 2) {
      if (preferRussian &&
          nowIsRu &&
          !nextIsRu &&
          nowTurns >= (nextTurns * 0.7).floor()) {
        return current;
      }
      return next;
    }
  }
  if (preferRussian) {
    if (nextIsRu && !nowIsRu) return next;
    if (!nextIsRu && nowIsRu) return current;
  } else {
    if (!nextIsRu && nowIsRu) return next;
    if (nextIsRu && !nowIsRu) return current;
  }
  return next.length >= now.length ? next : current;
}

/// Chat bubbles: shop/AI on the left (blue), client on the right (yellow).
class CallTranscriptChat extends StatelessWidget {
  final String text;
  final bool translating;
  final String answeredBy;
  final String clientLabel;

  /// Начало разговора. Отдельного времени у реплик нет — расшифровка
  /// приходит одним текстом, — поэтому день и время ставим на весь разговор.
  final DateTime? startedAt;

  const CallTranscriptChat({
    super.key,
    required this.text,
    this.translating = false,
    this.answeredBy = '',
    this.clientLabel = '',
    this.startedAt,
  });

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) {
      return Text(
        translating
            ? context.tr('Перевожу разговор...', 'Translating the call...')
            : context.tr('Расшифровки пока нет.', 'No transcript yet.'),
        style: TextStyle(
          fontSize: 14,
          height: 1.4,
          color: AppColors.inkMuted,
        ),
      );
    }

    final lines = parseCallTranscript(text);
    final stamp = Formatters.messageStamp(startedAt);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (stamp.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.cardMuted,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  stamp,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.inkMuted,
                  ),
                ),
              ),
            ),
          ),
        for (var i = 0; i < lines.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _Bubble(
            line: lines[i],
            answeredBy: answeredBy,
            clientLabel: clientLabel,
          ),
        ],
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  final _SpeakerLine line;
  final String answeredBy;
  final String clientLabel;

  const _Bubble({
    required this.line,
    required this.answeredBy,
    this.clientLabel = '',
  });

  @override
  Widget build(BuildContext context) {
    final shop = line.isShop;
    final color = shop
        ? (AppColors.isDark
            ? const Color(0xFF153E5C)
            : const Color(0xFFD4ECFF))
        : (AppColors.isDark
            ? const Color(0xFF3E3210)
            : const Color(0xFFFFF3C4));
    final borderColor = shop
        ? const Color(0xFF64B5F6).withValues(alpha: 0.55)
        : const Color(0xFFFFD54F).withValues(alpha: 0.65);
    return Align(
      alignment: shop ? Alignment.centerLeft : Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          decoration: BoxDecoration(
            color: color,
            border: Border.all(color: borderColor, width: 1.0),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(shop ? 4 : 16),
              bottomRight: Radius.circular(shop ? 16 : 4),
            ),
          ),
          child: Column(
            crossAxisAlignment:
                shop ? CrossAxisAlignment.start : CrossAxisAlignment.end,
            children: [
              Text(
                _speakerTitle(
                  line.speaker,
                  answeredBy,
                  clientLabel: clientLabel,
                ),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: AppColors.inkMuted,
                ),
              ),
              const SizedBox(height: 2),
              // Двойное касание выделяет слово, адреса и телефоны из
              // разговора нажимаются.
              LinkedText(
                line.text,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  color: AppColors.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
