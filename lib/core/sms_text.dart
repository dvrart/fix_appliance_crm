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

  static final _cyrillic = RegExp('[А-Яа-яЁё]');
  static const _ruLatin = {
    'а': 'a', 'б': 'b', 'в': 'v', 'г': 'g', 'д': 'd', 'е': 'e', 'ё': 'e',
    'ж': 'zh', 'з': 'z', 'и': 'i', 'й': 'y', 'к': 'k', 'л': 'l', 'м': 'm',
    'н': 'n', 'о': 'o', 'п': 'p', 'р': 'r', 'с': 's', 'т': 't', 'у': 'u',
    'ф': 'f', 'х': 'kh', 'ц': 'ts', 'ч': 'ch', 'ш': 'sh', 'щ': 'sch',
    'ъ': '', 'ы': 'y', 'ь': '', 'э': 'e', 'ю': 'yu', 'я': 'ya',
  };

  /// Кириллица → латиница с сохранением регистра: «Артём» → «Artem».
  static String toLatin(String text) {
    return text.replaceAllMapped(_cyrillic, (match) {
      final ch = match[0]!;
      final latin = _ruLatin[ch.toLowerCase()];
      if (latin == null) return ch;
      if (latin.isEmpty || ch == ch.toLowerCase()) return latin;
      return latin[0].toUpperCase() + latin.substring(1);
    });
  }

  /// Служебная подпись вместо имени: карточка клиента до того, как он назвал
  /// имя, называется «Клиент +14165550101», а контакт на заявке — «Неизвестно».
  /// В SMS такое уходить не должно.
  static bool isPlaceholderName(String? name) {
    final s = (name ?? '').trim();
    if (s.isEmpty) return true;
    if (RegExp(r'^(клиент|client)(\s|$|\+)', caseSensitive: false).hasMatch(s)) {
      return true;
    }
    if (RegExp(r'^(без имени|неизвестно|unknown|no name)$', caseSensitive: false)
        .hasMatch(s)) {
      return true;
    }
    if (RegExp(r'^\+?\d[\d\s\-().]{6,}$').hasMatch(s)) return true;
    return false;
  }

  /// Обращение в SMS: имя клиента латиницей или «», если имени нет.
  static String clientName(String? raw) {
    if (isPlaceholderName(raw)) return '';
    final first = toLatin(raw!.trim()).split(RegExp(r'\s+')).first;
    if (!RegExp(r"^[A-Za-z][A-Za-z'\-]{1,15}$").hasMatch(first)) return '';
    return first[0].toUpperCase() + first.substring(1).toLowerCase();
  }

  /// Подстановка `{name}`. Имени нет — убираем и обращение, и запятую перед
  /// ним: должно получиться «Hi!», а не «Hi !» и не «Hi Клиент +14165550101!».
  static String fillName(String template, String? rawName) {
    final name = clientName(rawName);
    if (name.isNotEmpty) return template.replaceAll('{name}', name);
    return template
        .replaceAll(RegExp(r'[ \t]*,?[ \t]*\{name\}'), '')
        .replaceAll('{name}', '')
        .replaceAll(RegExp(r'^[ \t]*,[ \t]*', multiLine: true), '');
  }

  static String _restore(String text, List<String> tokens) {
    return text.replaceAllMapped(_placeholder, (match) {
      final idx = int.tryParse(match[1] ?? '') ?? -1;
      if (idx < 0 || idx >= tokens.length) return '';
      return tokens[idx];
    });
  }
}
