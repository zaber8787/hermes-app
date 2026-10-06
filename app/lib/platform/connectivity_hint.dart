import 'connectivity_hint_io.dart'
    if (dart.library.js_interop) 'connectivity_hint_web.dart' as impl;

/// OFFLINE-SEND R3 §5.2: a HINT, never evidence. The only sanctioned use is
/// the app's OWN decision not to invoke a dispatch (blockedBeforeDispatch).
/// A hint value can NEVER deny delivery of an attempt that already
/// dispatched, and it must never classify a past POST (plan §1 red lines).
enum ConnectivityHint { online, offline, unknown }

/// Current connectivity hint. Web reads `navigator.onLine` afresh on EVERY
/// call (no listener, no cache); dart:io devices have no reliable cheap
/// signal and always answer [ConnectivityHint.unknown] — unknown is
/// deliberately NOT offline (no short-circuit, the normal send path runs).
ConnectivityHint currentConnectivityHint() => impl.currentConnectivityHint();
