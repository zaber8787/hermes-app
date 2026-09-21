/// dart:io side: one app == one context, so a per-name FIFO chain inside
/// this isolate is the complete serialization guarantee.
///
/// The queue stores call-site closures and runs each one through the
/// zone captured when it was queued. Chaining through a PREVIOUS call's
/// future (prev.then(...)) is the trap this avoids: under flutter_test
/// each test body owns a private fake-async zone, and a continuation
/// attached to a future that last completed in a dead earlier zone never
/// runs again — the transaction would stall forever.
library;

import 'dart:async';

final Map<String, bool> _running = {};
final Map<String, List<void Function()>> _queues = {};

Future<T> withStoreTx<T>(String name, Future<T> Function() body) {
  final callerZone = Zone.current;
  final done = Completer<T>(); // resolves continuations in their own zones
  void start() => callerZone.run(() {
    Future<T>.microtask(body).then((v) {
      if (!done.isCompleted) done.complete(v);
      _advance(name);
    }, onError: (Object e, StackTrace s) {
      if (!done.isCompleted) done.completeError(e, s);
      _advance(name);
    });
  });
  if (_running[name] == true) {
    (_queues[name] ??= <void Function()>[]).add(start);
  } else {
    _running[name] = true; // claimed synchronously: no double start
    start();
  }
  return done.future;
}

void _advance(String name) {
  final queue = _queues[name];
  if (queue == null || queue.isEmpty) {
    _running.remove(name);
    _queues.remove(name);
    return;
  }
  queue.removeAt(0)();
}

/// io has no sibling contexts; in-process ordering is total.
bool get storeTxIsCrossTab => false;
