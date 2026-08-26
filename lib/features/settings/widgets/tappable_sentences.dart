import 'package:flutter/material.dart';

import '../../../core/constants.dart';

List<String> splitTappableSentences(String text) {
  final out = <String>[];
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.length <= 180) {
      out.add(line);
      continue;
    }
    for (final part in line.split(RegExp(r'(?<=[.!?…])\s+'))) {
      final sentence = part.trim();
      if (sentence.isNotEmpty) out.add(sentence);
    }
  }
  return out;
}

class TappableSentences extends StatelessWidget {
  final String text;
  final String selected;
  final ValueChanged<String> onSelect;

  const TappableSentences({
    super.key,
    required this.text,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final sentences = splitTappableSentences(text);
    if (sentences.isEmpty) {
      return Text(text, style: const TextStyle(height: 1.35));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final sentence in sentences)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Material(
              color: sentence == selected
                  ? AppColors.accent
                  : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => onSelect(sentence),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Text(
                    sentence,
                    style: TextStyle(
                      height: 1.35,
                      fontWeight:
                          sentence == selected ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
