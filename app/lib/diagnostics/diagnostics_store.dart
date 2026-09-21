import 'diagnostics_store_io.dart'
    if (dart.library.js_interop) 'diagnostics_store_web.dart' as impl;

/// Where the metadata-only diagnostic journal lives: rotating file on devices,
/// memory ring in the browser. Never payloads, URLs, credentials or text.
abstract class DiagnosticsStore {
  Future<void> append(String line);

  /// Materialise the journal (incl. rotated half) for the user.
  /// Returns false when the user cancels the save dialog.
  Future<bool> exportSnapshot();
}

DiagnosticsStore newDiagnosticsStore(String path) => impl.newStore(path);
