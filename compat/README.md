# hermes-app-compat

Source only; installation is an operator action (see below).
Targets Hermes HEAD `2a327c25af3eb146db7be627db4c2c3fc42e0494`.

Seven independent groups: bounded complete artifact uploads; 500 MiB and common
MIME limits; authenticated media downloads; history image data URLs; session/run
approval cards; skills signature compatibility; session/run activity snapshots.
All upstream dependencies are in `compat.py`. Nothing writes Hermes core files.
No notification or keepalive changes.

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

The installer only rsyncs the four managed source/documentation files and prints the
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

Media paths use upstream validation with its default empty session key. This is
operator-authenticated host-file delivery, not a new per-session filesystem boundary.
`FileResponse` inherits upstream path-open races and stat-time size checking. History
inline images retain the upstream 5 MiB bound. The request-size constant is global,
so raising it also raises the high-level request-body limit for non-artifact routes.

Live probes are opt-in (`--mode live --base-url ... --token-file ...`). They never
install/restart or rewrite settings. Agent-turn cases require
`--allow-test-agent-turns`; manual Flutter UI checks remain a deployment task.
