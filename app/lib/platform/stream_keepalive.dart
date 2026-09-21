import 'dart:async';
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
