import 'store_tx_io.dart'
    if (dart.library.js_interop) 'store_tx_web.dart' as impl;

/// Serializes the read-modify-write transactions on shared LocalStore keys
/// (AUDIT-21 D2: the pending-turn claim / compare-update / clear trio,
/// R2: plus the attempt journal and local settlement).
///
/// On dart:io devices the app is a single context, so chaining per-name in
/// this isolate is a complete guarantee (`storeTxIsCrossTab` reports false
/// simply because there is no other tab to be cross-tab against).
///
/// On web the primitive is the Web Locks API (`navigator.locks`), which the
/// target browsers (Chrome/Edge 69+, Firefox 96+, Safari 15.4+) provide and
/// which is honored ACROSS same-origin tabs; a crashed tab's locks die with
/// it, so nothing can deadlock a takeover. If a browser lacks Web Locks the
/// web implementation falls back to per-isolate chaining, which is a
/// SINGLE-TAB serialization only: cross-tab claims degrade to
/// last-writer-wins AND cross-tab compare-and-set (claim / compare-update /
/// compare-delete) is NOT atomic — a second tab can slip a write in between
/// this tab's reread and its remove (R2 §4.5 / A10; the old "compare ops
/// stay safe" wording overstated the no-locks mode and is retired).
/// `storeTxCapability` reports which mode is in effect, and it stays
/// `unknown` until the first real transaction has probed `navigator.locks`.
Future<T> withStoreTx<T>(String name, Future<T> Function() body) =>
    impl.withStoreTx(name, body);

bool get storeTxIsCrossTab => impl.storeTxIsCrossTab;

/// Whether the store transaction serialization is cross-context in fact,
/// as PROBED (never assumed): `unknown` only before web's first
/// transaction has actually attempted a lock.
enum StoreTxCapability { unknown, resolvedAvailable, unavailable }

StoreTxCapability get storeTxCapability => impl.storeTxCapability;
