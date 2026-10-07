/// STEERWEB R7: the canonical deep link. Server pushes (ntfy click) and the
/// notification panel speak ONE URL shape:
///
///   `https://<entry>/#/chat?session=<sid>&run=<rid>&event=<eid>[&request=<id>]`
///
/// Parsing is EXACT: only the HTTPS(S) canonical form is trusted, ids are
/// percent-decoded VERBATIM, and a key, token or topic in a link is a hard
/// parse failure — a secret never rides a navigable URL, in either direction.
library;

class RunLink {
  const RunLink({
    required this.sessionId,
    this.runId,
    this.eventId,
    this.requestId,
  });

  final String sessionId;
  final String? runId;
  final String? eventId;
  final String? requestId;

  static const _secretMarkers = ['key=', 'token=', 'apikey=', 'topic=', 'Bearer'];

  static RunLink? tryParse(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    if (uri.scheme != 'https' && uri.scheme != 'http') return null;
    final fragment = uri.fragment;
    if (!fragment.startsWith('/chat')) return null;
    final q = fragment.indexOf('?');
    final query = q < 0 ? const <String, String>{} : Uri.splitQueryString(fragment.substring(q + 1));
    for (final raw in [url, uri.path, uri.query, fragment]) {
      for (final marker in _secretMarkers) {
        if (raw.contains(marker)) return null; // secrets are a PARSE FAILURE
      }
    }
    final sid = query['session'];
    if (sid == null || sid.trim().isEmpty) return null;
    return RunLink(
      sessionId: sid,
      runId: _id(query['run']),
      eventId: _id(query['event']),
      requestId: _id(query['request']),
    );
  }

  static String? _id(String? v) => (v == null || v.trim().isEmpty) ? null : v;

  String toUrl({String base = 'https://hermes.invalid'}) {
    final q = <String>[
      'session=${Uri.encodeComponent(sessionId)}',
      if (runId != null) 'run=${Uri.encodeComponent(runId!)}',
      if (eventId != null) 'event=${Uri.encodeComponent(eventId!)}',
      if (requestId != null) 'request=${Uri.encodeComponent(requestId!)}',
    ];
    return '$base/#/chat?${q.join("&")}';
  }

  @override
  String toString() =>
      'RunLink(session:${sessionId.length > 8 ? sessionId.substring(0, 8) : sessionId})';
}
