/// AUDIT-21 (D1): one per-session presence ledger for the whole app — the
/// single place allowed to answer "is someone watching / opening this
/// session?".
///
/// Deliberately a plain SYNCHRONOUS registry, not riverpod state: the
/// navigation dedupe guard must run before ANY await — `markRead`'s await
/// in particular. That await was the window through which a fast second
/// tap slipped past every async guard and stacked a second ChatPage for
/// the same sid (whose pop-dispose then cut the SSE the first page was
/// still watching). Batch C's LRU pin rule reads this same ledger.
class ChatViewers {
  ChatViewers._();

  static final _viewers = <String, int>{};
  static final _opening = <String>{};

  /// ChatPage calls this from initState (before any await).
  static void acquire(String sid) {
    _viewers[sid] = (_viewers[sid] ?? 0) + 1;
    _lastUsed[sid] = ++_clock;
  }

  /// ChatPage calls this from dispose. True means this release took the
  /// session from exactly one viewer down to zero — the caller owns the
  /// `detach()` decision and only a 1→0 transition may cut the stream.
  /// A never-tracked sid also reports true, so pages mounted without
  /// going through open() (tests, future entry points) keep today's
  /// "pop detaches" semantics instead of silently never detaching.
  static bool release(String sid) {
    _lastUsed[sid] = ++_clock; // LRU recency: "last seen on screen"
    final n = (_viewers[sid] ?? 0) - 1;
    if (n <= 0) {
      _viewers.remove(sid);
      return true;
    }
    _viewers[sid] = n;
    return false;
  }

  static int count(String sid) => _viewers[sid] ?? 0;

  /// open() claims the sid SYNCHRONOUSLY before touching storage. False =
  /// the session is already open, or another tap's push is mid-flight —
  /// in both cases the second tap must not navigate again.
  static bool claimOpening(String sid) => _opening.add(sid);

  // ---- AUDIT-16 (batch C): alive ledger + LRU recency -------------------
  // ChatController builds register and dispose un-register, giving the
  // eviction pass the set of providers that currently retain a controller.
  // Recency uses a monotonic counter (not the clock): same-millisecond
  // visits must still order deterministically.
  static final _owner = <String, Object>{};
  static final _lastUsed = <String, int>{};
  static int _clock = 0;

  /// The ledger is OWNED by the controller instance that registered: a
  /// deferred dispose of a replaced/evicted controller can never delete
  /// a freshly rebuilt resident's entry.
  static void register(String sid, Object self) {
    _owner[sid] = self;
    _lastUsed[sid] = ++_clock;
  }

  static void unregister(String sid, Object self) {
    if (_owner.containsKey(sid) && !identical(_owner[sid], self)) return;
    _owner.remove(sid);
    _lastUsed.remove(sid);
  }

  static int get aliveCount => _owner.length;

  /// Registered sessions no page is viewing and no open() is claiming,
  /// least-recently-used first — the eviction candidates. A session with
  /// a running turn stays OUTSIDE this set's decision (the evictor
  /// double-checks busy before dropping anything).
  static List<String> idleResidents() {
    final idle = [
      for (final sid in _owner.keys)
        if (count(sid) == 0 && !_opening.contains(sid)) sid,
    ];
    idle.sort((a, b) => (_lastUsed[a] ?? 0).compareTo(_lastUsed[b] ?? 0));
    return idle;
  }

  /// Called once the claim's route has been pushed AND popped (or the
  /// open was abandoned) — by then a successful push has already run the
  /// page's acquire(), so visibility coverage is continuous.
  static void releaseOpening(String sid) => _opening.remove(sid);

  static bool isOpening(String sid) => _opening.contains(sid);

  /// Test-only isolation between cases.
  static void reset() {
    _viewers.clear();
    _opening.clear();
    _owner.clear();
    _lastUsed.clear();
  }
}
