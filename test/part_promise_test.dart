import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fix_appliance_crm/models/job.dart';
import 'package:flutter_test/flutter_test.dart';

/// Очередь запчастей: просроченное обещание — наверху, свежее — ниже,
/// без обещания — в самом низу. Тот же порядок, что у грузовика в шапке.
List<Job> partQueueOrder(List<Job> jobs, DateTime today) {
  final start = DateTime(today.year, today.month, today.day);
  // 0 — срок прошёл, 1 — срок ещё впереди, 2 — день не обещан.
  int rank(Job job) {
    final promised = job.promisedPartAt;
    if (promised == null) return 2;
    return promised.isBefore(start) ? 0 : 1;
  }

  final sorted = [...jobs];
  sorted.sort((a, b) {
    final byRank = rank(a).compareTo(rank(b));
    if (byRank != 0) return byRank;
    return (a.promisedPartAt ?? a.createdAt)
        .compareTo(b.promisedPartAt ?? b.createdAt);
  });
  return sorted;
}

Job partJob(String id, DateTime created, {DateTime? promised}) => Job(
  id: id,
  clientId: 'c$id',
  clientName: 'Client $id',
  clientPhone: '',
  clientAddress: '',
  status: 'Ожидание запчасти',
  createdAt: created,
  promisedPartAt: promised,
);

void main() {
  final today = DateTime(2026, 10, 27);

  test('просроченные обещания встают первыми, без даты — последними', () {
    final ordered = partQueueOrder([
      partJob('no-date', DateTime(2026, 10, 1)),
      partJob('soon', DateTime(2026, 10, 20), promised: DateTime(2026, 10, 29)),
      partJob('late', DateTime(2026, 10, 25), promised: DateTime(2026, 10, 25)),
      partJob('later', DateTime(2026, 10, 10), promised: DateTime(2026, 10, 20)),
    ], today);

    expect(ordered.map((job) => job.id), ['later', 'late', 'soon', 'no-date']);
  });

  test('сегодняшний день обещания ещё не просрочен', () {
    final ordered = partQueueOrder([
      partJob('today', DateTime(2026, 10, 1), promised: today),
      partJob('yesterday', DateTime(2026, 10, 2), promised: DateTime(2026, 10, 26)),
    ], today);

    expect(ordered.first.id, 'yesterday');
  });

  test('старое поле agreedReturnAt читается как обещанный день', () {
    final job = Job.fromMap({
      'clientId': 'c',
      'createdAt': Timestamp.fromDate(DateTime(2026, 10, 1)),
      'agreedReturnAt': Timestamp.fromDate(DateTime(2026, 10, 29, 15, 30)),
    }, 'old');

    expect(job.promisedPartAt, DateTime(2026, 10, 29, 15, 30));
  });

  test('promisedPartAt важнее старого agreedReturnAt', () {
    final job = Job.fromMap({
      'clientId': 'c',
      'createdAt': Timestamp.fromDate(DateTime(2026, 10, 1)),
      'agreedReturnAt': Timestamp.fromDate(DateTime(2026, 10, 20)),
      'promisedPartAt': Timestamp.fromDate(DateTime(2026, 10, 31)),
    }, 'moved');

    expect(job.promisedPartAt, DateTime(2026, 10, 31));
  });

  test('обещание с временем в сегодняшний день сохраняет время и не просрочено', () {
    final withTime = DateTime(2026, 10, 27, 14, 30);
    final job = Job.fromMap({
      'clientId': 'c',
      'createdAt': Timestamp.fromDate(DateTime(2026, 10, 1)),
      'promisedPartAt': Timestamp.fromDate(withTime),
    }, 'timed');

    expect(job.promisedPartAt, withTime);
    final ordered = partQueueOrder([
      partJob('today-timed', DateTime(2026, 10, 1), promised: withTime),
      partJob('yesterday', DateTime(2026, 10, 2), promised: DateTime(2026, 10, 26, 18, 0)),
    ], today);
    expect(ordered.first.id, 'yesterday');
  });

  test('несколько заказанных запчастей (Amazon, Reliable Parts) читаются и сохраняются', () {
    final job = Job.fromMap({
      'clientId': 'c',
      'createdAt': Timestamp.fromDate(DateTime(2026, 10, 1)),
      'trackingOrders': [
        {
          'part': 'Помпа',
          'carrier': 'amazon',
          'trackingNumber': 'TBA1234567890',
          'orderId': '112-1111111-1111111',
          'status': 'shipped',
        },
        {
          'part': 'ТЭН',
          'carrier': 'reliable_parts',
          'trackingNumber': '1Z999AA10123456784',
          'orderId': 'RP-987654',
          'status': 'delivered',
        },
      ],
    }, 'multi-parts');

    expect(job.trackingOrders.length, 2);
    expect(job.trackingOrders[0].part, 'Помпа');
    expect(job.trackingOrders[0].effectiveCarrier, 'amazon');
    expect(job.trackingOrders[0].orderId, '112-1111111-1111111');
    expect(job.trackingOrders[1].part, 'ТЭН');
    expect(job.trackingOrders[1].effectiveCarrier, 'reliable_parts');
    expect(job.trackingOrders[1].status, 'delivered');
    expect(job.expectedParts, containsAll(['Помпа', 'ТЭН']));
  });
}
