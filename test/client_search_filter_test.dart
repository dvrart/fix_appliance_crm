import 'package:fix_appliance_crm/features/clients/client_search_filter.dart';
import 'package:fix_appliance_crm/models/job.dart';
import 'package:flutter_test/flutter_test.dart';

/// Поиск клиентов по фильтрам (просьба FIX 25.10.2026): город, имя,
/// описание ремонта и запчасти из заявок клиента. Фильтры можно включать
/// по несколько сразу — условия складываются по «И», слова внутри одного
/// запроса тоже.
void main() {
  final sue = <String, dynamic>{
    'id': 'sue',
    'fullName': 'Sue Rathbone',
    'phone': '9054837515',
    'notes': 'Собака во дворе',
    'locations': [
      {
        'id': 'primary',
        'street': '190 Argyle Street',
        'city': 'Simcoe',
        'postalCode': 'N3Y 1V7',
        'contacts': [
          {'id': 'tenant', 'name': 'Bob Tenant', 'phone': '5195550101', 'role': 'tenant'},
        ],
      },
    ],
  };
  final will = <String, dynamic>{
    'id': 'will',
    'fullName': 'Will Smith',
    'phone': '4169842574',
    'address': '1023 Cheesewood Road, Brantford',
  };
  final frank = <String, dynamic>{
    'id': 'frank',
    'fullName': 'Frank Miller',
    'phone': '5197541234',
    'address': '22 West Street, Brantford',
  };

  final jobs = [
    Job(
      id: 'j1',
      clientId: 'sue',
      clientName: 'Sue Rathbone',
      clientPhone: '9054837515',
      clientAddress: '190 Argyle Street, Simcoe',
      createdAt: DateTime(2026, 10, 25),
      description: 'Посудомойка не сливает воду, ошибка E15',
      appliances: [JobAppliance(type: 'Посудомойка', brand: 'Bosch')],
      documents: const [
        {
          'type': 'Invoice',
          'items': [
            {'name': 'Drain pump', 'partNumber': 'W10 348-269', 'type': 'Part'},
            {'name': 'Labour', 'type': 'Service'},
          ],
        },
        {
          'type': 'Invoice',
          'deletedAt': '2026-10-20T00:00:00.000',
          'items': [
            {'name': 'Heating element', 'type': 'Part'},
          ],
        },
      ],
    ),
    // Заявка без привязки к карточке: находится по номеру телефона.
    Job(
      id: 'j2',
      clientId: '',
      clientName: 'Will',
      clientPhone: '+1 (416) 984-2574',
      clientAddress: '55 Main St, Paris',
      createdAt: DateTime(2026, 10, 7),
      solution: 'Заменил ремень барабана',
      appliances: [JobAppliance(type: 'Сушилка', brand: 'Whirlpool')],
    ),
    // Пример FIX: в Брэнтфорде ремонтировал стиральную машину —
    // менял дверной замок.
    Job(
      id: 'j3',
      clientId: 'frank',
      clientName: 'Frank Miller',
      clientPhone: '5197541234',
      clientAddress: '22 West Street, Brantford',
      createdAt: DateTime(2026, 9, 14),
      description: 'Заменил дверной замок',
      appliances: [JobAppliance(type: 'Стиральная машина', brand: 'LG')],
    ),
  ];
  final index = ClientJobIndex.build(jobs);

  bool hit(Map<String, dynamic> data, ClientSearchField field, String query) =>
      clientMatchesField(data, data['id'] as String, query, field, index);

  test('город — из адресов клиента и из его заявок', () {
    expect(hit(sue, ClientSearchField.city, 'simcoe'), isTrue);
    expect(hit(will, ClientSearchField.city, 'brantford'), isTrue);
    expect(hit(will, ClientSearchField.city, 'paris'), isTrue);
    expect(hit(sue, ClientSearchField.city, 'brantford'), isFalse);
    // Улица — не город.
    expect(hit(sue, ClientSearchField.city, 'argyle'), isFalse);
  });

  test('имя — клиент и люди на его адресах, но не город и не техника', () {
    expect(hit(sue, ClientSearchField.name, 'rathbone'), isTrue);
    expect(hit(sue, ClientSearchField.name, 'bob'), isTrue);
    expect(hit(sue, ClientSearchField.name, 'simcoe'), isFalse);
    expect(hit(sue, ClientSearchField.name, 'bosch'), isFalse);
  });

  test('описание — поломка, решение, техника и заметки', () {
    expect(hit(sue, ClientSearchField.description, 'e15'), isTrue);
    expect(hit(sue, ClientSearchField.description, 'посудомойка'), isTrue);
    expect(hit(sue, ClientSearchField.description, 'bosch'), isTrue);
    expect(hit(sue, ClientSearchField.description, 'собака'), isTrue);
    expect(hit(will, ClientSearchField.description, 'ремень'), isTrue);
    expect(hit(sue, ClientSearchField.description, 'ремень'), isFalse);
  });

  test('запчасти — позиции счетов и номер детали в любом написании', () {
    expect(hit(sue, ClientSearchField.parts, 'drain pump'), isTrue);
    expect(hit(sue, ClientSearchField.parts, 'W10348269'), isTrue);
    expect(hit(sue, ClientSearchField.parts, 'w10-348'), isTrue);
    // Счёт в корзине не считается.
    expect(hit(sue, ClientSearchField.parts, 'heating element'), isFalse);
    expect(hit(will, ClientSearchField.parts, 'drain pump'), isFalse);
  });

  test('«Везде» ищет по карточке, как раньше; пустой запрос пропускает всех', () {
    expect(hit(sue, ClientSearchField.all, 'argyle'), isTrue);
    expect(hit(sue, ClientSearchField.all, '905483'), isTrue);
    expect(hit(will, ClientSearchField.parts, ''), isTrue);
  });

  test('частые города для быстрых кнопок', () {
    final cities = topClientCities([sue, will], index);
    expect(cities, containsAll(['Simcoe', 'Brantford', 'Paris']));
  });

  test('слова запроса ищутся по «И» — машина и дверной замок', () {
    expect(
      hit(frank, ClientSearchField.description, 'стиральная машина дверной замок'),
      isTrue,
    );
    // Окончания слов: «стиральн» находит «стиральная».
    expect(hit(frank, ClientSearchField.description, 'стиральн замок'), isTrue);
    // Слова из одной заявки клиента тоже подходят.
    expect(hit(sue, ClientSearchField.description, 'посудомойка сливает'), isTrue);
    // Не хватает хотя бы одного слова — не подходит.
    expect(
      hit(frank, ClientSearchField.description, 'стиральная машина холодильник'),
      isFalse,
    );
  });

  test('несколько фильтров складываются по «И»', () {
    bool all(Map<String, dynamic> data, List<ClientSearchCriterion> criteria) =>
        clientMatchesAll(data, data['id'] as String, index, criteria);

    const washerAndDoorLock = [
      ClientSearchCriterion(ClientSearchField.city, 'brantford'),
      ClientSearchCriterion(
        ClientSearchField.description,
        'стиральная машина дверной замок',
      ),
    ];
    expect(all(frank, washerAndDoorLock), isTrue);
    // У Уилла город Брэнтфорд есть, но стиральной машины не было.
    expect(all(will, washerAndDoorLock), isFalse);
    // У Сью стиральная техника есть (посудомойка), но город другой.
    expect(all(sue, washerAndDoorLock), isFalse);
    // Пустые запросы пропускаются, не отсекая всех.
    expect(
      all(will, const [ClientSearchCriterion(ClientSearchField.city, '')]),
      isTrue,
    );
  });
}
