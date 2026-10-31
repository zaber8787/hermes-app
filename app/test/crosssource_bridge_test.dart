import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/transport.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';

// TASK-CROSSSOURCE R3: the compat bridge answers a foreign-source (Discord)
// send it could not deliver after its retries with HTTP 502 and
// `kind=bridge_unavailable`. The repository turns exactly that body into its
// own localized error; any other 502 stays the generic server failure.
class FixedPort implements HttpPort {
  FixedPort(this.status, this.body);
  final int status;
  final Object body;

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
    final raw = this.body is String ? this.body as String : jsonEncode(this.body);
    return PortResponse(
      status,
      {'content-type': 'application/json'},
      Stream.value(utf8.encode(raw)),
    );
  }

  @override
  void close() {}
}

Future<ApiException> chatError(FixedPort port) async {
  final repo = HermesRepository('http://bridge.invalid', 'k', port: port);
  try {
    await repo.chat('20260910_151843_94d2209a', 'hi').toList();
  } on ApiException catch (e) {
    return e;
  }
  fail('chat did not throw');
}

void main() {
  test('502 kind=bridge_unavailable becomes the bridge error', () async {
    final e = await chatError(
      FixedPort(502, {
        'error': {'message': 'discord bridge unavailable', 'code': 'bridge_unavailable'},
        'kind': 'bridge_unavailable',
        'delivery_id': 'xsrc_1',
      }),
    );
    expect(e.status, 502);
    expect(e.kind, ApiException.bridgeUnavailable);
    expect((e.uiMessage as UiLocal).key, MessageKey.apiM029);
  });

  test('any other 502 stays the generic server failure', () async {
    for (final body in <Object>[
      {'error': {'message': 'bad gateway'}},
      'not json',
      {'kind': 'something_else'},
    ]) {
      final e = await chatError(FixedPort(502, body));
      expect(e.status, 502);
      expect(e.kind, isNull);
      expect((e.uiMessage as UiLocal).key, MessageKey.apiM007);
    }
  });
}
