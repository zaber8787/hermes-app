import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'save_file.dart';

Future<SaveResult> saveBytesAs(String name, Uint8List bytes) async {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'application/octet-stream'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = name
    ..style.display = 'none';
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  // Revoke after the browser had a chance to start the download.
  unawaited(Future.delayed(const Duration(seconds: 30), () {
    web.URL.revokeObjectURL(url);
  }));
  return const BrowserStarted();
}

/// Artifacts re-download cheaply over Tailscale; an LRU-ish memory map beats
/// persisting multi-hundred-MB blobs in IndexedDB for a private tool.
class WebByteCache implements ByteCache {
  final _entries = <String, Uint8List>{};
  final _order = <String>[];
  static const _maxEntries = 12;

  @override
  Future<Uint8List> getOrCreate(
    String key,
    Future<Uint8List> Function() load, {
    Object? root,
  }) async {
    final hit = _entries.remove(key);
    if (hit != null) {
      _order.remove(key);
      _remember(key, hit);
      return hit;
    }
    final bytes = await load();
    _remember(key, bytes);
    return bytes;
  }

  void _remember(String key, Uint8List bytes) {
    _entries[key] = bytes;
    _order.add(key);
    while (_order.length > _maxEntries) {
      final evicted = _order.removeAt(0);
      final dropped = _entries.remove(evicted);
      // 500 MB drafts would wedge the tab; keep total under ~400 MB.
      if (dropped != null && _bytesTotal() > 400 * 1024 * 1024) {
        for (final stale in _order.toList()) {
          _order.remove(stale);
          _entries.remove(stale);
          if (_bytesTotal() <= 200 * 1024 * 1024) break;
        }
      }
    }
  }

  int _bytesTotal() {
    var total = 0;
    for (final value in _entries.values) {
      total += value.length;
    }
    return total;
  }
}

ByteCache newCache() => WebByteCache();
