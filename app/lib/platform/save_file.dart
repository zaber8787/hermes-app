import 'dart:typed_data';

import 'save_file_io.dart' if (dart.library.js_interop) 'save_file_web.dart' as impl;

/// Save bytes under a suggested name. io: system share sheet; web: browser
/// download. Returns null when the user cancels.
Future<String?> saveBytesAs(String name, Uint8List bytes) =>
    impl.saveBytesAs(name, bytes);

/// Re-openable byte cache for downloaded artifacts, keyed by the caller.
/// io keeps files under the app support dir (or `root` override in tests);
/// web keeps an in-memory map and ignores `root`.
abstract class ByteCache {
  Future<Uint8List> getOrCreate(
    String key,
    Future<Uint8List> Function() load, {
    Object? root,
  });
}

ByteCache newByteCache() => impl.newCache();
