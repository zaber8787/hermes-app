import 'dart:convert';
import 'dart:typed_data';

import '../platform/save_file.dart';
import 'diagnostics_store.dart';

/// Ring buffer journal for the browser tab: metadata only, ~1 MB cap, and a
/// download on export (no persistent file system without a file handle).
class MemoryDiagnosticsStore implements DiagnosticsStore {
  static const _cap = 1024 * 1024;
  final _lines = <String>[];
  int _bytes = 0;

  @override
  Future<void> append(String line) async {
    _lines.add(line);
    _bytes += line.length;
    while (_bytes > _cap && _lines.length > 1) {
      _bytes -= _lines.removeAt(0).length;
    }
  }

  @override
  Future<bool> exportSnapshot() async {
    final snapshot = utf8.encode(_lines.join());
    return (await saveBytesAs(
      'hermes-diagnostics.jsonl',
      Uint8List.fromList(snapshot),
    )).succeeded;
  }
}

DiagnosticsStore newStore(String path) => MemoryDiagnosticsStore();
