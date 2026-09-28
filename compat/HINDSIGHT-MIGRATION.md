# Hindsight memory-provider migration (UPD-COMPAT P4)

Target commit `d0288be5b33` moved the hindsight provider out of Hermes core
(upstream commit `4cbf862abe4`). Nothing in this repository re-adds it; this
document records how the provider is installed after `hermes update` and what
changes for a self-hosted setup.

## How the provider is installed after the update

Upstream owns the whole path:

- `hermes update` runs the per-home migration hook
  (`hermes_cli/memory_provider_migration.py::migrate_all_homes`). For every
  profile home whose `memory.provider` names a non-core provider that is no
  longer present, it installs the catalog plugin
  (`hermes plugins install <name>`, enable=True) through the catalog
  installer (`hermes_cli/plugins_cmd_catalog.py`, provenance recorded in
  `.install-metadata.json` plus the `.hermes-catalog.json` sidecar). Your
  `memory.hindsight*` settings and data are untouched by this step.
- Catalog entry for hindsight at the target: pin
  `176f8c2de1369f569c489b831d143b78128b5535`, plugin version `1.0.1`,
  `requires_hermes >= 0.21.4`. Cloud and local EXTERNAL modes are supported.
- Manual equivalent when the automatic step reports a failure:
  `hermes plugins install hindsight`. A failed migration never takes the
  update or the agent down; it only prints the one-liner to run.
- A startup recovery (`recover_at_startup`) re-checks the provider after a
  partial install.

## Verify after the update

1. The update output shows the memory-provider migration line (installed, or
   the exact `hermes plugins install hindsight` command if it could not run).
2. The plugin is present and enabled in the plugin list; the hindsight
   recall/reflect/retain tools are offered.
3. One end-to-end memory check: retain something in a test session, restart
   the page/gateway at your normal window, confirm recall returns it.
   Memory being down is visible as the provider's tools/hooks missing —
   never assume silence means memory is alive.

## Rollback

The provider directory is owned by upstream/plugin installs; this plugin
never writes it. To roll back a `hermes update`, restore the previous
`hermes-agent` checkout/venv through your normal PM procedure and disable
the catalog-installed plugin; the `~/.pg0` store belongs to the daemon, not
to Hermes, so do not delete it before an older build is confirmed working.

## This machine (read-only facts, 2026-09-26)

- `~/.hermes/config.yaml`: `memory.provider: hindsight`,
  `memory.hindsight_backend: local`, `memory.hindsight_url` and
  `memory.hindsight_qdrant_url` pointing at `http://localhost:6333`,
  custom LLM provider/model settings for the provider.
- A pre-update local patch (`9be03c42f15`, archived on the legacy branch)
  added passthrough in `plugins/memory/hindsight/embedded.py` of two Hermes
  config keys into the embedded daemon environment:
  `llm_timeout -> HINDSIGHT_API_LLM_TIMEOUT` (default 300) and
  `worker_max_slots -> HINDSIGHT_API_WORKER_MAX_SLOTS` (default 4).
  Reason: self-hosted reasoning models exceed the 120 s daemon default.
- `~/.pg0/` exists (installation/instances). The main agent's standing
  premise is a local embedded-form daemon on port `:9177`.

## Behavior difference you must record

The catalog pin explicitly does NOT support `local_embedded` on PM-managed
Hermes ("it still calls the retired lazy-install path for hindsight-all").
Therefore after the update:

- The embedded daemon must run as a LOCAL EXTERNAL service you manage
  yourself (systemd or your PM), reusing the same `~/.pg0` store, serving the
  port `memory.hindsight_url` points at (e.g. `:9177`).
- The two archived passthrough keys do not exist in the catalog code. Set
  `HINDSIGHT_API_LLM_TIMEOUT` and `HINDSIGHT_API_WORKER_MAX_SLOTS` in the
  daemon's own environment (its service unit) instead; Hermes config keys
  `llm_timeout`/`worker_max_slots` become inert.
- Point `memory.hindsight_backend`/`memory.hindsight_url` at that external
  daemon. Automatic migration installs the plugin but does not rewrite these
  values for you.

Order that keeps memory alive across the update: update `hermes-agent` (only
after the compat probe is green at that SHA), let the migration install the
plugin, start/configure the external daemon with the environment tuning,
then cold-restart the gateway in your normal window, then run the memory
verification above, then enable/confirm `hermes-app-compat` per README.
`hermes update` itself never restarts services; the cold restart is yours.
