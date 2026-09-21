import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'diagnostics_store.dart';

/// Metadata only: never persist payloads, URLs, credentials or exception text.
class Diagnostics {
  Diagnostics(this.store, this.version);
  static const channel = MethodChannel('hermes/diagnostics');
  static Diagnostics? current;
  final DiagnosticsStore store;
  final String version;
  Future<void> _pending = Future.value();
  String? failure;
  static Future<void> initialize() async {
    try {
      if (kIsWeb) {
        current = Diagnostics(
          newDiagnosticsStore('unused'),
          const String.fromEnvironment('APP_VERSION', defaultValue: 'web'),
        );
      } else {
        final info = await channel.invokeMapMethod<String, String>('info');
        current = Diagnostics(
          newDiagnosticsStore('${info!['directory']}/sse.jsonl'),
          info['version']!,
        );
      }
      await current!.record('app.start');
    } catch (_) {
      /* Diagnostics must not prevent startup. */
    }
  }

  Future<void> record(String kind, {String? event, int? stream}) {
    final line =
        '${jsonEncode({'at': DateTime.now().toUtc().toIso8601String(), 'version': version, 'kind': kind, 'event': ?event, 'stream': ?stream})}\n';
    _pending = _pending
        .then((_) => store.append(line))
        .catchError((Object _) {
          failure = '診斷檔寫入失敗';
        });
    return _pending;
  }

  Future<bool> export() async {
    await _pending;
    if (failure != null) throw StateError(failure!);
    return store.exportSnapshot();
  }
}
