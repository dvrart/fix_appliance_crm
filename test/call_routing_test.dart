import 'package:fix_appliance_crm/services/call_routing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('phone numbers become E.164, junk becomes empty', () {
    expect(CallRouting.normalizePhone('(519) 555-0123'), '+15195550123');
    expect(CallRouting.normalizePhone('1 519 555 0123'), '+15195550123');
    expect(CallRouting.normalizePhone('+44 20 7946 0958'), '+442079460958');
    expect(CallRouting.normalizePhone('555-0123'), '');
    expect(CallRouting.pretty('+15195550123'), '+1 (519) 555-0123');
  });

  test('without a SIM number every mode works as the app', () {
    final noSim = CallRouting.fromConfig({'callRoute': 'cell'});
    expect(noSim.route, CallRoute.cell);
    expect(noSim.effective, CallRoute.app);
    expect(noSim.outboundViaCell, isFalse);
    expect(noSim.autoFallback, isFalse);
  });

  test('the chosen mode applies once the SIM number is set', () {
    final cell = CallRouting.fromConfig({
      'callRoute': 'cell',
      'masterCellNumber': '519-555-0123',
    });
    expect(cell.cellNumber, '+15195550123');
    expect(cell.outboundViaCell, isTrue);

    final auto = cell.copyWith(route: CallRoute.auto);
    expect(auto.autoFallback, isTrue);
    expect(auto.outboundViaCell, isFalse);

    final unknown = CallRouting.fromConfig({
      'callRoute': 'whatever',
      'masterCellNumber': '5195550123',
    });
    expect(unknown.effective, CallRoute.app);
  });
}
