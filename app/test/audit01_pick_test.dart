import 'dart:async';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/features/attachments/attachment.dart';
import 'package:hermes_app/features/attachments/attachment_controller.dart';
import 'package:hermes_app/features/attachments/draft_store.dart';
import 'package:hermes_app/features/settings/local_store.dart';

/// AUDIT-01 regression: pick() → _stage() used to re-enter the busy-guarded
/// pickSource() and silently no-op. These tests drive the REAL entry point
/// (FilePicker) end to end with SINGLE-SUBSCRIPTION streams (web semantics).

base class _Picked extends PlatformFile {
  _Picked(this.name, this._streamFactory);
  @override
  final String name;
  final Stream<List<int>> Function() _streamFactory;
  int streamOpens = 0;

  @override
  Stream<Uint8List> readAsByteStream() {
    streamOpens++;
    return _streamFactory().map(
      (chunk) => chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
    );
  }

  @override
  Uri get uri => Uri.parse('fake:///$name');
  @override
  XFile get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => null;
  @override
  Future<int> length() => Future.value(0);
  @override
  Future<Uint8List> readAsBytes() =>
      Future.error(UnimplementedError());
}

class _FakePicker extends FilePickerPlatform
    with MockPlatformInterfaceMixin {
  _FakePicker(this.result);
  Future<List<PlatformFile>> Function() result;
  int calls = 0;
  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) {
    calls++;
    return result();
  }
}

/// Memory DraftStore; the bytes map is the "blob" copy under test.
class MemBlobs implements DraftStore {
  final blobs = <String, List<int>>{};
  final failStage = <String>{};
  int stageSeq = 0;
  @override
  Future<String> stage(Stream<List<int>> source, String key) async {
    final bytes = <int>[];
    await for (final chunk in source) {
      bytes.addAll(chunk);
    }
    if (failStage.contains(key)) throw StateError('stage broken');
    blobs[key] = bytes;
    return 'blob:$key';
  }

  @override
  Future<void> discard(String ref) async =>
      blobs.remove(ref.replaceFirst('blob:', ''));

  @override
  Future<AttachmentSource> open(String ref) async {
    final bytes = blobs[ref.replaceFirst('blob:', '')]!;
    return StreamAttachmentSource(() => Stream.value(bytes), bytes.length);
  }
}

/// One-shot stream factory — a second listener would hang/throw, mirroring
/// the web FileReader stream contract.
Stream<List<int>> oneShot(List<int> bytes) =>
    Stream.fromFuture(Future.value(bytes));

Stream<List<int>> failingAfter(List<int> bytes) {
  final c = StreamController<List<int>>();
  c.add(bytes);
  c.addError(const _Gone());
  unawaited(c.close());
  return c.stream;
}

class _Gone implements Exception {
  const _Gone();
}

void main() {
  late LocalStore store;
  late MemBlobs blobs;
  late AttachmentController controller;
  late _FakePicker picker;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    blobs = MemBlobs();
    controller = AttachmentController(
      HermesRepository('http://fake.invalid', 'k'),
      store,
      's1',
      blobs: blobs,
    );
  });

  tearDown(() {
    FilePickerPlatform.instance = MethodChannelBackedDefault();
    controller.dispose();
  });

  Future<void> pick(List<PlatformFile> Function() files) async {
    picker = _FakePicker(() async => files());
    FilePickerPlatform.instance = picker;
    await controller.pick();
  }

  test('pick() stages every selected file: draft, blob and prefs each get one',
      () async {
    final picked = _Picked('report.pdf', () => oneShot([1, 2, 3, 4]));
    await pick(() => [picked]);
    expect(controller.error, isNull);
    expect(controller.drafts, hasLength(1), reason: 'draft landed');
    expect(blobs.blobs.values.single, [1, 2, 3, 4], reason: 'blob landed');
    // prefs copy survives a controller rebuild:
    final reloaded = AttachmentController(
      HermesRepository('http://fake.invalid', 'k'),
      store,
      's1',
      blobs: blobs,
    );
    expect(reloaded.drafts.single.filename, 'report.pdf');
    reloaded.dispose();
    // Single-subscription respected: opened EXACTLY once (no size-then-read).
    expect(picked.streamOpens, 1);
    expect(controller.busy, isFalse);
  });

  test('two picked files both stage under ONE busy window', () async {
    final a = _Picked('a.bin', () => oneShot([1]));
    final b = _Picked('b.bin', () => oneShot([2, 2]));
    await pick(() => [a, b]);
    expect(controller.drafts.map((d) => d.filename), ['a.bin', 'b.bin']);
    expect(blobs.blobs.length, 2);
    expect(a.streamOpens, 1);
    expect(b.streamOpens, 1);
  });

  test('cancel (empty result) is a clean no-op', () async {
    await pick(() => []);
    expect(controller.drafts, isEmpty);
    expect(controller.error, isNull);
    expect(controller.busy, isFalse);
    expect(blobs.blobs, isEmpty);
  });

  test('second file failing mid-read keeps the first and surfaces an error',
      () async {
    final good = _Picked('good.bin', () => oneShot([9, 9]));
    final bad = _Picked('bad.bin', () => failingAfter([1]));
    await pick(() => [good, bad]);
    expect(controller.drafts.map((d) => d.filename), ['good.bin']);
    expect(blobs.blobs.values.single, [9, 9]);
    expect(controller.error, isNotNull);
    expect(controller.busy, isFalse);
  });

  test('oversize stream is rejected while spooling (no re-open needed)',
      () async {
    Stream<List<int>> hugeStream() async* {
      // Chunked so peak memory stays ~64 MiB while crossing the cap.
      var sent = 0;
      while (sent <= attachmentMaxBytes) {
        final chunk = List.filled(1 << 26, 0);
        sent += chunk.length;
        yield chunk;
      }
    }

    final huge = _Picked('huge.bin', hugeStream);
    await pick(() => [huge]);
    expect(controller.drafts, isEmpty);
    expect(blobs.blobs, isEmpty);
    expect((controller.error! as UiLocal).key, MessageKey.attachmentTooLarge);
  });
}

/// Restore a token-valid default so test order can't poison later suites.
class MethodChannelBackedDefault extends FilePickerPlatform
    with MockPlatformInterfaceMixin {}
