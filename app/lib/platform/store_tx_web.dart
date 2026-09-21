import 'dart:async';
import 'dart:js_interop';
import 'package:web/web.dart' as web;

/// Web side: same-origin tabs serialize pending-key transactions through
/// the Web Locks API when present. A crashed tab's document dies and the
/// browser releases its locks with it — takeover is then just the next
/// claim. When `navigator.locks` is missing (older Safari) every call
/// throws synchronously once, we remember, and run on per-isolate chains
/// instead: compare-and-update/clear stay safe, claims become
/// last-writer-wins (storeTxIsCrossTab == false says so out loud).
bool? _haveLocks;

bool get storeTxIsCrossTab => _haveLocks ?? false;

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
