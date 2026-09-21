import 'dart:typed_data';

import 'save_file_io.dart' if (dart.library.js_interop) 'save_file_web.dart' as impl;

/// Typed outcome of a save flow (I18N-PLAN §4.4): never a translated
/// pseudo-path. `SavedPath.path` is the raw OS path (display data),
/// `BrowserStarted` is the web truth, `SaveCancelled` the user's choice.
sealed class SaveResult {
  const SaveResult();

  /// True when something reached the user (path or browser download start).
  bool get succeeded => this is! SaveCancelled;
}

class SaveCancelled extends SaveResult {
  const SaveCancelled();
}

class SavedPath extends SaveResult {
  const SavedPath(this.path);
  final String path;
}

class BrowserStarted extends SaveResult {
  const BrowserStarted();
}

/// Save bytes under a suggested name. io: system share sheet; web: browser
/// download. Returns the typed outcome — callers never see a localized
/// string as a path.
Future<SaveResult> saveBytesAs(String name, Uint8List bytes) =>
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
