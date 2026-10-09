import 'dart:async';

import '../settings/local_store.dart';
import 'run_link.dart';

/// NOTIF2 B2: ONE deep-link ingress for the whole app. Web feeds it the
/// live address changes (its launch URL is stashed by main() as before);
/// native feeds it the app_links stream, which carries the COLD intent and
/// every warm one. The ingress never drops a parsed link: before a router
/// exists (login pending) the href waits in the existing one-spend stash,
/// and while a route is busy the next link is QUEUED, not discarded. URLs
/// are never permanently deduped — tapping the same notification again
/// means navigating again.
class DeepLinkIngress {
  LocalStore? _store;
  StreamSubscription<String>? _sub;
  Future<void> Function(RunLink)? _router;
  final List<RunLink> _queued = [];
  bool _routing = false;

  /// Subscribe EARLY (from main(), right after the store exists): a cold
  /// Android intent must not wait for the first widget to mount.
  void start(Stream<String> links, LocalStore store) {
    _store = store;
    unawaited(_sub?.cancel() ?? Future<void>.value());
    _sub = links.listen(
      observe,
      // a broken source stream changes NOTHING (cold links stay in the
      // stash path; the panel keeps working) — it must never crash the app.
      onError: (Object _) {},
      cancelOnError: false,
    ); // app_links: initial event rides the stream
  }

  void observe(String href) {
    RunLink? link;
    try {
      link = RunLink.tryParse(href);
    } on Object {
      link = null;
    }
    if (link == null) return; // unparseable / secret-bearing: honest nothing
    if (_router == null) {
      unawaited(_store?.stashDeepLink(href)); // login handoff, spent ONCE
      return;
    }
    deliver(link);
  }

  /// A link from any non-stream source (the stash handoff) enters the SAME
  /// serialized queue as the stream.
  void deliver(RunLink link) {
    if (_router == null) {
      unawaited(_store?.stashDeepLink(link.toUrl()));
      return;
    }
    _queued.add(link);
    _pump();
  }

  /// The SessionsPage seam: attached while the session list lives. Attaching
  /// spends any stashed link through the same queue.
  void attach(Future<void> Function(RunLink) router) {
    _router = router;
    final raw = _store?.peekDeepLink();
    if (raw != null && _store != null) {
      unawaited(_store!.clearDeepLink()); // spent ONCE — never a surprise jump
      final link = RunLink.tryParse(raw);
      if (link != null) _queued.add(link);
    }
    _pump();
  }

  void detach() => _router = null;

  void dispose() {
    unawaited(_sub?.cancel() ?? Future<void>.value());
    _sub = null;
    _router = null;
    _queued.clear();
    _routing = false;
  }

  void _pump() {
    final router = _router;
    if (_routing || router == null || _queued.isEmpty) return;
    _routing = true;
    final link = _queued.removeAt(0);
    unawaited(() async {
      try {
        await router(link);
      } on Object {
        // a failed route changes NOTHING; the next link still runs
      } finally {
        _routing = false;
        _pump();
      }
    }());
  }
}

/// The app-wide singleton: main() starts it, SessionsPage attaches it.
final DeepLinkIngress deepLinkIngress = DeepLinkIngress();
