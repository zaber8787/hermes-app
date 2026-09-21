// Opt-in live integration; uses the shipped repository/parser/model unchanged.
// Does not run flutter test/analyze/build. Only probe-created sessions are mutated.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/transport.dart';
import 'package:hermes_app/features/chat/live_turn.dart';
import 'package:hermes_app/models/message.dart';
import 'runtime_config.dart';
import 'package:hermes_app/models/session.dart';

String stamp() => DateTime.now().toUtc().toIso8601String();
void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

class AuditPort implements HttpPort {
  AuditPort(this.audit);
  final List<Json> audit;
  final HttpPort inner = newHttpPort();
  @override
  Future<PortResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Stream<List<int>>? body,
    int? contentLength,
    Future<void>? abortTrigger,
    Duration? headersTimeout,
  }) async {
    final record = <String, dynamic>{
      'at': stamp(),
      'method': method,
      'url': uri.toString(),
      'authorization': 'Bearer <REDACTED>',
    };
    audit.add(record);
    try {
      final response = await inner.send(
        method,
        uri,
        headers: headers,
        body: body,
        contentLength: contentLength,
        abortTrigger: abortTrigger,
        headersTimeout: headersTimeout,
      );
      record['status'] = response.statusCode;
      return response;
    } catch (e) {
      record['error'] = '$e';
      rethrow;
    }
  }

  @override
  void close() => inner.close();
}

Future<({int status, String body})> rawRequest(
  AuditPort port,
  String method,
  String url, {
  Json? body,
  Map<String, String>? headers,
}) async {
  final response = await port.send(
    method,
    Uri.parse(url),
    headers: {...?headers, if (body != null) 'content-type': 'application/json'},
    body: body == null ? null : Stream.value(utf8.encode(jsonEncode(body))),
  );
  final text = await utf8.decoder.bind(response.stream).join();
  return (status: response.statusCode, body: text);
}

Future<void> main(List<String> args) async {
  final reconnectOnly = args.contains('--only-reconnect');
  // Canonical config (ENVHYGIENE §3.1): base URL and key from ONE file;
  // missing values fail BEFORE any network call, and nothing is printed.
  final cfg = RuntimeConfig();
  final key = cfg.apiKey();
  final base = cfg.liveBaseUrl();
  final audit = <Json>[];
  final result = <String, dynamic>{
    'started_at': stamp(),
    'base': base,
    'layer':
        'real server + unchanged app repository/parser/models; no Android device',
    'scope': reconnectOnly ? 'reconnect-only' : 'full',
    'requests': audit,
    'steps': <String, dynamic>{},
    'created_sessions': <String>[],
    'cleanup': <Json>[],
  };
  final steps = result['steps'] as Json;
  final created = result['created_sessions'] as List<String>;
  final repo = HermesRepository(base, key, port: AuditPort(audit));
  final setup = AuditPort(audit);
  final output = File(
    Platform.environment['P1_WALKTHROUGH_JSON'] ??
        '../logs/p1/integration-walkthrough.json',
  );
  void save() {
    output.parent.createSync(recursive: true);
    output.writeAsStringSync(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(result).replaceAll(key, '<REDACTED>'),
    );
  }

  Future<Json> raw(
    String method,
    String path, {
    Json? body,
    int status = 200,
  }) async {
    final response = await rawRequest(
      setup,
      method,
      '$base$path',
      body: body,
      headers: {'authorization': 'Bearer $key'},
    ).timeout(const Duration(seconds: 610));
    save();
    require(
      response.status == status,
      '$method $path: HTTP ${response.status}, expected $status',
    );
    return Map<String, dynamic>.from(jsonDecode(response.body));
  }

  Future<String> create(String label) async {
    final response = await raw(
      'POST',
      '/api/sessions',
      body: {'title': 'P1 walkthrough $label'},
      status: 201,
    );
    final sid = response['session']['id'] as String;
    created.add(sid);
    save();
    return sid;
  }

  Future<void> step(String name, Future<Json> Function() action) async {
    stdout.writeln('${stamp()} START $name');
    try {
      final evidence = await action();
      steps[name] = {'status': 'passed', ...evidence};
      stdout.writeln(
        '${stamp()} PASS $name ${jsonEncode(evidence).replaceAll(key, '<REDACTED>')}',
      );
    } catch (e) {
      steps[name] = {'status': 'failed', 'error': '$e'};
      stdout.writeln(
        '${stamp()} FAIL $name ${'$e'.replaceAll(key, '<REDACTED>')}',
      );
    }
    save();
  }

  Future<Json> turn(String sid, String input, {String? control}) async {
    final live = LiveTurn();
    final events = <Json>[];
    var acted = false;
    var localStopAccepted = false;
    await for (final event in repo.chat(sid, input)) {
      live.apply(event, sid);
      events.add({'at': stamp(), 'type': event.type, 'payload': event.json});
      if (!acted &&
          control != null &&
          event.type == 'tool.started' &&
          event.json['tool_name'] == 'terminal' &&
          textOf(event.json['args']).contains('sleep')) {
        acted = true;
        require(
          live.runId != null,
          'Missing run.started mapping before tool event',
        );
        await Future<void>.delayed(const Duration(seconds: 2));
        if (control == 'stop') {
          await repo.stop(live.runId!);
          localStopAccepted = true;
        } else {
          await repo.steer(
            live.runId!,
            '停止剩下的 sleep，立即只回覆 P1_STEER_CONFIRMED，不要再呼叫工具。',
          );
        }
      }
    }
    final histories = await repo.messages(sid);
    require(
      live.runId != null && live.completed,
      'No run mapping or run.completed',
    );
    if (control != null) {
      require(acted, '$control was not exercised during sleep');
    }
    if (control == 'steer') {
      require(
        live.finalText?.contains('P1_STEER_CONFIRMED') == true,
        'Steer output not confirmed',
      );
    }
    // Full completion payloads are retained for retrospective final/narration review.
    (result['turns'] ??= <Json>[]).add({
      'session_id': sid,
      'input': input,
      'events': events,
    });
    final counts = <String, int>{};
    for (final event in events) {
      counts.update(event['type'] as String, (n) => n + 1, ifAbsent: () => 1);
    }
    return {
      'session_id': sid,
      'run_id': live.runId,
      'events': counts,
      'final': live.finalText,
      'completed': live.completed,
      'tools': live.tools.length,
      'progress_did_not_add_tools':
          live.tools.length == (counts['tool.started'] ?? 0),
      'history_count': histories.length,
      'local_stop_accepted': localStopAccepted,
      'input_persisted': histories.any(
        (m) => m.role == 'user' && m.content == input,
      ),
    };
  }

  List<Session> sessions = [];
  List<Skill> skills = [];
  String? chatSid;
  const longInput =
      '這是 API 控制測試。請依序用 terminal 呼叫六次 sleep 10，總共約60秒，每次等完成後才呼叫下一次，不要背景執行；全部完成後回 P1_LONG_DONE。';
  try {
    await step('01_connection_settings', () async {
      await repo.checkCapabilities();
      require(await repo.health(), 'Health check failed');
      final invalid = HermesRepository(
        base,
        'p1-intentionally-invalid',
        port: AuditPort(audit),
      );
      var rejects = false;
      try {
        await invalid.checkCapabilities();
      } on ApiException catch (e) {
        rejects = e.status == 401;
      } finally {
        invalid.close();
      }
      require(rejects, 'Invalid key not rejected as 401');
      return {
        'capabilities': 'compatible',
        'health': true,
        'invalid_key_status': 401,
      };
    });
    if (!reconnectOnly) {
      await step('02_sessions_refresh_and_skills', () async {
        sessions = await repo.sessions();
        skills = await repo.skills();
        require(sessions.isNotEmpty && skills.isNotEmpty, 'Empty lists');
        require(
          sessions.map((s) => s.id).toSet().length == sessions.length,
          'Duplicate sessions',
        );
        require(
          List.generate(
            sessions.length - 1,
            (i) => sessions[i].activity >= sessions[i + 1].activity,
          ).every((e) => e),
          'Activity order incorrect',
        );
        final refreshed = await repo.sessions();
        final refreshedSkills = await repo.skills();
        return {
          'sessions': sessions.length,
          'skills': skills.length,
          'refresh_sessions': refreshed.length,
          'refresh_skills': refreshedSkills.length,
          'unique_ids': true,
          'recent_activity_descending': true,
        };
      });
      await step('03_history_upward_pagination_and_projection', () async {
        final candidates = [...sessions]
          ..sort((a, b) => b.count.compareTo(a.count));
        require(candidates.isNotEmpty, 'No real sessions');
        final sid = candidates.first.id;
        var offset = 0;
        var merged = <Message>[];
        final pageSizes = <int>[];
        while (true) {
          final page = await repo.messages(sid, offset: offset);
          pageSizes.add(page.length);
          merged = mergeMessages(merged, page);
          offset += page.length;
          if (page.length < 200) break;
        }
        final baseline = await repo.messages(sid, limit: 500);
        require(
          merged.map((m) => m.id).toSet().length == merged.length,
          'Duplicate messages',
        );
        require(
          jsonEncode(
                merged
                    .skip(merged.length > 500 ? merged.length - 500 : 0)
                    .map((m) => m.id)
                    .toList(),
              ) ==
              jsonEncode(baseline.map((m) => m.id).toList()),
          'Latest baseline differs from merged history',
        );
        final counts = <String, int>{};
        var hidden = 0;
        final sampled = <String>[];
        for (final s in candidates.take(3)) {
          final rawMessages = await repo.messages(s.id, limit: 500);
          final entries = projectMessages(rawMessages);
          final hiddenIds = rawMessages
              .where((m) => m.displayKind == 'hidden')
              .map((m) => m.id)
              .toSet();
          hidden += hiddenIds.length;
          require(
            !entries.any((e) => hiddenIds.contains(e.message.id)),
            'Hidden row rendered',
          );
          for (final e in entries) {
            counts.update(e.kind.name, (n) => n + 1, ifAbsent: () => 1);
          }
          sampled.add(s.id);
        }
        return {
          'session_id': sid,
          'page_sizes': pageSizes,
          'unique_rows': merged.length,
          'baseline_500_matches': true,
          'sample_sessions': sampled,
          'display_entry_counts': counts,
          'hidden_rows_omitted': hidden,
        };
      });
      await step('04_stream_and_completion_projection', () async {
        chatSid = await create('chat');
        final evidence = await turn(
          chatSid!,
          '這是介面串流驗證。請用 terminal 執行 printf SMOKE_OK，最後只回覆 SMOKE_OK。',
        );
        require((evidence['tools'] as int) > 0, 'No tool observed');
        require(evidence['input_persisted'] == true, 'User input missing');
        return evidence;
      });
      await step('05_skill_autocomplete_rewrite_roundtrip', () async {
        require(chatSid != null, 'No test chat session');
        final selected = skills.firstWhere((s) => s.name == 'grill-me');
        final rewritten = rewriteSkills(
          '/${selected.name} 這是API介面管線測試，僅載入skill後回覆 P1_SKILL_OK，不要開始審問，不要讀其他專案或修改檔案。',
          skills,
        );
        require(
          rewritten.startsWith('[用戶明確 invoke skill：grill-me。'),
          'Contract rewrite mismatch',
        );
        final evidence = await turn(chatSid!, rewritten);
        require(
          evidence['input_persisted'] == true,
          'Rewritten skill input not persisted',
        );
        return {
          'autocomplete_match': selected.name,
          'rewritten': rewritten,
          ...evidence,
        };
      });
      await step('06_stop_and_session_reuse', () async {
        final sid = await create('stop');
        final stopped = await turn(sid, longInput, control: 'stop');
        require(stopped['local_stop_accepted'] == true, 'Stop not accepted');
        final reused = await turn(sid, '不要呼叫工具，只回覆 P1_REUSABLE。');
        require(
          textOf(reused['final']).contains('P1_REUSABLE'),
          'Stopped session not reusable',
        );
        return {
          'stop': stopped,
          'reuse': reused,
          'note':
              'Live repository control verified; UI stop persistence covered by existing controller tests, not re-run here.',
        };
      });
      await step('07_steer', () async {
        final sid = await create('steer');
        return turn(sid, longInput, control: 'steer');
      });
    }
    await step('08_disconnect_history_reconciliation', () async {
      final sid = await create('disconnect');
      final disconnected = HermesRepository(
        base,
        key,
        port: AuditPort(audit),
      );
      final live = LiveTurn();
      var dropped = false;
      final before = audit.length;
      try {
        await for (final event in disconnected.chat(
          sid,
          '請用 terminal 執行 sleep 10，完成後只回覆 P1_RECOVERED。',
        )) {
          live.apply(event, sid);
          if (event.type == 'assistant.completed') {
            dropped = true;
            disconnected
                .close(); // Lose transport before relying on run.completed.
            break;
          }
        }
      } catch (_) {
        require(dropped, 'Disconnect happened before the deliberate cut');
      } finally {
        disconnected.close();
      }
      require(dropped, 'No deliberate connection cut');
      final delays = <int>[];
      var persisted = false;
      for (final seconds in [1, 2, 4, 8, 16, 30]) {
        delays.add(seconds);
        await Future<void>.delayed(Duration(seconds: seconds));
        try {
          final history = await repo.messages(sid);
          persisted = projectMessages(history).any(
            (e) =>
                e.kind == EntryKind.finalReply &&
                e.message.content == live.finalText,
          );
          if (persisted) break;
        } catch (_) {
          /* Retry the read only. */
        }
      }
      final posts = audit
          .skip(before)
          .where(
            (r) =>
                r['method'] == 'POST' &&
                Uri.parse(r['url'] as String).path.endsWith('/chat/stream'),
          )
          .length;
      result['reconnect_diagnostic'] = {
        'persisted': persisted,
        'chat_posts': posts,
      };
      require(
        persisted && posts == 1,
        'Completion history reconciliation failed or POST replayed',
      );
      return {
        'session_id': sid,
        'deliberate_transport_close': true,
        'received_assistant_completed': live.finalText != null,
        'observed_run_completed': live.completed,
        'history_matches_completion': persisted,
        'chat_posts': posts,
        'read_reconnect_delays_seconds': delays,
        'note':
            'No SSE resume endpoint is specified; this verifies completion-to-history reconciliation, not lossless SSE replay.',
      };
    });
  } finally {
    for (final sid in created) {
      try {
        final deleted = await raw('DELETE', '/api/sessions/$sid');
        await raw('GET', '/api/sessions/$sid', status: 404);
        (result['cleanup'] as List<Json>).add({
          'session_id': sid,
          'deleted': deleted['deleted'],
          'get_status': 404,
        });
      } catch (e) {
        (result['cleanup'] as List<Json>).add({
          'session_id': sid,
          'error': '$e',
        });
      }
      save();
    }
    repo.close();
    setup.close();
    result['finished_at'] = stamp();
    result['passed'] =
        steps.length == (reconnectOnly ? 2 : 8) &&
        steps.values.every((e) => e['status'] == 'passed') &&
        (result['cleanup'] as List<Json>).every((e) => e['get_status'] == 404);
    save();
    stdout.writeln(
      '${stamp()} WALKTHROUGH ${result['passed'] == true ? 'PASSED' : 'FAILED'}; ${created.length} temporary sessions, cleanup=${jsonEncode(result['cleanup'])}',
    );
    if (result['passed'] != true) exitCode = 1;
  }
}
