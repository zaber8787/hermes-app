import 'store_tx_io.dart'
    if (dart.library.js_interop) 'store_tx_web.dart' as impl;

/// Serializes the read-modify-write transactions on shared LocalStore keys
/// (AUDIT-21 D2: the pending-turn claim / compare-update / clear trio).
///
/// On dart:io devices the app is a single context, so chaining per-name in
/// this isolate is a complete guarantee (`storeTxIsCrossTab` reports false
/// simply because there is no other tab to be cross-tab against).
///
/// On web the primitive is the Web Locks API (`navigator.locks`), which the
/// target browsers (Chrome/Edge 69+, Firefox 96+, Safari 15.4+) provide and
/// which is honored ACROSS same-origin tabs; a crashed tab's locks die with
/// it, so nothing can deadlock a takeover. If a browser lacks Web Locks the
/// web implementation falls back to per-isolate chaining and
/// `storeTxIsCrossTab` becomes false: the compare-and-update/clear ops
/// remain safe (a mismatched token is never applied), but the CLAIM itself
/// degrades to last-writer-wins — the weaker guarantee is stated here and
/// surfaced by the flag instead of silently pretending otherwise.
Future<T> withStoreTx<T>(String name, Future<T> Function() body) =>
    impl.withStoreTx(name, body);

bool get storeTxIsCrossTab => impl.storeTxIsCrossTab;
