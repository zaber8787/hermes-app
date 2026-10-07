/// In-page address changes (back/forward after a hash navigation). Native
/// builds have none; web builds ride popstate/hashchange.
library;

export 'deep_link_source_native.dart'
    if (dart.library.js_interop) 'deep_link_source_web.dart';
