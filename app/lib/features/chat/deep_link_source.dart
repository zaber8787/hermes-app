/// In-page address changes (back/forward after a hash navigation). Native
/// builds have none; web builds ride popstate/hashchange.
/// NOTIF2 B2 adds `incomingLinks()`: the platform's deep-link ingress —
/// the intent stream on native, the same live address stream on web.
library;

export 'deep_link_source_native.dart'
    if (dart.library.js_interop) 'deep_link_source_web.dart';
