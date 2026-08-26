/// Каждое предложение исходящего SMS — с новой строки.
/// URL, email, суммы и сокращения не режутся по точке.
class SmsText {
  static final _placeholder = RegExp('\uE000(\\d+)\uE001');
  static final _protect = <RegExp>[
    RegExp(r'https?://[^\s]+', caseSensitive: false),
    RegExp(r'\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b'),
    RegExp(r'\b(?:e\.g|i\.e)', caseSensitive: false),
    RegExp(r'\b[ap]\.m', caseSensitive: false),
    RegExp(r'\b(?:Mr|Mrs|Ms|Dr|Prof|Sr|Jr|St|Apt|Inc|Ltd|Co|vs|etc|No)\.',
        caseSensitive: false),
    RegExp(r'\b\d{3}\.\d{3}\.\d{4}\b'),
    RegExp(r'(?<![A-Za-z])\d+[.,]\d+'),
    RegExp(r'\b(?:www\.)?[\w-]+(?:\.[\w-]+)+(?:/[^\s]*)?', caseSensitive: false),
  ];

  static String formatSentences(String text) {
    final raw = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (raw.trim().isEmpty) return '';
    final out = <String>[];
    for (final line in raw.split('\n')) {
      if (line.trim().isEmpty) {
        if (out.isNotEmpty && out.last.isNotEmpty) out.add('');
        continue;
      }
      out.addAll(_splitSentences(line.trim()));
    }
    while (out.isNotEmpty && out.last.isEmpty) {
      out.removeLast();
    }
    return out.join('\n');
  }

  static List<String> _splitSentences(String line) {
    final tokens = <String>[];
    var protected = line;
    for (final pattern in _protect) {
      protected = protected.replaceAllMapped(pattern, (match) {
        var value = match[0]!;
        var extra = '';
        if (value.toLowerCase().startsWith('http://') ||
            value.toLowerCase().startsWith('https://')) {
          while (value.isNotEmpty && '.,!?;:'.contains(value[value.length - 1])) {
            extra = value[value.length - 1] + extra;
            value = value.substring(0, value.length - 1);
          }
        }
        final key = '\uE000${tokens.length}\uE001';
        tokens.add(value);
        return '$key$extra';
      });
    }
    final parts = <String>[];
    final buf = StringBuffer();
    const ends = '.!?…';
    for (var i = 0; i < protected.length; i++) {
      buf.write(protected[i]);
      if (!ends.contains(protected[i])) continue;
      while (i + 1 < protected.length && ends.contains(protected[i + 1])) {
        i += 1;
        buf.write(protected[i]);
      }
      final next = i + 1 < protected.length ? protected[i + 1] : null;
      if (next != null && !_isSpace(next)) continue;
      parts.add(_restore(buf.toString().trim(), tokens));
      buf.clear();
      while (i + 1 < protected.length && _isSpace(protected[i + 1])) {
        i += 1;
      }
    }
    final tail = buf.toString().trim();
    if (tail.isNotEmpty) parts.add(_restore(tail, tokens));
    return parts.where((part) => part.isNotEmpty).toList();
  }

  static bool _isSpace(String ch) => ch.trim().isEmpty;

  static String _restore(String text, List<String> tokens) {
    return text.replaceAllMapped(_placeholder, (match) {
      final idx = int.tryParse(match[1] ?? '') ?? -1;
      if (idx < 0 || idx >= tokens.length) return '';
      return tokens[idx];
    });
  }
}
