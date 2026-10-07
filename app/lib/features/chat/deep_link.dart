/// STEERWEB R7 + 01412FIX F5 (M6): the deep-link CONSUMER. Parsing alone is
/// not navigation — this module turns an exact RunLink into a decided route:
/// exact identity against the account's session list (never a fuzzy match),
/// hidden/deleted/wrong-profile all end in an honest refusal, and a link
/// captured before login is stashed once and spent once.
library;

import '../../models/session.dart';
import 'run_link.dart';

enum DeepLinkStatus { opened, sessionNotFound, sessionHidden }

class DeepLinkRoute {
  const DeepLinkRoute(this.status, this.session, this.link);
  final DeepLinkStatus status;
  final Session? session;
  final RunLink link;

  bool get opened => status == DeepLinkStatus.opened;
}

/// EXACT identity resolution. A session that is absent (deleted OR another
/// profile — indistinguishable from the client, and deliberately never told
/// apart) or explicitly hidden (per the caller's ONE effective-hidden rule)
/// is refused; nothing is ever guessed.
DeepLinkRoute resolveDeepLink(
  RunLink link,
  List<Session> sessions, {
  bool Function(Session)? hiddenOf,
}) {
  for (final s in sessions) {
    if (s.id == link.sessionId) {
      if (hiddenOf != null ? hiddenOf(s) : s.hidden == true) {
        return DeepLinkRoute(DeepLinkStatus.sessionHidden, null, link);
      }
      return DeepLinkRoute(DeepLinkStatus.opened, s, link);
    }
  }
  return DeepLinkRoute(DeepLinkStatus.sessionNotFound, null, link);
}

/// Captures the launch URL (web: the address bar incl. the #/chat fragment;
/// native Uri.base is a file path and NEVER parses). Returns the stashed raw
/// URL when the link is real, else null.
String? captureLaunchLink() {
  final href = Uri.base.toString();
  return RunLink.tryParse(href) != null ? href : null;
}
