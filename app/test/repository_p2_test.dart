import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/hermes_repository.dart';

void main() {
  test('renameSession sends PATCH with raw JSON title', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    String? method, body;
    server.listen((request) async {
      method = request.method;
      body = await utf8.decoder.bind(request).join();
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'ok': true}));
      await request.response.close();
    });
    final repo = HermesRepository('http://127.0.0.1:${server.port}', 'k');
    try {
      await repo.renameSession('s/1', '新名字');
      expect(method, 'PATCH');
      expect(jsonDecode(body!)['title'], '新名字');
    } finally {
      repo.close();
      await server.close(force: true);
    }
  });

  test('setSessionModel POSTs model to the session model route', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    String? path, body;
    server.listen((request) async {
      path = request.uri.path;
      body = await utf8.decoder.bind(request).join();
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'model_lock': 'accepted'}));
      await request.response.close();
    });
    final repo = HermesRepository('http://127.0.0.1:${server.port}', 'k');
    try {
      await repo.setSessionModel('s%2F1', 'model-x');
      expect(path, endsWith('/model'));
      expect(jsonDecode(body!)['model'], 'model-x');
    } finally {
      repo.close();
      await server.close(force: true);
    }
  });

  test('deleteSession issues DELETE', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    String? method;
    server.listen((request) async {
      method = request.method;
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{}');
      await request.response.close();
    });
    final repo = HermesRepository('http://127.0.0.1:${server.port}', 'k');
    try {
      await repo.deleteSession('s1');
      expect(method, 'DELETE');
    } finally {
      repo.close();
      await server.close(force: true);
    }
  });

  test('modelOptions flattens providers with current flag', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'providers': [
            {
              'slug': 'p1',
              'name': 'P1',
              'is_current': false,
              'models': [
                {'id': 'm-a', 'is_current': true},
                {'id': 'm-b'},
              ],
            },
          ],
        }),
      );
      await request.response.close();
    });
    final repo = HermesRepository('http://127.0.0.1:${server.port}', 'k');
    try {
      final options = await repo.modelOptions();
      expect(options.length, 2);
      expect(options.first['model'], 'm-a');
      expect(options.first['current'], isTrue);
      expect(options.last['current'], isFalse);
    } finally {
      repo.close();
      await server.close(force: true);
    }
  });
}
