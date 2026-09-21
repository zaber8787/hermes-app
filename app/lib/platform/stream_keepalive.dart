import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../diagnostics/diagnostics.dart';

/// One lease per HTTP stream, including streams still waiting for headers.
/// Closing before headers arrive prevents a late open from starting a service.
class StreamKeepalive {
  StreamKeepalive(this.id);
  static const channel = MethodChannel('hermes/stream-keepalive');
  static Future<void> _operations = Future.value();
  final int id;
  bool _closed = false, _requested = false;
  Future<void> _pending = Future.value();

  static void initialize() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'error') {
        await Diagnostics.current?.record('fgs.error');
      }
    });
  }

  /// Locale mirror dispatched through the same serialized queue as start/
  /// stop, so the initial tag lands BEFORE the first stream start and a
  /// changed-language command can never interleave with start/stop.
  /// Returns success; false means "keep going, warn once" (never replays
  /// streams). Web has no such channel: skip without touching the queue.
  /// Test-only: the serialized chain is process-scoped state; between
  /// flutter_test zones a completed-but-orphaned tail would stall it.
  @visibleForTesting
  static void resetCommandQueueForTest() => _operations = Future.value();

  static Future<bool> syncLocale(String tag) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    final operation = _operations.then((_) => _setLocale(tag));
    _operations = operation.then((_) {}, onError: (_) {});
    return operation;
  }

  static Future<bool> _setLocale(String tag) async {
    // ignore: avoid_print
    print('[dbg] _setLocale running $tag');
    try {
      await channel.invokeMethod<void>('setLocale', {'tag': tag});
      unawaited(Diagnostics.current?.record('fgs.locale'));
      return true;
    } on MissingPluginException {
      // No native service side at all (tests, unsupported builds): skip
      // without warning — the notification simply does not exist here.
      return true;
    } catch (_) {
      unawaited(Diagnostics.current?.record('fgs.locale_error'));
      return false;
    }
  }

  Future<void> start() {
    if (_closed || _requested) return _pending;
    _requested = true;
    _pending = _invoke('start');
    return _pending;
  }

  Future<void> stop() {
    if (_closed) return _pending;
    _closed = true;
    if (_requested) _pending = _pending.then((_) => _invoke('stop'));
    return _pending;
  }

  Future<void> _invoke(String method) {
    // Serialize process-wide service commands, including across sessions.
    _operations = _operations.then((_) => _call(method));
    return _operations;
  }

  Future<void> _call(String method) async {
    try {
      await channel.invokeMethod<void>(method, id);
      unawaited(Diagnostics.current?.record('fgs.$method', stream: id));
    } catch (_) {
      // Notification denial/start restrictions never fail or replay chat.
      unawaited(Diagnostics.current?.record('fgs.error', stream: id));
    }
  }
}
