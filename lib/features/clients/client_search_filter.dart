import '../../models/client.dart';
import '../../models/job.dart';
import '../../services/client_service.dart';

/// По каким полям ищем на экране «Клиенты» (просьба FIX 25.10.2026):
/// город, имя, описание ремонта, запчасти. «Везде» — прежний поиск по
/// карточке клиента.
///
/// Фильтры можно включать по несколько сразу: `ClientSearchCriterion` +
/// `clientMatchesAll` складывают условия по «И» — например, город Брэнтфорд
/// и ремонт стиральной машины с заменой дверного замка. Слова внутри одного
/// запроса тоже ищутся по «И», поэтому «стиральная машина дверной замок»
/// находит работу и про машину, и про замок.
enum ClientSearchField { all, city, name, description, parts }

extension ClientSearchFieldX on ClientSearchField {
  /// Фильтру нужны заявки клиента, а не только его карточка.
  bool get needsJobs =>
      this == ClientSearchField.city ||
      this == ClientSearchField.description ||
      this == ClientSearchField.parts;
}

/// Тексты из заявок, разложенные по клиентам: что ремонтировали, какие
/// запчасти ставили, в каком городе была работа.
class ClientJobIndex {
  final Map<String, _ClientJobTexts> _byClientId;
  final Map<String, _ClientJobTexts> _byPhone;

  ClientJobIndex._(this._byClientId, this._byPhone);

  static final empty = ClientJobIndex._(const {}, const {});

  factory ClientJobIndex.build(Iterable<Job> jobs) {
    final byClientId = <String, _ClientJobTexts>{};
    final byPhone = <String, _ClientJobTexts>{};
    for (final job in jobs) {
      if (job.isDeleted || job.isMergedDuplicate) continue;
      final texts = _ClientJobTexts.of(job);
      final id = job.clientId.trim();
      if (id.isNotEmpty) {
        byClientId.putIfAbsent(id, _ClientJobTexts.new).add(texts);
      }
      final phone = ClientService.normalizePhone(job.clientPhone);
      if (phone.length >= 10) {
        byPhone.putIfAbsent(phone, _ClientJobTexts.new).add(texts);
      }
    }
    return ClientJobIndex._(byClientId, byPhone);
  }

  _ClientJobTexts _textsOf(String clientId, String phone) {
    final out = _ClientJobTexts();
    final byId = _byClientId[clientId.trim()];
    if (byId != null) out.add(byId);
    // Заявки без привязки к карточке находим по номеру телефона.
    final norm = ClientService.normalizePhone(phone);
    final byPhone = norm.length >= 10 ? _byPhone[norm] : null;
    if (byPhone != null) out.add(byPhone);
    return out;
  }
}

class _ClientJobTexts {
  final List<String> cities = [];
  final List<String> descriptions = [];
  final List<String> parts = [];

  _ClientJobTexts();

  factory _ClientJobTexts.of(Job job) {
    final texts = _ClientJobTexts();
    final city = job.displayCity.trim();
    if (city.isNotEmpty) texts.cities.add(city);
    texts.descriptions.addAll([
      job.description,
      job.solution,
      for (final r in job.recalls) ...[r.description, r.report],
      for (final appliance in job.appliances) ...[
        appliance.type,
        appliance.brand,
        appliance.model,
        appliance.issue,
      ],
    ]);
    texts.parts.addAll([
      job.packingNotes,
      job.trackingPart,
      for (final order in job.trackingOrders) order.part,
    ]);
    for (final doc in job.documents) {
      if (Job.isDocumentTrashed(doc)) continue;
      final items = doc['items'];
      if (items is! List) continue;
      for (final item in items) {
        if (item is! Map) continue;
        texts.parts.addAll([
          (item['name'] ?? '').toString(),
          (item['description'] ?? '').toString(),
          (item['partNumber'] ?? '').toString(),
        ]);
      }
    }
    texts.descriptions.removeWhere((s) => s.trim().isEmpty);
    texts.parts.removeWhere((s) => s.trim().isEmpty);
    return texts;
  }

  void add(_ClientJobTexts other) {
    cities.addAll(other.cities);
    descriptions.addAll(other.descriptions);
    parts.addAll(other.parts);
  }
}

/// Города клиента: из его адресов и из заявок.
List<String> clientCities(Client client, ClientJobIndex index) {
  final out = <String>[];
  final seen = <String>{};
  void add(String raw) {
    final city = raw.trim();
    if (city.isEmpty || !seen.add(city.toLowerCase())) return;
    out.add(city);
  }

  for (final location in client.locations) {
    add(location.city);
  }
  add(Job.cityFromAddress(client.address));
  index._textsOf(client.id, client.phone).cities.forEach(add);
  return out;
}

String _fold(String value) => value.toLowerCase().trim();

final _wordSeparator = RegExp(r'[^a-z0-9а-яё]+');

String _compact(String value) =>
    value.toLowerCase().replaceAll(_wordSeparator, '');

bool _containsWord(List<String> values, String word) {
  final compactWord = _compact(word);
  for (final value in values) {
    final v = _fold(value);
    if (v.contains(word)) return true;
    // Номер детали пишут как угодно: «W10 348-269» = «W10348269».
    if (compactWord.length >= 3 && _compact(v).contains(compactWord)) {
      return true;
    }
    // Окончания слов: «машина» находит «машине», «стиральн» — «стиральной».
    for (final part in v.split(_wordSeparator)) {
      if (part.startsWith(word)) return true;
    }
  }
  return false;
}

/// Каждое слово запроса должно встретиться хотя бы в одном из значений —
/// «стиральная машина дверной замок» находит и машину, и замок, даже если
/// это разные заявки клиента. Слова короче трёх букв пропускаются; если
/// запрос состоит только из них, он ищется целиком, как раньше.
bool _anyContains(Iterable<String> values, String query) {
  final q = _fold(query);
  if (q.isEmpty) return true;
  final words = q.split(_wordSeparator).where((w) => w.length >= 3).toList();
  if (words.isEmpty) words.add(q);
  final list = values.toList();
  for (final word in words) {
    if (!_containsWord(list, word)) return false;
  }
  return true;
}

/// Подходит ли клиент под запрос в выбранном поле.
bool clientMatchesField(
  Map<String, dynamic> data,
  String id,
  String query,
  ClientSearchField field,
  ClientJobIndex index,
) {
  if (query.trim().isEmpty) return true;
  if (field == ClientSearchField.all) {
    return ClientService.matchesMap(data, id, query);
  }
  final Client client;
  try {
    client = Client.fromMap(data, id);
  } catch (_) {
    return false;
  }
  switch (field) {
    case ClientSearchField.city:
      return _anyContains(clientCities(client, index), query);
    case ClientSearchField.name:
      return _anyContains([
        (data['display_name'] ?? '').toString(),
        client.fullName,
        client.companyName ?? '',
        for (final location in client.locations)
          for (final contact in location.contacts) contact.name,
      ], query);
    case ClientSearchField.description:
      return _anyContains([
        client.notes ?? '',
        ...index._textsOf(client.id, client.phone).descriptions,
      ], query);
    case ClientSearchField.parts:
      return _anyContains(index._textsOf(client.id, client.phone).parts, query);
    case ClientSearchField.all:
      return true;
  }
}

/// Один критерий поиска: поле и запрос.
class ClientSearchCriterion {
  final ClientSearchField field;
  final String query;

  const ClientSearchCriterion(this.field, this.query);
}

/// Клиент подходит, если подходит под каждый критерий (условия по «И»).
bool clientMatchesAll(
  Map<String, dynamic> data,
  String id,
  ClientJobIndex index,
  Iterable<ClientSearchCriterion> criteria,
) {
  for (final criterion in criteria) {
    if (criterion.query.trim().isEmpty) continue;
    if (!clientMatchesField(data, id, criterion.query, criterion.field, index)) {
      return false;
    }
  }
  return true;
}

/// Самые частые города среди клиентов — для быстрых кнопок под поиском.
List<String> topClientCities(
  Iterable<Map<String, dynamic>> clients,
  ClientJobIndex index, {
  int limit = 12,
}) {
  final counts = <String, int>{};
  final labels = <String, String>{};
  for (final data in clients) {
    final id = (data['id'] ?? '').toString();
    final Client client;
    try {
      client = Client.fromMap(data, id);
    } catch (_) {
      continue;
    }
    for (final city in clientCities(client, index)) {
      final key = city.toLowerCase();
      labels.putIfAbsent(key, () => city);
      counts[key] = (counts[key] ?? 0) + 1;
    }
  }
  final keys = counts.keys.toList()
    ..sort((a, b) {
      final byCount = counts[b]!.compareTo(counts[a]!);
      return byCount != 0 ? byCount : a.compareTo(b);
    });
  return [for (final key in keys.take(limit)) labels[key]!];
}
