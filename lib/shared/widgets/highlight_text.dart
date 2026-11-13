import 'package:flutter/material.dart';

import '../../core/utils/bilingual_search.dart';

/// Подсвечивает совпадения поискового запроса жёлтым.
class HighlightText extends StatelessWidget {
  final String text;
  final String query;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  static const Color highlightColor = Color(0xFFFFF59D);

  const HighlightText(
    this.text, {
    super.key,
    this.query = '',
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    final q = query.trim();
    if (q.isEmpty || text.isEmpty) {
      return Text(
        text,
        style: style,
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
      );
    }

    final lower = text.toLowerCase();
    final needle = q.toLowerCase();
    final spans = <InlineSpan>[];
    var start = 0;
    while (true) {
      final index = lower.indexOf(needle, start);
      if (index < 0) {
        if (start < text.length) {
          spans.add(TextSpan(text: text.substring(start)));
        }
        break;
      }
      if (index > start) {
        spans.add(TextSpan(text: text.substring(start, index)));
      }
      spans.add(
        TextSpan(
          text: text.substring(index, index + needle.length),
          style: const TextStyle(
            backgroundColor: highlightColor,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
      start = index + needle.length;
    }

    if (spans.length == 1 && spans.first is TextSpan) {
      final only = spans.first as TextSpan;
      if (only.style == null) {
        final cross = BilingualSearch.crossScriptMatchRanges(text, q);
        if (cross.isNotEmpty) {
          final crossSpans = <InlineSpan>[];
          var pos = 0;
          for (final r in cross) {
            if (r.start > pos) {
              crossSpans.add(TextSpan(text: text.substring(pos, r.start)));
            }
            crossSpans.add(
              TextSpan(
                text: text.substring(r.start, r.end),
                style: const TextStyle(
                  backgroundColor: highlightColor,
                  fontWeight: FontWeight.w800,
                ),
              ),
            );
            pos = r.end;
          }
          if (pos < text.length) {
            crossSpans.add(TextSpan(text: text.substring(pos)));
          }
          return Text.rich(
            TextSpan(style: style, children: crossSpans),
            maxLines: maxLines,
            overflow: overflow ?? TextOverflow.clip,
            textAlign: textAlign,
          );
        }
        return Text(
          text,
          style: style,
          maxLines: maxLines,
          overflow: overflow,
          textAlign: textAlign,
        );
      }
    }

    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: maxLines,
      overflow: overflow ?? TextOverflow.clip,
      textAlign: textAlign,
    );
  }
}
