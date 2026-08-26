import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';

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

String _speakerTitle(String label, String answeredBy) {
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

/// Chat bubbles: shop/AI on the left (blue), client on the right (yellow).
class CallTranscriptChat extends StatelessWidget {
  final String text;
  final bool translating;
  final String answeredBy;

  const CallTranscriptChat({
    super.key,
    required this.text,
    this.translating = false,
    this.answeredBy = '',
  });

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) {
      return Text(
        translating
            ? context.tr('Перевожу разговор...', 'Translating the call...')
            : context.tr('Расшифровки пока нет.', 'No transcript yet.'),
        style: const TextStyle(
          fontSize: 14,
          height: 1.4,
          color: Color(0xFF3D3D3D),
        ),
      );
    }

    final lines = parseCallTranscript(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < lines.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _Bubble(
            line: lines[i],
            answeredBy: answeredBy,
          ),
        ],
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  final _SpeakerLine line;
  final String answeredBy;

  const _Bubble({required this.line, required this.answeredBy});

  @override
  Widget build(BuildContext context) {
    final shop = line.isShop;
    final color = shop ? AppColors.primary : AppColors.accent;
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
                _speakerTitle(line.speaker, answeredBy),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
              const SizedBox(height: 2),
              SelectableText(
                line.text,
                style: const TextStyle(
                  fontSize: 15,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
