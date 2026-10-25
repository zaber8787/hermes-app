import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../settings/local_store.dart';
import 'run_link.dart';

enum DeepLinkRouteOutcome { opened, permanentMiss, temporaryFailure }

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
  final ValueNotifier<RunLink?> pendingRetryNotifier = ValueNotifier(null);
  RunLink? get pendingRetry => pendingRetryNotifier.value;

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
    // APK-EXIT (2026-10-24): LINK-EXIT2 made the app claim the fileserver
    // port (:8443) so chat links stay in-app — but that also captured the
    // update APK links: tapping one in a notification opened the app, the
    // path parsed to no route, and the download never started. A file
    // artifact is not a route — hand it to the browser (which knows how
    // to download and install) and leave the routing queue untouched.
    if (_isFileArtifact(href)) {
      unawaited(_openExternally(href));
      return;
    }
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
    attachWithOutcome((link) async {
      await router(link);
      return DeepLinkRouteOutcome.opened;
    });
  }

  void attachWithOutcome(
    Future<DeepLinkRouteOutcome> Function(RunLink) router,
  ) {
    _router = (link) async {
      final outcome = await router(link);
      if (outcome == DeepLinkRouteOutcome.temporaryFailure) {
        pendingRetryNotifier.value = link;
      }
    };
    final raw = _store?.peekDeepLink();
    if (raw != null && _store != null) {
      unawaited(_store!.clearDeepLink()); // spent ONCE — never a surprise jump
      final link = RunLink.tryParse(raw);
      if (link != null) _queued.add(link);
    }
    _pump();
  }

  /// Only a user action requeues a failed route; network recovery/reattach
  /// never opens a different page behind the user's back.
  void retryPending() {
    final link = pendingRetry;
    if (link == null || _router == null) return;
    pendingRetryNotifier.value = null;
    _queued.insert(0, link);
    _pump();
  }

  void detach() {
    _router = null;
  }

  static bool _isFileArtifact(String href) {
    final uri = Uri.tryParse(href);
    if (uri == null) return false;
    final path = uri.path.toLowerCase();
    return path.endsWith('.apk') || path.endsWith('.zip');
  }

  static Future<void> _openExternally(String href) async {
    // Same verified-domain dodge as chat links: ACTION_VIEW on our own
    // domain resolves back to THIS activity, so pin the browser natively
    // first and fall through to url_launcher.
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        final opened = await const MethodChannel(
          'hermes/browser',
        ).invokeMethod<bool>('openExternally', {'url': href});
        if (opened == true) return;
      } catch (_) {
        // fall through to url_launcher
      }
    }
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      // No browser at all: an honest no-op beats a crash.
    }
  }

  void dispose() {
    unawaited(_sub?.cancel() ?? Future<void>.value());
    _sub = null;
    _router = null;
    _queued.clear();
    pendingRetryNotifier.value = null;
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
        pendingRetryNotifier.value = link;
      } finally {
        _routing = false;
        _pump();
      }
    }());
  }
}

/// The app-wide singleton: main() starts it, SessionsPage attaches it.
final DeepLinkIngress deepLinkIngress = DeepLinkIngress();
