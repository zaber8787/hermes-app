import 'package:web/web.dart' as web;

import 'connectivity_hint.dart';

/// Web: `navigator.onLine` is read on EVERY call (no listener, no cached
/// flag — a stale true/false is exactly the bug class this seam avoids).
/// It is a HINT only: browsers report onLine=true whenever they are
/// attached to *a* network, and it says nothing about a PAST request — so
/// it may only gate whether THIS send is invoked at all (plan §1 rule 2),
/// never whether an earlier attempt delivered.
ConnectivityHint currentConnectivityHint() =>
    web.window.navigator.onLine
    ? ConnectivityHint.online
    : ConnectivityHint.offline;
