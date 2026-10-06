# hermes-app-compat

Source only; installation is an operator action (see below).
Supports two source backends selected by fingerprint triple at registration:
baseline `2a327c25af3eb146db7be627db4c2c3fc42e0494` and target
`d0288be5b3330d2442e3907185b8e9d0958297bb`. Any other source fails every
fingerprint-gated group closed.

Ten independent groups: bounded complete artifact uploads; 500 MiB and common
MIME limits; authenticated media downloads; history image data URLs; session/run
approval cards; skills signature compatibility; session/run activity snapshots;
ntfy viewer-gone wake-ups; the P5 cron-delivery bridge (`app` platform +
atomic report writer); and the auto-wake contract (server-verified cron
provenance on the messages projection, plus the capability-gated admission
ledger, per-report consumption records, shared hourly quota, and wake receipts).
All upstream dependencies are in `compat.py`. Nothing writes Hermes core files.
The push unit adds notifications for already-existing session-SSE events; the
SSE heartbeat/keepalive behavior is untouched.

## Validation

From the hermes-app repository:

```sh
python3 tools/compat_probe.py --mode offline --full-size --json-output /tmp/compat-result.json
```

The runner uses the agent's existing venv, archives clean HEAD into a temporary
directory, and gives each case a fresh HOME/HERMES_HOME. It never imports the dirty
agent checkout. Workers prohibit non-loopback connects and bytecode writes. No API
keys, model calls, live gateway, or production configuration are needed. 500 MiB
uploads still buffer in the upstream store and can use over 1 GiB; run sequentially.
The control case must reproduce clean upstream truncation and skills HTTP500.
`--only` is always a PARTIAL report. Without `--full-size`, limits are NOT_RUN.

## Installation (operator only)

```sh
bash compat/install.sh
hermes plugins enable hermes-app-compat
```

The installer only rsyncs the managed source/documentation files and prints the
enable command. It does not enable, change config, restart, or delete operator files.
`HERMES_HOME` selects an alternate profile home. The operator must restore any old
in-tree artifact patch separately, then cold-restart through the normal gateway
management procedure. Do not run this installer while merely reviewing source.

After activation, inspect `hermes-app-compat manifest`: each group must say `applied`
(or `native_candidate` subsequently validated by probes). A skipped group is red,
not a healthy fallback. The plugin catches registration errors and leaves other
groups active; approval is one atomic group. Manifest state is also available as
`gateway.platforms.api_server._hermes_app_compat_state_v1['manifest']`.

## Upgrades and rollback

Run clean-head offline probes after `hermes update`. Copied upload/SSE/worker methods
have fixed source SHA256 fingerprints; unexpected changes refuse that group until a
review incorporates new upstream behavior in `compat.py`. Do not simply refresh a
hash to bypass the guard. No runtime source rewriting or `exec` is used.

Repeated registration is idempotent. Managers share process-global patches with
reference-counted owners; last unload restores only bindings still owned by this
plugin. Disabling requires a cold restart: existing aiohttp routers retain bound
handlers, so hot unload cannot be advertised as complete rollback.

Approval uses run-specific keys and real upstream policy/queue/HTTP resolution.
No listener keeps upstream unattended behavior. Cron, -q, denial, timeout, ownership,
room request IDs and stop authorization remain intact. Session workers bind approval
context inside the executor. Stop, disconnect, worker exit and gateway shutdown
release pending listeners. A proxy that keeps draining after the viewer leaves can
retain a listener until the normal timeout; absence of a reply never means approval.

On the TARGET backend session approvals ride the native notify lifecycle; the
plugin adds only the listener-aware predicate and the queue mirror. A session
turn handed to a live Bot Chat owner executes outside this process: once any
such handoff has happened, activity snapshots answer 503 for the process
(never a fabricated idle) until receipt tracking lands as its own batch.
Registration honors the loader deadline: groups and the unload lease exist
before the first setattr, and a load marked abandoned stops at the next
binding and rolls back.

Push (TARGET backend only; BASE is `skipped_incompatible`) publishes at most one
ntfy wake-up per event when a session-SSE turn goes on living after its viewer
disconnected: approval needed (unresolved card, high), reply ready (completed,
byte-bounded plain-text preview, never data URLs), run failed (redacted error,
high). A connected viewer means zero pushes; a terminal frame already written to
the socket is acknowledged and never re-pushed; cancelled/interrupted never
push; replays dedup through one per-run state. Detached turns keep running with
native persistence/approval/stop semantics, and one discard consumer bounds the
event queue. Config lives in the profile `config.yaml` `push:` block
(`ntfy_server`/`ntfy_topic`); unconfigured runs keep the original disconnect
behavior. Messages carry the `hermes-agent` echo tag so a shared ntfy platform
topic can never loop them back as prompts. Live Bot Chat handoff turns are out
of scope (documented unsupported).

Cron bridge (TARGET backend only; BASE is `skipped_incompatible`) registers the
`app` platform so a job can use `deliver="app:<exact_session_id>"`. One cron
execution commits exactly one `[Cron report: name]` row
(role=user, display_kind=internal_notification) into the session's live
compression continuation, inside a single reviewed SessionDB transaction with
dedup, active-turn-lease rejection, and hidden/archived/ended/source policy
fail-closed (never a silent unhide, new session, or Discord fallback). Success
means committed data: the next `GET /api/sessions/{id}/messages` shows it and
the App renders it as a system event; no model turn is ever started by a
delivery. A busy target returns observable `queued` via a durable plugin spool
and bounded drainer (queued is never reported as delivered); the same execution
always retries into the same row id, while a new execution of identical text is
a new legitimate report. The app branch carries its execution identity through
live metadata and the standalone ContextVar (wrapper-bound, fingerprinted),
takes no generic mirror or thread seeding, and refuses multi-target jobs before
any platform sends.

Hindsight moved out of upstream core. See `HINDSIGHT-MIGRATION.md` for the
catalog install path, verification, rollback, and the local-mode behavior
difference to record before updating.

Media paths use upstream validation with its default empty session key. This is
operator-authenticated host-file delivery, not a new per-session filesystem boundary.
`FileResponse` inherits upstream path-open races and stat-time size checking. History
inline images retain the upstream 5 MiB bound. The request-size constant is global,
so raising it also raises the high-level request-body limit for non-artifact routes.

Live probes are opt-in (`--mode live --base-url ... --token-file ...`). They never
install/restart or rewrite settings. Agent-turn cases require
`--allow-test-agent-turns`; manual Flutter UI checks remain a deployment task.

## Self-wake (server-side, opt-in)

`wake.selfwake` in profile config: `false`/absent/malformed = off (fail closed —
`settings()` returns a reason string, never guesses), `"shadow"` = record
intents without ever admitting, `true` = the gateway worker owns dispatch.
Toggling off voids undispatched pending/shadow intents; consumed or accepted
batches are never released. Re-enabling bumps the enable generation so reports
that landed while disabled stay history (reconcile only recovers the crash gap
— a report row with NO receipt).

The worker (arm via app-platform connect, stop via disconnect) consumes
`selfwake_intents` in `cron_bridge.db`, decides everything against the B
ledger (never capability state), and dispatches exactly one loopback
`chat/stream + wake_batch` POST per batch. An App that consumed a key first is
yielded to forever; the self side only ever adopts batches whose `owner`
column says `self:*`. Uncertain outcomes (crash between CAS and terminal)
settle once as `uncertain-consumed` with the missed-reply risk recorded in
`selfwake_audit` — never a re-POST.

Fuse: 3 fires / lineage (`chain_limit`, durable, survives restart/hour/
compression) or 3 consecutive failed/uncertain settlements stops the lineage;
reopening needs a human message on the session (`chain_human_checkpoint`) or
`chain_release` (audited `chain-reset`). `causal_suspect` is a conservative
heuristic, not full causal tracking.

Wire coverage: `.selfwake-evidence/s4-wire-matrix.sh` proves the wake turn
over OpenAI chat-completions and native Anthropic Messages fakes; the OpenAI
Responses wire is host-gated upstream (loopback overrides speak chat
completions — Hermes documents this), covered by the product suite instead.

Rollback: set `wake: {selfwake: false}` (or remove the key) — no new admits,
pending intents void at next tick, in-flight runs finish under the existing
shutdown drain. Ledger/bridge rows stay for audit; there is nothing to
migrate back. Full disable of the feature binary-wise is removing this plugin
section only — wake/bridge/ntfy paths do not depend on `self_wake.py`.
