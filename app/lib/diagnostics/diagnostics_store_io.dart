import 'dart:io';
import 'package:flutter/services.dart';

import '../platform/save_file.dart';
import 'diagnostics_store.dart';

class FileDiagnosticsStore implements DiagnosticsStore {
  FileDiagnosticsStore(this.path);
  final String path;

  @override
  Future<void> append(String line) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    if (await file.exists() && await file.length() >= 2 * 1024 * 1024) {
      final old = File('$path.1');
      if (await old.exists()) await old.delete();
      await file.rename(old.path);
    }
    await file.writeAsString(line, mode: FileMode.append, flush: true);
  }

  @override
  Future<bool> exportSnapshot() async {
    final file = File(path);
    final old = File('$path.1');
    final snapshot = File('${file.parent.path}/hermes-diagnostics.jsonl');
    await snapshot.writeAsString(
      '${await old.exists() ? await old.readAsString() : ''}${await file.readAsString()}',
    );
    try {
      // Android runner owns the share sheet; keep that path untouched.
      return await const MethodChannel('hermes/diagnostics')
              .invokeMethod<bool>('export', snapshot.path) ??
          false;
    } on PlatformException {
      return (await saveBytesAs(
        'hermes-diagnostics.jsonl',
        await snapshot.readAsBytes(),
      )).succeeded;
    } on MissingPluginException {
      return (await saveBytesAs(
        'hermes-diagnostics.jsonl',
        await snapshot.readAsBytes(),
      )).succeeded;
    }
  }
}

DiagnosticsStore newStore(String path) => FileDiagnosticsStore(path);
