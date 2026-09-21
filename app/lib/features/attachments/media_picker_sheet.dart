import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../l10n/app_strings.dart';
import '../../l10n/message_key.dart';
import '../../l10n/ui_message.dart';

/// Telegram-style media picker: bottom sheet full of recent images/videos
/// thumbnails; tapping one returns its AssetEntity for upload. "其他檔案"
/// hands control back so the caller can open the system file picker instead.
class MediaPickerSheet {
  MediaPickerSheet._();

  static Future<AssetEntity?> show(
    BuildContext context, {
    VoidCallback? onPickOther,
  }) {
    return showModalBottomSheet<AssetEntity>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        builder: (context, scrollController) => _MediaGrid(
          scrollController: scrollController,
          onPickOther: onPickOther == null
              ? null
              : () {
                  Navigator.pop(context);
                  onPickOther();
                },
        ),
      ),
    );
  }

  /// Test seam: the grid behind the sheet with an injectable [MediaSource] so
  /// permission transitions are reproducible without the platform plugin.
  @visibleForTesting
  static Widget debugGrid({
    required ScrollController scrollController,
    VoidCallback? onPickOther,
    required MediaSource source,
  }) => _MediaGrid(
    scrollController: scrollController,
    onPickOther: onPickOther,
    source: source,
  );
}

/// Permission + asset access, wrapped so tests can drive every transition
/// (denied→authorized, limited→authorized, error→success) deterministically.
@visibleForTesting
class MediaPermission {
  const MediaPermission({required this.hasAccess, this.isLimited = false});
  final bool hasAccess, isLimited;
}

@visibleForTesting
abstract class MediaSource {
  Future<MediaPermission> requestPermission();
  Future<List<AssetEntity>> getRange(int start, int end);
  Future<void> openSetting();
  Future<void> presentLimited();
}

class _PhotoSource implements MediaSource {
  @override
  Future<MediaPermission> requestPermission() async {
    final p = await PhotoManager.requestPermissionExtend();
    return MediaPermission(hasAccess: p.hasAccess, isLimited: p.isLimited);
  }

  @override
  Future<List<AssetEntity>> getRange(int start, int end) =>
      PhotoManager.getAssetListRange(
        start: start,
        end: end,
        type: RequestType.common,
      );

  @override
  Future<void> openSetting() async => PhotoManager.openSetting();

  @override
  Future<void> presentLimited() async => PhotoManager.presentLimited();
}

class _MediaGrid extends StatefulWidget {
  const _MediaGrid({
    required this.scrollController,
    this.onPickOther,
    this.source,
  });
  final ScrollController scrollController;
  final VoidCallback? onPickOther;
  final MediaSource? source;

  @override
  State<_MediaGrid> createState() => _MediaGridState();
}

class _MediaGridState extends State<_MediaGrid> {
  static const _pageSize = 300;
  late final MediaSource _source = widget.source ?? _PhotoSource();
  List<AssetEntity> _assets = const [];
  bool _loading = true;
  bool _loadingMore = false, _hasMore = true;
  UiMessage? _error;
  bool _granted = true, _limited = false;

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    final pos = widget.scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 600) _loadMore();
  }

  // AUDIT-02: every exit closes the spinner and resets granted/limited/error
  // from THIS run's permission result, so recovery (denied/limited/error →
  // authorized) never inherits a stale state and the permission UI is
  // reachable instead of an eternal spinner.
  Future<void> _load() async {
    var granted = false;
    var limited = false;
    try {
      final permission = await _source.requestPermission();
      granted = permission.hasAccess;
      limited = permission.isLimited;
      if (!granted) {
        if (mounted) {
          setState(() {
            _granted = false;
            _limited = false;
            _error = null;
            _assets = const [];
            _hasMore = false;
            _loading = false; // AUDIT-02: close loading on denial
          });
        }
        return;
      }
      // Root query across the whole library (all folders, newest first).
      // Listing albums and taking albums[0] only covers one bucket on Android.
      final batch = await _source.getRange(0, _pageSize);
      if (!mounted) return;
      setState(() {
        _granted = true;
        _limited = limited;
        _error = null;
        _assets = batch;
        _hasMore = batch.length == _pageSize;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _granted = granted;
        _limited = limited;
        _error = const UiMessage.local(MessageKey.galleryM002);
        _assets = const [];
        _hasMore = false;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore || _error != null || !_granted) {
      return;
    }
    setState(() => _loadingMore = true);
    try {
      final start = _assets.length;
      final batch = await _source.getRange(start, start + _pageSize);
      if (!mounted) return;
      final seen = _assets.map((a) => a.id).toSet();
      setState(() {
        _assets = [..._assets, ...batch.where((a) => !seen.contains(a.id))];
        _hasMore = batch.length == _pageSize;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Text(
                strings.resolve(MessageKey.galleryM003),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              if (widget.onPickOther != null)
                TextButton.icon(
                  onPressed: widget.onPickOther,
                  icon: const Icon(Icons.folder_open_outlined, size: 18),
                  label: Text(strings.resolve(MessageKey.galleryM004)),
                ),
            ],
          ),
        ),
        Expanded(
          child: Column(
            children: [
              if (_granted && _limited)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.info_outline, size: 18),
                  title: Text(strings.resolve(MessageKey.galleryM005)),
                  trailing: TextButton(
                    onPressed: () async {
                      if (defaultTargetPlatform == TargetPlatform.android) {
                        await _source.openSetting();
                      } else {
                        await _source.presentLimited();
                      }
                      await _load();
                    },
                    child: Text(strings.resolve(MessageKey.galleryM006)),
                  ),
                ),
              Expanded(child: _body(context, scheme)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _body(BuildContext context, ColorScheme scheme) {
    final strings = AppStrings.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (!_granted) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.photo_library_outlined, size: 40, color: scheme.outline),
            const SizedBox(height: 8),
            Text(strings.resolve(MessageKey.galleryM007)),
            TextButton(
              onPressed: () =>
                  _source.openSetting().then((_) => _load()),
              child: Text(strings.resolve(MessageKey.galleryM008)),
            ),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(strings.render(_error!)),
            TextButton(
              onPressed: _load,
              child: Text(strings.resolve(MessageKey.commonRetry)),
            ),
          ],
        ),
      );
    }
    return GridView.builder(
      controller: widget.scrollController,
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ),
      // Last cell is a loading sentinel while more pages remain; scrolling
      // near the bottom also prefetches (_onScroll).
      itemCount: _assets.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _assets.length) {
          return const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final asset = _assets[index];
        return GestureDetector(
          onTap: () => Navigator.pop(context, asset),
          child: _Thumb(asset: asset),
        );
      },
    );
  }
}

class _Thumb extends StatefulWidget {
  const _Thumb({required this.asset});
  final AssetEntity asset;

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  late final Future<Uint8List?> _bytes = widget.asset.thumbnailDataWithSize(
    const ThumbnailSize.square(200),
    quality: 70,
  );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (context, snap) => Stack(
        fit: StackFit.expand,
        children: [
          if (snap.connectionState == ConnectionState.done &&
              snap.data != null)
            Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true)
          else
            ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest),
          if (widget.asset.type == AssetType.video)
            const Positioned(
              right: 3,
              bottom: 3,
              child: Icon(Icons.play_circle_fill,
                  size: 16, color: Colors.white70),
            ),
        ],
      ),
    );
  }
}
