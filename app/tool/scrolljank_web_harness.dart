// Build: flutter build web --no-pub --target tool/scrolljank_web_harness.dart
// Serve build/web over HTTP; inspect #scrolljank-result and browser console.
import 'dart:ui' as ui;
import 'dart:convert';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;
import 'package:hermes_app/features/chat/message_content.dart';
import '../test/support/localized_app.dart';
import '../test/support/scrolljank_jpeg.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final bytes = scrolljankJpeg();
  final inlineKey = GlobalKey();
  final boundaryKey = GlobalKey();
  final result = web.HTMLDivElement()..id = 'scrolljank-result';
  web.document.body!.append(result);
  void record(String message) {
    result.textContent = '${result.textContent}\n$message';
    debugPrint(message);
  }

  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  try {
    record('METADATA ${descriptor.width}x${descriptor.height}');
  } catch (error) {
    record('METADATA ERROR $error');
  } finally {
    descriptor.dispose();
    buffer.dispose();
  }
  final provider = ResizeImage(MemoryImage(bytes), width: 512, height: 384);
  final stream = provider.resolve(ImageConfiguration.empty);
  late ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      record('RESIZE PASS ${info.image.width}x${info.image.height}');
      info.dispose();
      stream.removeListener(listener);
    },
    onError: (Object error, StackTrace? stack) {
      record('RESIZE FAIL $error');
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
  runApp(
    localizedWrap(
      RepaintBoundary(
        key: boundaryKey,
        child: Column(
          children: [
            const Text('4000x3000 JPEG: ResizeImage / production inline'),
            SizedBox(
              width: 480,
              height: 250,
              child: Image(
                image: provider,
                frameBuilder: (context, child, frame, sync) {
                  if (frame != null) record('DIRECT FRAME PASS');
                  return child;
                },
                errorBuilder: (context, error, stack) {
                  record('DIRECT FRAME FAIL $error');
                  return const Text('FAIL');
                },
              ),
            ),
            SizedBox(
              key: inlineKey,
              width: 480,
              child: MessageImageMemory(bytes),
            ),
          ],
        ),
      ),
    ),
  );
  // Capture the production subtree after real browser frames, independent of
  // the direct ResizeImage probe. Download links keep evidence exportable.
  await Future<void>.delayed(const Duration(seconds: 5));
  var rendered = false;
  void inspect(Element element) {
    final object = element.renderObject;
    if (object is RenderImage && object.image != null) {
      rendered = true;
      record(
        'INLINE FRAME PASS ${object.image!.width}x${object.image!.height}',
      );
    }
    element.visitChildren(inspect);
  }

  final inlineContext = inlineKey.currentContext;
  if (inlineContext != null && inlineContext.mounted) {
    inspect(inlineContext as Element);
  }
  if (!rendered) record('INLINE FRAME FAIL no decoded raster after 5 seconds');
  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final screenshot = await boundary.toImage();
  try {
    final png = await screenshot.toByteData(format: ui.ImageByteFormat.png);
    if (png != null) {
      final link = web.HTMLAnchorElement()
        ..download = 'scrolljank-render.png'
        ..href =
            'data:image/png;base64,${base64Encode(png.buffer.asUint8List())}'
        ..textContent = 'Download rendered screenshot';
      web.document.body!.append(link);
    }
  } finally {
    screenshot.dispose();
  }
  final log = web.HTMLAnchorElement()
    ..download = 'scrolljank-render-result.txt'
    ..href =
        'data:text/plain;charset=utf-8,${Uri.encodeComponent(result.textContent ?? '')}'
    ..textContent = 'Download rendering result';
  web.document.body!.append(log);
}
