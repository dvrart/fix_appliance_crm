import 'package:fix_appliance_crm/models/job.dart';
import 'package:fix_appliance_crm/models/labour_discount.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final items = <Map<String, dynamic>>[
    {'name': 'Service call', 'qty': 1, 'price': 99, 'type': 'Service'},
    {'name': 'Drain pump', 'qty': 1, 'price': 89, 'type': 'Part'},
    {'name': 'Labour', 'qty': 2, 'price': 50.5, 'type': 'Service'},
    {'name': 'Old line without a label', 'qty': 1, 'price': 40},
  ];

  test('the discount base is only labour-marked lines — never parts or unlabeled lines', () {
    expect(LabourDiscount.labourBase(items), 200);
    expect(LabourDiscount.amount(items, 30), 60);
    expect(LabourDiscount.amount(items, 150), 200, reason: 'clamped to 100%');
  });

  test('applying adds one negative Service line; tax and total follow it', () {
    final next = LabourDiscount.apply(items, 30, carePlan: true);
    expect(next.length, items.length + 1);
    final line = next.last;
    expect(line['price'], -60);
    expect(line['type'], 'Service');
    expect(line['name'], 'Labour discount 30% (Care Plan)');
    expect(Job.itemKind(line), 'service');
    final doc = {'items': next, 'taxRate': 0.13};
    expect(Job.documentSubtotal(doc), 99 + 89 + 101 + 40 - 60);
    expect(Job.documentTotal(doc), closeTo((99 + 89 + 101 + 40 - 60) * 1.13, 0.0001));
  });

  test('a Care Plan repair covers all labour and leaves the parts', () {
    final covered = LabourDiscount.coverLabour(items);
    expect(covered.last['price'], -200);
    expect(covered.last['carePlan'], isTrue);
    expect(Job.documentSubtotal({'items': covered}), 89 + 40);

    final manual = LabourDiscount.apply(items, 10);
    expect(LabourDiscount.coverLabour(manual).last['price'], -20,
        reason: 'a discount the owner typed stays as he typed it');
    expect(LabourDiscount.coverLabour([items[1]]), [items[1]],
        reason: 'a parts-only invoice needs no labour line');
  });

  test('re-applying replaces the line, 0 removes it, refresh follows changed labour', () {
    final once = LabourDiscount.apply(items, 30);
    final twice = LabourDiscount.apply(once, 10);
    expect(twice.where(LabourDiscount.isDiscountLine).length, 1);
    expect(twice.last['price'], -20);
    expect(twice.last['name'], 'Labour discount 10%');
    expect(LabourDiscount.apply(twice, 0).any(LabourDiscount.isDiscountLine), isFalse);

    final edited = [
      ...twice.where((i) => !LabourDiscount.isDiscountLine(i)),
      {'name': 'Extra labour', 'qty': 1, 'price': 100, 'type': 'Service'},
      twice.last,
    ];
    final refreshed = LabourDiscount.refresh(edited);
    expect(refreshed.length, edited.length);
    expect(refreshed.last['price'], -30);
    expect(LabourDiscount.refresh(items), same(items), reason: 'no discount — list untouched');
  });
}
