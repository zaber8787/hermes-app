import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/l10n/app_strings.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'package:hermes_app/features/attachments/attachment.dart';
import 'package:hermes_app/features/attachments/attachment_controller.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/features/chat/message_content.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late Directory dir;
  late File file;
  late HttpServer server;
  late HermesRepository repo;
  late LocalStore store;
  final id = 'a' * 32;
  var uploads = 0;
  setUp(() async {
    uploads = 0;
    dir = await Directory.systemTemp.createTemp('hermes-p3');
    file = await File('${dir.path}/draft').writeAsString('hello file');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    repo = HermesRepository('http://127.0.0.1:${server.port}', 'SECRET');
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
  });
  tearDown(() async {
    repo.close();
    await server.close(force: true);
    await dir.delete(recursive: true);
  });
  void serve({bool enabled = true, int status = 201}) {
    server.listen((r) async {
      r.response.headers.contentType = ContentType.json;
      if (r.uri.path == '/v1/capabilities') {
        r.response.write(
          jsonEncode({
            'features': {
              'browser_extension_control': {
                'enabled': enabled,
                'artifact_transport': {
                  'max_bytes': 10485760,
                  'allowed_mime_types': ['text/plain'],
                },
              },
            },
          }),
        );
      } else {
        uploads++;
        expect(r.method, 'POST');
        expect(r.headers.value('authorization'), 'Bearer SECRET');
        expect(r.headers.contentType!.mimeType, 'text/plain');
        expect(r.headers.value('X-Artifact-Filename'), 'note.txt');
        expect(await utf8.decoder.bind(r).join(), 'hello file');
        r.response.statusCode = status;
        r.response.write(
          status == 201
              ? jsonEncode({
                  'artifact_id': id,
                  'filename': 'note.txt',
                  'expires_at':
                      DateTime.now().millisecondsSinceEpoch / 1000 + 300,
                })
              : '{"error":"SECRET reflected"}',
        );
      }
      await r.response.close();
    });
  }

  test(
    'raw upload receipt persists before message assembly; retry reuses id',
    () async {
      serve();
      await store.saveAttachments(repo.baseUrl, 's', [
        AttachmentDraft(localPath: file.path, filename: 'note.txt'),
      ]);
      final c = AttachmentController(repo, store, 's');
      expect(await c.prepare('read this'), 'read this\n[附件: $id note.txt]');
      final reopened = AttachmentController(repo, store, 's');
      expect(reopened.drafts.single.artifactId, id);
      expect(await reopened.prepare('again'), 'again\n[附件: $id note.txt]');
      expect(uploads, 1);
      expect(store.attachments(repo.baseUrl, 'other'), isEmpty);
      expect(store.attachments('http://other', 's'), isEmpty);
      await reopened.clear();
      expect(await file.exists(), isFalse);
      c.dispose();
      reopened.dispose();
    },
  );
  test('disabled capabilities preserves draft and sends no upload', () async {
    serve(enabled: false);
    await store.saveAttachments(repo.baseUrl, 's', [
      AttachmentDraft(localPath: file.path, filename: 'note.txt'),
    ]);
    final c = AttachmentController(repo, store, 's');
    await expectLater(c.prepare('text'), throwsA(isA<ApiException>()));
    expect((c.error! as UiLocal).key, MessageKey.apiM015);
    expect(uploads, 0);
    expect(store.attachments(repo.baseUrl, 's').single.localPath, file.path);
    expect(await file.exists(), isTrue);
    c.dispose();
  });
  for (final status in [400, 404, 413, 415]) {
    test(
      'HTTP $status is translated and does not echo response body',
      () async {
        serve(status: status);
        await expectLater(
          repo.uploadAttachment(StreamAttachmentSource(() => file.openRead()), 'note.txt'),
          throwsA(
            isA<ApiException>()
                .having((e) => e.status, 'status', status)
                .having(
                  (e) =>
                      AppStrings.forLocale(AppLocale.zhHant).render(e.uiMessage),
                  'safe Chinese',
                  allOf(isNot(contains('SECRET')), contains('附件')),
                ),
          ),
        );
      },
    );
  }
  test(
    'expired saved receipt uploads again and invalid receipt cannot compose',
    () async {
      serve();
      await store.saveAttachments(repo.baseUrl, 's', [
        AttachmentDraft(
          localPath: file.path,
          filename: 'note.txt',
          artifactId: id,
          expiresAt: 1,
        ),
      ]);
      final c = AttachmentController(repo, store, 's');
      expect(await c.prepare(''), '[附件: $id note.txt]');
      expect(uploads, 1);
      expect(
        () => composeAttachmentInput('x', [
          AttachmentDraft(localPath: file.path, filename: 'x'),
        ]),
        throwsFormatException,
      );
      expect(
        () => c.drafts.single.withReceipt({'artifact_id': '../bad'}),
        throwsFormatException,
      );
      c.dispose();
    },
  );
  test('download authenticates and verifies bytes checksum', () async {
    final bytes = utf8.encode('download');
    server.listen((r) async {
      expect(r.uri.path, '/v1/artifacts/download/$id');
      expect(r.headers.value('authorization'), 'Bearer SECRET');
      r.response.headers.set(
        'X-Artifact-Sha256',
        sha256.convert(bytes).toString(),
      );
      r.response.add(bytes);
      await r.response.close();
    });
    expect(await repo.downloadAttachment(id), bytes);
  });
  test(
    'one-shot download is cached across concurrent taps and later saves',
    () async {
      var reads = 0;
      server.listen((r) async {
        reads++;
        r.response.write('cached');
        await r.response.close();
      });
      final results = await Future.wait([
        cachedArtifact(repo, id, directory: dir),
        cachedArtifact(repo, id, directory: dir),
      ]);
      expect(results.first, utf8.encode('cached'));
      expect(results.last, results.first);
      expect(await cachedArtifact(repo, id, directory: dir), results.first);
      expect(reads, 1);
    },
  );
  test('upload cannot accept a truncated receipt', () async {
    server.listen((r) async {
      await r.drain<void>();
      r.response.headers.contentType = ContentType.json;
      if (r.uri.path.endsWith('capabilities')) {
        r.response.write('{"features":{}}');
      } else {
        r.response.statusCode = 201;
        r.response.write(jsonEncode({'artifact_id': id, 'size_bytes': 1}));
      }
      await r.response.close();
    });
    await expectLater(
      repo.uploadAttachment(StreamAttachmentSource(() => file.openRead()), 'note.txt'),
      throwsA(
        isA<ApiException>().having(
          (e) => (e.uiMessage as UiLocal).key,
          'uiMessage.key',
          MessageKey.apiM025,
        ),
      ),
    );
  });
  test('bad download checksum rejected', () async {
    server.listen((r) async {
      r.response.headers.set('X-Artifact-Sha256', 'bad');
      r.response.write('x');
      await r.response.close();
    });
    await expectLater(
      repo.downloadAttachment(id),
      throwsA(
        isA<ApiException>().having(
          (e) => (e.uiMessage as UiLocal).key,
          'uiMessage.key',
          MessageKey.apiM026,
        ),
      ),
    );
  });
}
