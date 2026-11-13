/// Двуязычный поиск (латиница ↔ кириллица): запрос в любой раскладке
/// находит совпадения как по кириллице, так и по латинице (например,
/// «артем» ↔ «Artem» / «Артём», «джон» ↔ «John», «брад» ↔ «Brad»).
class BilingualSearch {
  BilingualSearch._();

  static final RegExp _wordSeparator = RegExp(r'[^a-z0-9а-яё]+');
  static final RegExp _wordCapture = RegExp(r'[a-z0-9а-яё]+', caseSensitive: false);
  static final RegExp _cyrillic = RegExp(r'[а-яё]');
  static final RegExp _latin = RegExp(r'[a-z]');

  static const Map<String, String> _cyrMap = {
    'а': 'a',
    'б': 'b',
    'в': 'v',
    'г': 'g',
    'д': 'd',
    'е': 'e',
    'ё': 'e',
    'ж': 'zh',
    'з': 'z',
    'и': 'i',
    'й': 'i',
    'к': 'k',
    'л': 'l',
    'м': 'm',
    'н': 'n',
    'о': 'o',
    'п': 'p',
    'р': 'r',
    'с': 's',
    'т': 't',
    'у': 'u',
    'ф': 'f',
    'х': 'h',
    'ц': 'ts',
    'ч': 'ch',
    'ш': 'sh',
    'щ': 'sh',
    'ъ': '',
    'ы': 'i',
    'ь': '',
    'э': 'e',
    'ю': 'iu',
    'я': 'ia',
  };

  static bool hasCyrillic(String s) => _cyrillic.hasMatch(s.toLowerCase());
  static bool hasLatin(String s) => _latin.hasMatch(s.toLowerCase());

  static String fold(String value) => value.toLowerCase().trim();

  static String compact(String value) =>
      value.toLowerCase().replaceAll(_wordSeparator, '');

  /// Переводит кириллицу и английскую орфографию в единый фонетический
  /// латинский вид для сравнения в обе стороны.
  static String toPhonetic(String input) {
    var s = input.toLowerCase().trim();
    if (s.isEmpty) return '';

    if (hasCyrillic(s)) {
      s = s
          .replaceAll('дж', 'j')
          .replaceAll('тс', 'ts')
          .replaceAll('кс', 'ks');
      final buf = StringBuffer();
      for (var i = 0; i < s.length; i++) {
        final ch = s[i];
        buf.write(_cyrMap[ch] ?? ch);
      }
      s = buf.toString();
    }

    s = s
        .replaceAll('sch', 'sh')
        .replaceAll('tch', 'ch')
        .replaceAll('ph', 'f')
        .replaceAll('th', 't')
        .replaceAll('kh', 'h')
        .replaceAll('ck', 'k')
        .replaceAll('qu', 'kv')
        .replaceAll('gh', '')
        .replaceAll('x', 'ks')
        .replaceAll('w', 'v')
        .replaceAll('y', 'i')
        .replaceAll(RegExp(r'c(?=[ei])'), 's')
        .replaceAll('c', 'k')
        .replaceAll('q', 'k')
        .replaceAll(RegExp(r'oe\b'), 'o')
        .replaceAll(RegExp(r'(?<=[aeiou])h(?![aeiou])'), '')
        .replaceAll(RegExp(r'([a-z])\1+'), r'$1');
    return s;
  }

  /// Консонантный скелет одного слова (первая буква сохраняется даже если
  /// гласная, далее отбрасываются гласные): «брэнтфорд» = «brantford» -> `brntfrd`.
  static String skeleton(String word) {
    final p = toPhonetic(word).replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (p.length <= 2) return p;
    final buf = StringBuffer()..write(p[0]);
    for (var i = 1; i < p.length; i++) {
      final ch = p[i];
      if (ch != 'a' && ch != 'e' && ch != 'i' && ch != 'o' && ch != 'u') {
        buf.write(ch);
      }
    }
    return buf.toString();
  }

  /// Совпадает ли одно слово/фраза [rawQuery] с текстом [haystack].
  static bool matchesWord(String haystack, String rawQuery) {
    final q = fold(rawQuery);
    if (q.isEmpty) return true;
    final v = fold(haystack);
    if (v.isEmpty) return false;

    if (v.contains(q)) return true;

    final compactQ = compact(q);
    if (compactQ.length >= 3 && compact(v).contains(compactQ)) {
      return true;
    }

    final parts = v.split(_wordSeparator).where((p) => p.isNotEmpty).toList();
    for (final part in parts) {
      if (part.startsWith(q)) return true;
    }

    final pq = toPhonetic(q).replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (pq.isEmpty) return false;
    final pv = toPhonetic(v);
    if (pq.length >= 2 && pv.contains(pq)) return true;

    final pvCompact = pv.replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (pq.length >= 3 && pvCompact.contains(pq)) return true;

    final pvWords = pv.split(RegExp(r'[^a-z0-9]+')).where((w) => w.isNotEmpty);
    for (final pw in pvWords) {
      if (pw.startsWith(pq)) return true;
    }

    if (compactQ.length >= 3) {
      final qs = skeleton(q);
      if (qs.length >= 2) {
        for (final part in parts) {
          final ps = skeleton(part);
          if (qs.length >= 3 && ps.startsWith(qs)) return true;
          if (qs.length == 2 && ps == qs) return true;
        }
      }
    }

    return false;
  }

  /// Все слова запроса (длиной от 2 символов, или весь запрос целиком) должны
  /// встретиться хотя бы в одном значении из [values] — на любом из алфавитов.
  static bool matchesAny(Iterable<String> values, String query) {
    final q = fold(query);
    if (q.isEmpty) return true;
    final list = values.where((s) => s.trim().isNotEmpty).toList();
    if (list.isEmpty) return false;

    if (list.any((v) => fold(v).contains(q))) return true;

    final words = q.split(_wordSeparator).where((w) => w.length >= 2).toList();
    if (words.isEmpty) words.add(q);

    for (final word in words) {
      if (!list.any((v) => matchesWord(v, word))) return false;
    }
    return true;
  }

  static bool matches(String haystack, String query) =>
      matchesAny([haystack], query);

  static bool phoneticStartsWith(String haystack, String query) {
    final pq = toPhonetic(query).replaceAll(RegExp(r'[^a-z0-9]'), '');
    final pv = toPhonetic(haystack).replaceAll(RegExp(r'[^a-z0-9]'), '');
    return pq.isNotEmpty && pv.startsWith(pq);
  }

  /// Диапазоны (start, end) совпавших слов в [text] для подсветки [HighlightText],
  /// когда прямое совпадение подстроки не сработало (другой алфавит).
  static List<({int start, int end})> crossScriptMatchRanges(
    String text,
    String query,
  ) {
    final q = fold(query);
    if (q.isEmpty || text.isEmpty) return const [];
    final qWords = q.split(_wordSeparator).where((w) => w.length >= 2).toList();
    if (qWords.isEmpty) qWords.add(q);
    final ranges = <({int start, int end})>[];
    for (final m in _wordCapture.allMatches(text)) {
      final token = m.group(0) ?? '';
      if (token.isEmpty) continue;
      if (qWords.any((qw) => matchesWord(token, qw))) {
        ranges.add((start: m.start, end: m.end));
      }
    }
    return ranges;
  }
}
