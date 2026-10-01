import 'dart:async';

import 'package:fix_appliance_crm/services/network_status_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _TrackingClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;
  bool closed = false;

  _TrackingClient(this.respond);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      respond(request);

  @override
  void close() => closed = true;
}

void main() {
  final url = Uri.https('example.invalid', '/synthetic');

  test('successful reads preserve headers and release their client', () async {
    final client = _TrackingClient((request) async {
      expect(request.headers['X-Test'], 'value');
      return http.StreamedResponse(Stream.value([79, 75]), 200);
    });
    final response = await http.runWithClient(
      () => getWithTimeout(url, headers: {'X-Test': 'value'}),
      () => client,
    );
    expect(response.body, 'OK');
    expect(client.closed, isTrue);
  });

  test('failed reads preserve the error and release their client', () async {
    final client = _TrackingClient((_) async => throw StateError('Synthetic'));
    await expectLater(
      http.runWithClient(() => getWithTimeout(url), () => client),
      throwsStateError,
    );
    expect(client.closed, isTrue);
  });

  testWidgets('a server that never responds cannot hold the UI indefinitely', (
    tester,
  ) async {
    final pending = Completer<http.StreamedResponse>();
    final client = _TrackingClient((_) => pending.future);
    final result = http.runWithClient(() => getWithTimeout(url), () => client);
    final check = expectLater(result, throwsA(isA<TimeoutException>()));
    await tester.pump();
    await tester.pump(const Duration(seconds: 13));
    await check;
    expect(client.closed, isTrue);
    pending.complete(http.StreamedResponse(const Stream.empty(), 200));
    await tester.pump();
  });

  testWidgets('the deadline covers a stalled response body, not just headers', (
    tester,
  ) async {
    final body = StreamController<List<int>>();
    final client = _TrackingClient(
      (_) async => http.StreamedResponse(body.stream, 200),
    );
    final result = http.runWithClient(
      () => getWithTimeout(url, timeout: const Duration(seconds: 2)),
      () => client,
    );
    final check = expectLater(result, throwsA(isA<TimeoutException>()));
    await tester.pump();
    body.add([79]);
    await tester.pump(const Duration(seconds: 3));
    await check;
    expect(client.closed, isTrue);
    unawaited(body.close());
    await tester.pump();
  });
}
