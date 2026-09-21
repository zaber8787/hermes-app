import 'dart:typed_data';

import '../../api/hermes_repository.dart' show ApiException;
import 'attachment.dart';
import 'draft_store.dart';

/// Browser drafts live in memory: they survive navigation between sessions
/// but not a reload, which is acceptable — an unsent draft would have to be
/// re-uploaded anyway, and spooling 500 MB into IndexedDB would be worse.
class WebDraftStore implements DraftStore {
  final _blobs = <String, Uint8List>{};

  @override
  Future<String> stage(Stream<List<int>> source, String key) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in source) {
      if (bytes.length + chunk.length > attachmentMaxBytes) {
        throw const ApiException('附件超過 500 MiB，請縮小檔案。');
      }
      bytes.add(chunk);
    }
    _blobs[key] = bytes.takeBytes();
    return key;
  }

  @override
  Future<void> discard(String ref) async {
    _blobs.remove(ref);
  }

  @override
  Future<AttachmentSource> open(String ref) async {
    final bytes = _blobs[ref];
    if (bytes == null) {
      throw const ApiException('附件快取已遺失，請移除後重新選取。');
    }
    return StreamAttachmentSource(() => Stream.value(bytes), bytes.length);
  }
}

DraftStore newStore() => WebDraftStore();
