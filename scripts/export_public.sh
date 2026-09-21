#!/usr/bin/env bash
# Clean-export entry point (PUBLIC-AUDIT §4).
#
# Computes the public set E = T - I, where
#   T = tracked files (git ls-files) and
#   I = tracked files matched by ignore rules (git ls-files -ci),
# refuses symlink/submodule entries and any private-disposition path,
# requires the mandatory public files (LICENSE included — existence is
# checked, never created here), copies the exact bytes of every regular
# file in E into a fresh staging directory, proves that the staged
# listing equals E and contains no .git, and only then runs the hygiene
# gate over the stage. Prints "EXPORT-OK <dir>" only if everything
# passed. Publish the listed directory's contents — never .git history.
#
# Usage: bash scripts/export_public.sh [staging-dir]   (empty dir or absent)
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

block() { echo "EXPORT-BLOCKED: $*" >&2; exit 1; }

command -v git >/dev/null || block "git is required"
git rev-parse --git-dir >/dev/null 2>&1 || block "not a git checkout"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# --- E = T - I (NUL-delimited set difference of sorted lists) --------------
git ls-files -z | sort -z > "$tmp/T"
git ls-files -ci --exclude-standard -z | sort -z > "$tmp/I"
comm -z -23 "$tmp/T" "$tmp/I" > "$tmp/E"
mapfile -d '' -t paths < "$tmp/E"
[ "${#paths[@]}" -gt 0 ] || block "export set is empty"

# --- policy checks over E ---------------------------------------------------
# modes are the authoritative symlink/submodule signal (120000/160000)
while IFS= read -r -d '' rec; do
  mode="${rec%% *}"; path="${rec#*$'\t'}"
  case "$mode" in
    120000) block "symlink in export set: $path" ;;
    160000) block "submodule (gitlink) in export set: $path" ;;
  esac
done < "$tmp/T"
for p in "${paths[@]}"; do
  [ -L "$p" ] && block "symlink in export set: $p"
  [ -e "$p" ] || block "missing tracked file: $p"
  [ -d "$p" ] && block "non-regular entry in export set: $p"
done

# private-disposition paths: may exist on disk / in history, never public
deny=(
  'TASK/*' 'CHANGELOG-PRIVATE.md' 'patches/*' 'logs/*' 'exports/*' '.sweep/*'
  '*.log' 'web/current' 'releases/*' 'web/releases/*' 'app/build/*' 'build/*'
  'toolchain/*' 'docs/COMPAT-IMPL-VALIDATION.md' 'docs/*-VALIDATION.md'
  'docs/compat-offline-results.json' 'docs/p1-integration-summary.json'
  'docs/p3-capabilities.json' 'scripts/approve-*' 'scripts/commit-*'
  'scripts/dispatch-*' 'scripts/watch-*' 'scripts/start-*' 'scripts/until-idle.sh'
  'scripts/wait-pane-text.sh' 'scripts/rss-hunt.sh'
  'tools/db_rows.py' 'tools/latest_rows.py' 'tools/list_recent_sessions.py'
  'tools/which_key.py' 'tools/direct_cut_e2e.py' 'tools/proxy_survive_e2e.py'
  'tools/probe_upload_truncation.py' 'tools/probe_wave3_endpoints.py'
  'app/test/fixtures/private/*' 'probe/results/*' '.env' '.env.*' '.envrc'
  '*.jks' '*.keystore' '*key.properties'
)
for p in "${paths[@]}"; do
  [ "$p" = ".env.example" ] && continue   # reviewed exception: fields only, values empty
  for g in "${deny[@]}"; do
    # shellcheck disable=SC2053
    [[ "$p" == $g ]] && block "private-disposition path in export set: $p"
  done
done

# mandatory public files; LICENSE existence is REQUIRED (never created here)
for f in LICENSE README.md .env.example scripts/export_public.sh; do
  hit=0
  for p in "${paths[@]}"; do [ "$p" = "$f" ] && hit=1 && break; done
  [ "$hit" = 1 ] || block "required public file missing from export set: $f"
done

# --- staging: exact regular-file bytes into a fresh directory ---------------
stage="${1:-$(mktemp -d "${TMPDIR:-/tmp}/hermes-export.XXXXXX")}"
mkdir -p "$stage"
[ -z "$(find "$stage" -mindepth 1 -print -quit 2>/dev/null)" ] \
  || block "staging directory not empty: $stage"
for p in "${paths[@]}"; do
  mkdir -p "$stage/$(dirname "$p")"
  cp -p -- "$p" "$stage/$p"
done

# staged listing must equal E exactly, and carry no git metadata
(cd "$stage" && find . \( -type f -o -type l \) -print0 | sed -z 's|^\./||' | sort -z) \
  > "$tmp/S"
cmp -s "$tmp/S" "$tmp/E" || block "staged files differ from export set"
if find "$stage" -name .git -print -quit | grep -q .; then
  block ".git metadata inside staging"
fi

# --- final content scan ------------------------------------------------------
python3 tools/hygiene_gate.py --export "$stage" \
  || block "hygiene gate rejected the staged export"

echo "EXPORT-OK $stage"
