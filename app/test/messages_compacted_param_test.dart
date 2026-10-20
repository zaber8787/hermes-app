// Pre-compaction history must be fetchable: scroll-to-top was dead on
// heavily-compacted sessions because the messages query omitted
// include_compacted, so the API hid every compacted row (56 visible of 500+
// stored). Pins the flag on the wire.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/transport.dart';

class _SpyPort implements HttpPort {
  Uri? last;

  @override
  Future<PortResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Stream<List<int>>? body,
    int? contentLength,
    Future<void>? abortTrigger,
    Duration? headersTimeout,
    DispatchObservation? observation,
  }) async {
    last = uri;
    return PortResponse(
      200,
      {'content-type': 'application/json'},
      Stream.value(utf8.encode(jsonEncode({'object': 'list', 'data': []}))),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('unexpected HttpPort call: $invocation');
  }
}

void main() {
  test('messages() requests the compacted lineage', () async {
    final port = _SpyPort();
    final repo = HermesRepository('http://x.test', 'k', port: port);
    await repo.messages('s1', offset: 200);
    final q = port.last!.queryParameters;
    expect(q['include_compacted'], 'true');
    expect(q['order'], 'latest');
    expect(q['offset'], '200');
  });
}
