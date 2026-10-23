import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/features/chat/message_content.dart';
import 'package:hermes_app/features/chat/image_viewer.dart';
import 'package:hermes_app/providers.dart';

import 'support/localized_app.dart';

class _DecodeBinding extends AutomatedTestWidgetsFlutterBinding {
  int decodes = 0;
  @override
  Future<ui.Codec> instantiateImageCodecWithSize(
    ui.ImmutableBuffer buffer, {
    ui.TargetImageSizeCallback? getTargetSize,
  }) async {
    final codec = await super.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: getTargetSize,
    );
    decodes++;
    return codec;
  }
}

class _Repo extends HermesRepository {
  _Repo(this.bytes) : super('https://fixture.invalid', 'fixture');
  final Uint8List bytes;
  @override
  Future<Uint8List> downloadServerFile(String path) async => bytes;
  @override
  Future<Uint8List> downloadAttachment(String id) async => bytes;
}

Future<Uint8List> _png(int width, int height, [int color = 0xff123456]) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(Color(color), BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

Future<ui.Image> _resolve(ImageProvider provider) async {
  final done = Completer<ui.Image>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, synchronous) {
      done.complete(info.image.clone());
      info.dispose();
      stream.removeListener(listener);
    },
    onError: (Object error, StackTrace? stack) {
      done.completeError(error, stack);
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
  return done.future.timeout(const Duration(seconds: 5));
}

Future<ResizeImage> _mount(
  WidgetTester t,
  Widget child, {
  double width = 480,
  double dpr = 1,
  HermesRepository? repo,
}) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [if (repo != null) repositoryProvider.overrideWithValue(repo)],
      child: localizedWrap(
        MediaQuery(
          data: MediaQueryData(
            size: const Size(800, 600),
            devicePixelRatio: dpr,
          ),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: SingleChildScrollView(child: child),
            ),
          ),
        ),
      ),
    ),
  );
  await t.pump();
  await t.pump();
  // Real engine metadata/codec futures do not advance with virtual pump time.
  for (var i = 0; i < 100 && find.byType(Image).evaluate().isEmpty; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await t.pump();
  }
  return t.widget<Image>(find.byType(Image).last).image as ResizeImage;
}

void main() {
  final binding = _DecodeBinding();
  setUp(() {
    binding.imageCache.clear();
    binding.imageCache.clearLiveImages();
    resetDataUrlCache();
    binding.decodes = 0;
  });

  testWidgets('three sources resolve bounded pixels; remount keeps provider keys', (
    t,
  ) async {
    final bytes = (await t.runAsync(() => _png(4000, 3000)))!;
    final repo = _Repo(bytes);
    addTearDown(repo.close);
    final sources = <Widget>[
      const ServerPathImage('/bounded.png'),
      MessageImage('data:image/png;base64,${base64Encode(bytes)}'),
      const MessageImage(
        'https://fixture.invalid/v1/artifacts/download/0123456789abcdef0123456789abcdef',
        key: ValueKey('artifact'),
      ),
    ];
    for (final child in sources) {
      final provider = await _mount(t, child, repo: repo, dpr: 2);
      final key = await provider.obtainKey(ImageConfiguration.empty);
      final decoded = (await t.runAsync(() => _resolve(provider)))!;
      expect(decoded.width, lessThanOrEqualTo(960));
      expect(decoded.width * decoded.height, lessThanOrEqualTo(1536 * 1536));
      expect(decoded.width / decoded.height, closeTo(4 / 3, .01));
      // ignore: avoid_print
      print(
        'BOUNDED source=${child.runtimeType} ${decoded.width}x${decoded.height}',
      );
      decoded.dispose();
      await t.pumpWidget(const SizedBox());
      final remount = await _mount(t, child, repo: repo, dpr: 2);
      expect(await remount.obtainKey(ImageConfiguration.empty), key);
      await t.pumpWidget(const SizedBox());
    }
  });

  testWidgets('DPR 1/2/3, narrow/wide resize, buckets and extreme DPR cap', (
    t,
  ) async {
    final bytes = (await t.runAsync(() => _png(4000, 3000)))!;
    for (final dpr in [1.0, 2.0, 3.0, 100.0]) {
      final a = await _mount(
        t,
        MessageImageMemory(bytes),
        width: 300,
        dpr: dpr,
      );
      final decoded = (await t.runAsync(() => _resolve(a)))!;
      final expectedWidth = dpr == 100 ? 1536 : (300 * dpr / 64).ceil() * 64;
      final expectedHeight = dpr == 100 ? 1152 : (225 * dpr / 64).ceil() * 64;
      final factor = [
        expectedWidth / 4000,
        expectedHeight / 3000,
      ].reduce((a, b) => a < b ? a : b);
      expect(decoded.width, (4000 * factor).floor());
      expect(decoded.height, (3000 * factor).floor());
      expect(t.getSize(find.byType(MessageImageMemory)).height, 233);
      decoded.dispose();
      final nearby = await _mount(
        t,
        MessageImageMemory(bytes),
        width: 301,
        dpr: dpr,
      );
      expect(
        await nearby.obtainKey(ImageConfiguration.empty),
        await a.obtainKey(ImageConfiguration.empty),
      );
      final wide = await _mount(
        t,
        MessageImageMemory(bytes),
        width: 480,
        dpr: dpr,
      );
      final large = (await t.runAsync(() => _resolve(wide)))!;
      expect(large.width, greaterThanOrEqualTo(expectedWidth));
      expect(large.width * large.height, lessThanOrEqualTo(1536 * 1536));
      large.dispose();
    }
  });

  testWidgets(
    'landscape portrait extreme and small images preserve natural geometry',
    (t) async {
      for (final size in [
        const Size(4000, 3000),
        const Size(3000, 4000),
        const Size(4000, 1),
        const Size(1, 4000),
        const Size(16, 12),
      ]) {
        final bytes = (await t.runAsync(
          () => _png(size.width.toInt(), size.height.toInt()),
        ))!;
        final provider = await _mount(
          t,
          MessageImageMemory(bytes),
          width: 200,
          dpr: 3,
        );
        final before = t.getSize(find.byType(FittedBox).last);
        final decoded = (await t.runAsync(() => _resolve(provider)))!;
        await t.pump();
        expect(t.getSize(find.byType(FittedBox).last), before);
        expect(before, Size(200, 200 * size.height / size.width));
        final raster = t.renderObject<RenderBox>(find.byType(Image));
        final fitted = t.renderObject<RenderBox>(find.byType(FittedBox).last);
        final painted = MatrixUtils.transformRect(
          raster.getTransformTo(fitted),
          Offset.zero & raster.size,
        );
        expect(
          painted.width / painted.height,
          closeTo(size.width / size.height, .000001),
        );

        expect(decoded.width, inInclusiveRange(1, size.width.toInt()));
        expect(decoded.height, inInclusiveRange(1, size.height.toInt()));
        expect(decoded.width * decoded.height, lessThanOrEqualTo(1536 * 1536));
        if (size.width == 16) {
          expect(
            Size(decoded.width.toDouble(), decoded.height.toDouble()),
            size,
          );
        }
        decoded.dispose();
        final fixed = await _mount(
          t,
          MessageImage('data:image/png;base64,${base64Encode(bytes)}'),
        );
        final actual = (await t.runAsync(() => _resolve(fixed)))!;
        expect(t.getSize(find.byType(FittedBox).last).height, 250);
        expect(
          t.widget<FittedBox>(find.byType(FittedBox).last).fit,
          BoxFit.contain,
        );
        expect(actual.width * actual.height, lessThanOrEqualTo(1536 * 1536));
        actual.dispose();
      }
    },
  );

  testWidgets('animated GIF metadata and bounded codec retain multiple frames', (
    t,
  ) async {
    // Two distinct frames, generated as a self-contained GIF fixture.
    final bytes = base64Decode(
      'R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAgACAAAIBgABCAQQEAAh+QQACgAAACwAAAAAAgACAIEA/wAAAAAAAAAAAAAIBgABCAQQEAA7',
    );
    final provider = await _mount(t, MessageImageMemory(bytes), width: 200);
    ui.Image? completed;
    await t.runAsync(() async {
      _resolve(provider).then((image) => completed = image);
    });
    for (var i = 0; i < 100 && completed == null; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(completed, isNotNull);
    final image = completed!;
    expect(image.width, 2);
    expect(image.height, 2);
    image.dispose();
    final frameCount = await t.runAsync(() async {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: provider.width,
        targetHeight: provider.height,
        allowUpscaling: false,
      );
      try {
        return codec.frameCount;
      } finally {
        codec.dispose();
      }
    });
    expect(frameCount, 2);
    expect(t.getSize(find.byType(FittedBox).last), const Size(200, 200));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets(
    'viewer loads original bytes and independently decodes full resolution',
    (t) async {
      final bytes = (await t.runAsync(() => _png(4000, 3000)))!;
      final inline = await _mount(t, MessageImageMemory(bytes), width: 300);
      final small = (await t.runAsync(() => _resolve(inline)))!;
      expect(small.width, lessThan(4000));
      small.dispose();
      await t.tap(find.byType(Image));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await t.pump();
      final viewer = t.widget<MessageImageViewer>(
        find.byType(MessageImageViewer),
      );
      expect(await viewer.images.single.load(), same(bytes));
      final full = t
          .widget<Image>(
            find.descendant(
              of: find.byType(MessageImageViewer),
              matching: find.byType(Image),
            ),
          )
          .image;
      expect(full, isA<MemoryImage>());
      final decoded = (await t.runAsync(() => _resolve(full)))!;
      expect(
        Size(decoded.width.toDouble(), decoded.height.toDouble()),
        const Size(4000, 3000),
      );
      decoded.dispose();
    },
  );

  testWidgets('invalid bytes use existing localized failure fallback', (
    t,
  ) async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    await t.pumpWidget(localizedWrap(MessageImageMemory(bytes)));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump();
    expect(find.byType(Image), findsNothing);
    expect(find.text('The image could not be loaded'), findsOneWidget);
    expect(t.takeException(), isNull);
    // A recognized header with corrupt raster data must also reach fallback.
    final valid = (await t.runAsync(() => _png(40, 30)))!;
    await _mount(t, MessageImageMemory(Uint8List.sublistView(valid, 0, 24)));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump();
    expect(find.text('The image could not be loaded'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('20 distinct 4K images round-trip warm decoded cache working set', (
    t,
  ) async {
    final originals = <Uint8List>[];
    for (var i = 0; i < 20; i++) {
      originals.add(
        (await t.runAsync(() => _png(4000, 3000, 0xff000000 + i * 1000)))!,
      );
    }
    var peak = 0;
    for (final bytes in originals) {
      final provider = await _mount(
        t,
        MessageImageMemory(bytes),
        width: 480,
        dpr: 2,
      );
      final decoded = (await t.runAsync(() => _resolve(provider)))!;
      expect(
        Size(decoded.width.toDouble(), decoded.height.toDouble()),
        const Size(960, 720),
      );
      decoded.dispose();
      peak = binding.imageCache.currentSizeBytes > peak
          ? binding.imageCache.currentSizeBytes
          : peak;
      await t.pumpWidget(const SizedBox());
    }
    final cold = binding.decodes;
    for (final bytes in originals.reversed) {
      final provider = await _mount(
        t,
        MessageImageMemory(bytes),
        width: 480,
        dpr: 2,
      );
      final decoded = (await t.runAsync(() => _resolve(provider)))!;
      decoded.dispose();
    }
    expect(cold, 20);
    expect(binding.decodes, cold);
    expect(peak, 20 * 960 * 720 * 4);
    expect(binding.imageCache.pendingImageCount, 0);
    // ignore: avoid_print
    print(
      'BOUNDED 20x4K cold=$cold return=${binding.decodes - cold} size=960x720 '
      'peakRGBA=$peak originalRGBA=${20 * 4000 * 3000 * 4} '
      'live=${binding.imageCache.liveImageCount} pending=${binding.imageCache.pendingImageCount}',
    );
    await t.pumpWidget(const SizedBox());
    binding.imageCache.clear();
    binding.imageCache.clearLiveImages();
    final start = binding.decodes;
    var fullPeak = 0;
    for (final bytes in [...originals, ...originals.reversed]) {
      final decoded = (await t.runAsync(() => _resolve(MemoryImage(bytes))))!;
      expect(decoded.width, 4000);
      expect(decoded.height, 3000);
      decoded.dispose();
      if (binding.imageCache.currentSizeBytes > fullPeak) {
        fullPeak = binding.imageCache.currentSizeBytes;
      }
    }
    expect(binding.decodes - start, 38);
    expect(fullPeak, 2 * 4000 * 3000 * 4);
    // ignore: avoid_print
    print(
      'FULLRES 20x4K roundTripDecodes=${binding.decodes - start} '
      'peakRGBA=$fullPeak cacheLimit=${binding.imageCache.maximumSizeBytes}',
    );
  });
}
