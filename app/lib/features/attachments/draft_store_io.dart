import 'dart:io';
import 'package:path_provider/path_provider.dart';

import '../../api/hermes_repository.dart' show ApiException;
import 'attachment.dart';
import 'draft_store.dart';

class IoDraftStore implements DraftStore {
  Future<Directory> _dir() async {
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}/attachment-drafts').create(recursive: true);
  }

  @override
  Future<String> stage(Stream<List<int>> source, String key) async {
    final dir = await _dir();
    final file = File('${dir.path}/$key');
    final sink = file.openWrite();
    try {
      await for (final chunk in source) {
        sink.add(chunk);
      }
      await sink.flush();
    } catch (_) {
      await sink.close();
      await file.delete();
      rethrow;
    }
    await sink.close();
    return file.path;
  }

  @override
  Future<void> discard(String ref) async {
    try {
      await File(ref).delete();
    } catch (_) {
      /* Already gone. */
    }
  }

  @override
  Future<AttachmentSource> open(String ref) async {
    final file = File(ref);
    if (!await file.exists()) {
      throw const ApiException('附件快取已遺失，請移除後重新選取。');
    }
    return StreamAttachmentSource(() => file.openRead());
  }
}

DraftStore newStore() => IoDraftStore();
