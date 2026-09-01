/// Определение категории запчасти без интернета.
///
/// Порядок важен: номер модели прямо называет технику, парт-номер у крупных
/// брендов кодирует её префиксом, а слова в названии — самый слабый признак
/// (одна и та же помпа стоит и в стиралке, и в посудомойке).
library;

class PartCategory {
  static const fridge = 'Холодильник';
  static const washer = 'Стиральная машина';
  static const dryer = 'Сушилка';
  static const stove = 'Плита/Духовка';
  static const dishwasher = 'Посудомойка';
  static const other = 'Универсальное';

  static const all = [fridge, washer, dryer, stove, dishwasher, other];

  /// Префиксы номеров моделей. Модель говорит, что это за техника, поэтому
  /// смотрим её первой.
  static const _modelPrefixes = <String, String>{
    // Whirlpool / Maytag / KitchenAid / Amana
    'WRF': fridge, 'WRS': fridge, 'WRT': fridge, 'WRX': fridge,
    'WRB': fridge, 'KRF': fridge, 'KRS': fridge, 'MFI': fridge,
    'MFF': fridge, 'MSS': fridge, 'ASI': fridge, 'ART': fridge,
    'WTW': washer, 'WFW': washer, 'MVW': washer, 'MHW': washer,
    'NTW': washer, 'CAE': washer,
    'WED': dryer, 'WGD': dryer, 'MED': dryer, 'MGD': dryer,
    'NED': dryer, 'YWED': dryer,
    'WDT': dishwasher, 'WDF': dishwasher, 'KDT': dishwasher,
    'KDF': dishwasher, 'MDB': dishwasher, 'WDP': dishwasher,
    'WFE': stove, 'WFG': stove, 'WEE': stove, 'WEG': stove,
    'MER': stove, 'MGR': stove, 'KFE': stove, 'WOS': stove,
    // Samsung
    'RF': fridge, 'RS': fridge, 'RT': fridge, 'RB': fridge,
    'WA': washer, 'WV': washer,
    'DVE': dryer, 'DVG': dryer, 'DV': dryer,
    'DW': dishwasher,
    'NE': stove, 'NX': stove, 'NY': stove, 'NV': stove,
    // LG
    'LFX': fridge, 'LRF': fridge, 'LMX': fridge, 'LFC': fridge,
    'LRM': fridge, 'LFXS': fridge, 'LRS': fridge, 'LRY': fridge,
    'WM': washer, 'WT': washer,
    'DLE': dryer, 'DLG': dryer, 'DLEX': dryer, 'DLGX': dryer,
    'LDF': dishwasher, 'LDT': dishwasher, 'LDP': dishwasher,
    'LRE': stove, 'LRG': stove, 'LSE': stove, 'LSG': stove,
    // GE / Profile
    'GFE': fridge, 'GNE': fridge, 'GSS': fridge, 'PSS': fridge,
    'PFE': fridge, 'GYE': fridge, 'GSE': fridge, 'PYE': fridge,
    'GTW': washer, 'GFW': washer, 'GTD': dryer, 'GFD': dryer,
    'GDT': dishwasher, 'GDF': dishwasher, 'PDT': dishwasher,
    'JGB': stove, 'JGS': stove, 'JB': stove, 'JS': stove,
    'PGB': stove, 'PB': stove, 'JCB': stove,
    // Frigidaire / Electrolux
    'FFSS': fridge, 'FFHB': fridge, 'FGHB': fridge, 'FRSS': fridge,
    'LFSS': fridge, 'FFTR': fridge, 'FRT': fridge,
    'FFFW': washer, 'FFTW': washer, 'EFLS': washer,
    'FFRE': dryer, 'EFME': dryer, 'FFLE': dryer,
    'FFCD': dishwasher, 'FGID': dishwasher, 'FFBD': dishwasher,
    'FFEF': stove, 'FGGH': stove, 'FFGF': stove, 'FCRE': stove,
    // Bosch
    'SHP': dishwasher, 'SHE': dishwasher, 'SHX': dishwasher,
    'SGE': dishwasher, 'SMS': dishwasher,
    'WAT': washer, 'WAW': washer, 'WTG': dryer,
    'B36': fridge, 'B22': fridge,
    'HEI': stove, 'HBL': stove, 'HGI': stove,
  };

  /// Префиксы парт-номеров. У GE, Samsung и Frigidaire первые символы
  /// артикула закреплены за конкретной техникой.
  static final _partPrefixes = <RegExp, String>{
    // GE
    RegExp(r'^WR\d'): fridge,
    RegExp(r'^WB\d'): stove,
    RegExp(r'^WD\d'): dishwasher,
    RegExp(r'^WE\d'): dryer,
    RegExp(r'^WH\d'): washer,
    // Samsung: DC — это и стиралка, и сушилка, поэтому его не берём.
    RegExp(r'^DA\d{2}'): fridge,
    RegExp(r'^DD\d{2}'): dishwasher,
    RegExp(r'^DG\d{2}'): stove,
    // Frigidaire / Electrolux
    RegExp(r'^(240|241|242|297|5303)\d'): fridge,
    RegExp(r'^(134|137)\d'): washer,
    RegExp(r'^(154|5304)\d'): dishwasher,
    RegExp(r'^(316|318)\d'): stove,
  };

  /// Слова в названии. Посудомойку проверяем раньше стиралки: DISHWASHER
  /// содержит WASHER.
  static const _keywords = <(String, List<String>)>[
    (dishwasher, [
      'DISHWASH', 'ПОСУДОМО', 'SPRAY ARM', 'DISH RACK', 'DISHRACK',
      'UPPER RACK', 'LOWER RACK', 'DETERGENT DISPENSER', 'SUMP',
    ]),
    (fridge, [
      'ICE MAKER', 'ICEMAKER', 'EVAPORATOR', 'DEFROST', 'CRISPER',
      'FREEZER', 'FRIDGE', 'REFRIGERAT', 'COMPRESSOR', 'CONDENSER',
      'WATER DISPENSER', 'WATER FILTER', 'DAMPER', 'ХОЛОДИЛ', 'МОРОЗ',
    ]),
    (dryer, [
      'LINT', 'DRYER', 'DRUM ROLLER', 'IDLER PULLEY', 'BLOWER WHEEL',
      'THERMAL FUSE', 'СУШИЛ', 'СУШК',
    ]),
    (washer, [
      'AGITATOR', 'SUSPENSION ROD', 'SHOCK ABSORBER', 'TUB SEAL',
      'BELLOW', 'BOOT SEAL', 'WASHER', 'WASHING', 'СТИРАЛ',
    ]),
    (stove, [
      'BURNER', 'IGNITER', 'IGNITOR', 'BAKE ELEMENT', 'BROIL',
      'OVEN', 'RANGE', 'COOKTOP', 'STOVE', 'GRATE', 'SURFACE ELEMENT',
      'ДУХОВ', 'ПЛИТ', 'КОНФОРК',
    ]),
  ];

  /// Категория по тому, что известно о детали. `null` — признаков не хватило.
  static String? guess({
    String name = '',
    String model = '',
    String part = '',
  }) {
    final cleanModel = _clean(model);
    if (cleanModel.length >= 3) {
      // Длинные префиксы вперёд: WRF точнее, чем WR.
      final keys = _modelPrefixes.keys.toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      for (final prefix in keys) {
        if (cleanModel.startsWith(prefix)) return _modelPrefixes[prefix];
      }
    }

    final cleanPart = _clean(part);
    if (cleanPart.length >= 3) {
      for (final entry in _partPrefixes.entries) {
        if (entry.key.hasMatch(cleanPart)) return entry.value;
      }
    }

    final text = name.toUpperCase();
    if (text.trim().isNotEmpty) {
      for (final (category, words) in _keywords) {
        for (final word in words) {
          if (text.contains(word)) return category;
        }
      }
    }

    return null;
  }

  static String _clean(String value) =>
      value.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  /// Привести ответ ИИ к одной из наших категорий.
  static String? match(String raw) {
    final value = raw.trim().toLowerCase();
    if (value.isEmpty) return null;
    for (final category in all) {
      if (category.toLowerCase() == value) return category;
    }
    const aliases = <String, String>{
      'refrigerator': fridge,
      'fridge': fridge,
      'freezer': fridge,
      'washer': washer,
      'washing machine': washer,
      'dryer': dryer,
      'dishwasher': dishwasher,
      'range': stove,
      'oven': stove,
      'stove': stove,
      'cooktop': stove,
      'other': other,
      'universal': other,
    };
    return aliases[value];
  }
}
