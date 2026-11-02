/// TASK-WSAPP §2/§4: the client outbox for WS-routed sends.
///
/// Every WS send is written here BEFORE the first network byte; its key is
/// the `prompt.submit` `submission_id`, so a resend after a lost answer or a
/// reconnect is idempotent at the owner (key = ticket subject, session id,
/// submission id; the bridge mints every ticket for one fixed subject). An
/// entry leaves only on a receipt or a definitive refusal. While the link is
/// down entries wait, and each time it comes back they are submitted in
/// insertion order, one at a time, so the order the user typed is the order
/// the owner admits.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'gateway_ws.dart';

class WsOutboxEntry {
  const WsOutboxEntry({
    required this.key,
    required this.sid,
    required this.text,
    required this.createdAt,
  });
  final String key, sid, text;
  final DateTime createdAt;

  Json toJson() => {
    'key': key,
    'sid': sid,
    'text': text,
    'at': createdAt.toUtc().toIso8601String(),
  };

  static WsOutboxEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['key'], sid = raw['sid'], text = raw['text'];
    if (key is! String || sid is! String || text is! String) return null;
    return WsOutboxEntry(
      key: key,
      sid: sid,
      text: text,
      createdAt:
          DateTime.tryParse('${raw['at']}') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}

/// Where the outbox survives an app restart (LocalStore prefs in the app,
/// a map in tests).
abstract class WsOutboxPersistence {
  String? read();
  Future<void> write(String? value);
}

/// A submit the bridge or the owner refused for good (never retried).
class WsRefusal {
  const WsRefusal(this.entry, this.error);
  final WsOutboxEntry entry;
  final GatewayRpcError error;
}

class WsDelivery {
  const WsDelivery(this.entry, this.receipt);
  final WsOutboxEntry entry;
  final Json receipt;
  String? get admissionId => receipt['admission_id'] as String?;
}

class WsOutbox extends ChangeNotifier {
  WsOutbox(
    this.ws,
    this._persistence, {
    DateTime Function()? now,
    this.retryEvery = const Duration(seconds: 5),
  }) : _now = now ?? DateTime.now {
    _entries.addAll(_load());
    _linkSub = ws.linkChanges.listen((usable) {
      if (usable) unawaited(flush());
    });
  }

  final GatewayWs ws;
  final WsOutboxPersistence _persistence;
  final DateTime Function() _now;

  /// The link can stay up while the owner behind it cannot take a write (a
  /// first upstream dial that never reached ready sends no `bridge.upstream`
  /// at all), so a flush stopped that way tries again on its own.
  final Duration retryEvery;
  Timer? _retry;
  final _entries = <WsOutboxEntry>[];
  late final StreamSubscription<bool> _linkSub;
  final _deliveries = StreamController<WsDelivery>.broadcast();
  final _refusals = StreamController<WsRefusal>.broadcast();
  Future<void> _chain = Future.value();
  bool _disposed = false;
  static final _rand = Random.secure();

  Stream<WsDelivery> get deliveries => _deliveries.stream;
  Stream<WsRefusal> get refusals => _refusals.stream;

  List<WsOutboxEntry> get entries => List.unmodifiable(_entries);
  bool hasPending(String sid) => _entries.any((e) => e.sid == sid);

  /// Entries of [sid] waiting for a flush, without the one a live turn is
  /// submitting itself right now.
  List<WsOutboxEntry> queued(String sid) => _entries
      .where((e) => e.sid == sid && !_claimed.contains(e.key))
      .toList(growable: false);

  List<WsOutboxEntry> _load() {
    final raw = _persistence.read();
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return [for (final e in list) ?WsOutboxEntry.fromJson(e)];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _save() => _persistence.write(
    _entries.isEmpty
        ? null
        : jsonEncode([for (final e in _entries) e.toJson()]),
  );

  static String newKey() {
    final bytes = List<int>.generate(12, (_) => _rand.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'wsapp-$hex';
  }

  /// Persist [text] for [sid]; the returned entry's key is its idempotency
  /// key. With [claim] a flush passes it by until [submit] has answered, so
  /// the live turn that enqueued it gets its own receipt.
  Future<WsOutboxEntry> enqueue(
    String sid,
    String text, {
    bool claim = false,
  }) async {
    final entry = WsOutboxEntry(
      key: newKey(),
      sid: sid,
      text: text,
      createdAt: _now(),
    );
    if (claim) _claimed.add(entry.key);
    _entries.add(entry);
    await _save();
    if (!_disposed) notifyListeners();
    return entry;
  }

  Future<void> _remove(WsOutboxEntry entry) async {
    _entries.removeWhere((e) => e.key == entry.key);
    await _save();
    if (!_disposed) notifyListeners();
  }

  Future<T> _serialized<T>(Future<T> Function() body) {
    final done = Completer<T>();
    _chain = _chain.then((_) async {
      try {
        done.complete(await body());
      } catch (e, s) {
        done.completeError(e, s);
      }
    });
    return done.future;
  }

  /// Submit one entry now (behind any submit already in flight). Throws
  /// [WsUnavailable] (entry kept, resent on reconnect) or [GatewayRpcError]
  /// (definitive refusal, entry dropped). The caller owns the answer, so
  /// neither lands on [deliveries]/[refusals].
  Future<WsDelivery> submit(WsOutboxEntry entry) {
    _claimed.add(entry.key);
    return _serialized(() => _submitOne(entry)).whenComplete(() {
      _claimed.remove(entry.key);
      if (!_disposed) notifyListeners();
    });
  }

  /// Entries a live turn is submitting itself; a flush passes them by so
  /// the turn gets its own receipt (and with it, its admission's events).
  final _claimed = <String>{};

  Future<WsDelivery> _submitOne(WsOutboxEntry entry) async {
    if (!_entries.any((e) => e.key == entry.key)) {
      // Already delivered by a flush that ran first: never submit twice
      // from this client (the owner would dedupe it anyway).
      throw const WsUnavailable();
    }
    if (!ws.connected) throw const WsUnavailable();
    Json receipt;
    try {
      receipt = await _submitWire(entry);
    } on GatewayRpcError catch (e) {
      if (e.outcomeUnknown) throw const WsUnavailable(outcomeUnknown: true);
      await _remove(entry);
      rethrow;
    }
    await _remove(entry);
    return WsDelivery(entry, receipt);
  }

  Future<Json> _submitWire(WsOutboxEntry entry) async {
    Future<Json> once() async {
      await ws.ensureResumed(entry.sid);
      return ws.call('prompt.submit', {
        'session_id': entry.sid,
        'submission_id': entry.key,
        'text': entry.text,
      });
    }

    try {
      return await once();
    } on GatewayRpcError catch (e) {
      // The bridge forgot this connection's resume (it answers the owner's
      // own refusal shape): resume afresh once, same submission id.
      if (e.data?['detail'] != 'resume_required') rethrow;
      await ws.resume(entry.sid);
      return once();
    }
  }

  /// Submit every waiting entry in order; stops at the first one the link
  /// cannot carry (the next reconnect, or the retry timer while the link
  /// stays up, resumes from there).
  Future<void> flush() => _serialized(() async {
    _retry?.cancel();
    _retry = null;
    for (final entry in List.of(_entries)) {
      if (_disposed || !ws.connected) return;
      if (_claimed.contains(entry.key)) continue;
      try {
        final delivery = await _submitOne(entry);
        if (!_deliveries.isClosed) _deliveries.add(delivery);
      } on GatewayRpcError catch (e) {
        // Dropped for good; later entries still go.
        if (!_refusals.isClosed) _refusals.add(WsRefusal(entry, e));
      } catch (_) {
        if (!_disposed) {
          _retry = Timer(retryEvery, () => unawaited(flush()));
        }
        return;
      }
    }
  });

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    unawaited(_linkSub.cancel());
    unawaited(_deliveries.close());
    unawaited(_refusals.close());
    super.dispose();
  }
}
