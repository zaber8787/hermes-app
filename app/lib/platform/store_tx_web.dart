import 'dart:async';
import 'dart:js_interop';
import 'package:web/web.dart' as web;

import 'store_tx.dart';

/// Web side: same-origin tabs serialize pending-key transactions through
/// the Web Locks API when present — that is genuine CROSS-TAB serializa-
/// tion. A crashed tab's document dies and the browser releases its locks
/// with it, so takeover is just the next claim. When `navigator.locks` is
/// missing (older Safari) every call throws synchronously once, we
/// remember, and run on per-isolate chains instead — and those chains
/// serialize THIS TAB ONLY: cross-tab claims become last-writer-wins AND
/// cross-tab compare-update/compare-delete is NOT atomic (a second tab can
/// slip between this tab's reread and its remove — R2 §4.5; the old "the
/// compare ops stay safe" wording overstated this mode and is retired).
/// `storeTxIsCrossTab` stays false there exactly as before;
/// [storeTxCapability] additionally reports whether a lock was ever
/// probed at all (`unknown` before the first transaction).
bool? _haveLocks;

bool get storeTxIsCrossTab => _haveLocks ?? false;

/// PROBED capability: `unknown` until the first real transaction has
/// actually attempted `navigator.locks` — never assume, per §4.5.
StoreTxCapability get storeTxCapability => switch (_haveLocks) {
  null => StoreTxCapability.unknown,
  true => StoreTxCapability.resolvedAvailable,
  false => StoreTxCapability.unavailable,
};

Future<T> withStoreTx<T>(String name, Future<T> Function() body) async {
  if (_haveLocks ?? true) {
    late T value;
    Object? bodyError;
    StackTrace? bodyStack;
    try {
      await web.window.navigator.locks
          .request(
            'hermes.$name',
            ((web.Lock _) => () async {
                  try {
                    value = await body();
                  } catch (e, s) {
                    bodyError = e;
                    bodyStack = s;
                  }
                }().toJS)
                .toJS,
          )
          .toDart;
      if (bodyError != null) {
        Error.throwWithStackTrace(bodyError!, bodyStack ?? StackTrace.empty);
      }
      _haveLocks = true;
      return value;
    } catch (e) {
      if (bodyError != null) {
        rethrow; // the lock worked; the transaction itself failed.
      }
      _haveLocks = false; // no/broken Web Locks: degrade, never deadlock.
    }
  }
  return _chain(name, body);
}

// Same zone-safe queue as the io side (see store_tx_io's comment):
// never chain through a previous call's future object.
final Map<String, bool> _running = {};
final Map<String, List<void Function()>> _queues = {};

Future<T> _chain<T>(String name, Future<T> Function() body) {
  final callerZone = Zone.current;
  final done = Completer<T>();
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
    _running[name] = true;
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
