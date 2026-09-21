import 'dart:async';

import 'draft_store_io.dart' if (dart.library.js_interop) 'draft_store_web.dart'
    as impl;
import 'attachment.dart' show AttachmentSource;

/// Holds picked-but-unsent attachment bytes between sends: a spool directory
/// on dart:io devices, a memory map in the browser (drafts survive tab
/// navigation but not a reload).
abstract class DraftStore {
  /// Persist `source` under `key`; returns a local ref stored in drafts.
  Future<String> stage(Stream<List<int>> source, String key);
  Future<void> discard(String ref);
  /// Re-openable source for a stored ref; throws ApiException when gone.
  Future<AttachmentSource> open(String ref);
}

DraftStore newDraftStore() => impl.newStore();

/// Something the user picked in the media sheet (io: gallery asset; web:
/// never — the web sheet just forwards to the file picker).
class PickedMedia {
  PickedMedia(this.filename, this.source);
  final String filename;
  final AttachmentSource source;
}
