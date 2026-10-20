import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../platform/save_file.dart';
import '../../l10n/app_strings.dart';
import '../../l10n/message_key.dart';

typedef ImageDownloader = Future<SaveResult> Function(String, Uint8List);

class ViewerImage {
  const ViewerImage(this.name, this.load);
  final String name;
  final Future<Uint8List> Function() load;
}

/// Scoped to one message; callbacks retain the originating repository.
class MessageGallery extends InheritedWidget {
  const MessageGallery({super.key, required this.images, required super.child});
  final Map<String, ViewerImage> images;
  static Map<String, ViewerImage>? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MessageGallery>()?.images;
  @override
  bool updateShouldNotify(MessageGallery oldWidget) =>
      images != oldWidget.images;
}

void openImageViewer(
  BuildContext context,
  String source,
  ViewerImage fallback, {
  ImageDownloader downloader = saveBytesAs,
}) {
  final gallery = MessageGallery.of(context);
  final entries = gallery?.entries.toList() ?? [];
  final index = entries.indexWhere((e) => e.key == source);
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MessageImageViewer(
        images: index < 0
            ? [fallback]
            : entries.map((e) => e.key == source ? fallback : e.value).toList(),
        initialIndex: index < 0 ? 0 : index,
        downloader: downloader,
      ),
    ),
  );
}

class MessageImageViewer extends StatefulWidget {
  const MessageImageViewer({
    super.key,
    required this.images,
    this.initialIndex = 0,
    this.downloader = saveBytesAs,
  });
  final List<ViewerImage> images;
  final int initialIndex;
  final ImageDownloader downloader;
  @override
  State<MessageImageViewer> createState() => _MessageImageViewerState();
}

class _MessageImageViewerState extends State<MessageImageViewer> {
  late final PageController _controller = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;
  final Map<int, Future<Uint8List>> _loads = {};
  bool _saving = false;
  Future<Uint8List> _load(int index) =>
      _loads.putIfAbsent(index, widget.images[index].load);
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _download() async {
    if (_saving) return;
    final index = _index;
    setState(() => _saving = true);
    var key = MessageKey.contentM004;
    try {
      final result = await widget.downloader(
        widget.images[index].name,
        await _load(index),
      );
      key = result is SaveCancelled
          ? MessageKey.downloadCancelled
          : result is BrowserStarted
          ? MessageKey.downloadBrowserStarted
          : MessageKey.contentM021;
    } catch (_) {
      /* Show a retryable localized failure. */
    }
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppStrings.of(context).resolve(key))),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        '${AppStrings.of(context).resolve(MessageKey.contentM010)} ${_index + 1}/${widget.images.length}',
      ),
      actions: [
        if (widget.images.length > 1) ...[
          IconButton(
            tooltip: '上一張',
            onPressed: _index == 0
                ? null
                : () => _controller.previousPage(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                  ),
            icon: const Icon(Icons.chevron_left),
          ),
          IconButton(
            tooltip: '下一張',
            onPressed: _index == widget.images.length - 1
                ? null
                : () => _controller.nextPage(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                  ),
            icon: const Icon(Icons.chevron_right),
          ),
        ],
        IconButton(
          tooltip: AppStrings.of(context).resolve(MessageKey.contentM011),
          onPressed: _saving ? null : _download,
          icon: Icon(_saving ? Icons.hourglass_top : Icons.download_outlined),
        ),
      ],
    ),
    body: PageView.builder(
      controller: _controller,
      itemCount: widget.images.length,
      onPageChanged: (value) => setState(() => _index = value),
      itemBuilder: (context, index) => FutureBuilder<Uint8List>(
        future: _load(index),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text(
                AppStrings.of(context).resolve(MessageKey.contentM005),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return _ImagePage(bytes: snapshot.data!);
        },
      ),
    ),
  );
}

class _ImagePage extends StatefulWidget {
  const _ImagePage({required this.bytes});
  final Uint8List bytes;
  @override
  State<_ImagePage> createState() => _ImagePageState();
}

class _ImagePageState extends State<_ImagePage> {
  final _transform = TransformationController();
  bool _zoom = false;
  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: Center(
          child: GestureDetector(
            onTap: () {
              _zoom = !_zoom;
              _transform.value = Matrix4.diagonal3Values(
                _zoom ? 2 : 1,
                _zoom ? 2 : 1,
                1,
              );
            },
            child: InteractiveViewer(
              transformationController: _transform,
              maxScale: 5,
              panEnabled: _zoom,
              child: Image.memory(
                widget.bytes,
                width: constraints.maxWidth,
                fit: BoxFit.fitWidth,
                errorBuilder: (context, error, stack) => Text(
                  AppStrings.of(context).resolve(MessageKey.contentM005),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
