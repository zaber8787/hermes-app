#!/usr/bin/env bash
# TASK-PLUGINSYNC R3: repo compat/ -> deployed plugin dir. compat/ is the
# source of truth; every deploy sync goes through this script.
#
#   sync-deploy.sh --check     compare only; exit 0 when both sides match
#   sync-deploy.sh --dry-run   show what a sync would copy, change nothing
#   sync-deploy.sh             back up the deploy dir, copy repo -> deploy,
#                              clear __pycache__, then re-run --check
#   sync-deploy.sh --prune     same, and also delete deploy-only files
#
# Without --prune a deploy-only file aborts the sync before anything is
# written: it is drift that has to be pulled into the repo (or approved for
# deletion) first. Repo-only material (docs/, tools/) is never deployed.
# Bash 3.2 compatible (macOS system shell). Never restarts any service.
set -euo pipefail

src=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plugins=${HERMES_HOME:-"$HOME/.hermes"}/plugins
target=${SYNC_DEPLOY_TARGET:-"$plugins/hermes-app-compat"}
# Tarballs, not an expanded copy: plugin discovery scans dot-dirs under
# plugins/, and an expanded tree would carry a second plugin.yaml.
backup_dir=${SYNC_DEPLOY_BACKUP_DIR:-"$plugins/.hermes-app-compat.bak-pluginsync"}
excludes=(--exclude=__pycache__ --exclude=.pytest_cache --exclude=/docs --exclude=/tools)

mode=sync
case "${1:-}" in
  --check) mode=check ;;
  --dry-run) mode=dry ;;
  --prune) mode=prune ;;
  "") ;;
  *) echo "usage: $0 [--check|--dry-run|--prune]" >&2; exit 64 ;;
esac

# Content-level comparison, same view as `diff -rq` minus cache/repo-only dirs.
check() {
  local out
  out=$(diff -rq -x __pycache__ -x .pytest_cache -x docs -x tools "$src" "$target" 2>&1 || true)
  # docs/ and tools/ are excluded by name at every depth; only the top-level
  # ones are repo-only, so make sure nothing deeper is hiding behind that.
  local nested
  nested=$(cd "$src" && find . -mindepth 2 \( -name docs -o -name tools \) -not -path "*/__pycache__/*" | head -1)
  if [ -n "$nested" ]; then
    echo "sync-deploy: nested $nested is not compared; refusing to vouch" >&2
    return 2
  fi
  if [ -z "$out" ]; then
    echo "sync-deploy: IN SYNC $src == $target"
    return 0
  fi
  echo "$out"
  echo "sync-deploy: DRIFT between $src and $target" >&2
  return 1
}

if [ ! -d "$target" ]; then
  echo "sync-deploy: deploy dir missing: $target" >&2
  exit 2
fi

if [ "$mode" = check ]; then
  check
  exit $?
fi

if [ "$mode" = dry ]; then
  rsync -rlt --checksum --itemize-changes --dry-run "${excludes[@]}" "$src/" "$target/"
  echo "--- deploy-only files (need --prune or a repo pull):"
  rsync -rlt --checksum --itemize-changes --dry-run --delete "${excludes[@]}" \
    "$src/" "$target/" | grep '^\*deleting' || echo "(none)"
  exit 0
fi

extra=$(rsync -rlt --checksum --itemize-changes --dry-run --delete "${excludes[@]}" \
  "$src/" "$target/" | grep '^\*deleting' || true)
if [ -n "$extra" ] && [ "$mode" != prune ]; then
  echo "$extra"
  echo "sync-deploy: deploy has files the repo lacks; pull them into compat/ or rerun with --prune" >&2
  exit 3
fi

mkdir -p -- "$backup_dir"
stamp=$(date +%Y%m%d-%H%M%S)
archive="$backup_dir/hermes-app-compat-$stamp.tar.gz"
tar -C "$(dirname -- "$target")" -czf "$archive" "$(basename -- "$target")"
echo "sync-deploy: backup $archive"

delete=()
[ "$mode" = prune ] && delete=(--delete)
# -rlt without -p: content and mtimes follow the repo, deploy file modes stay.
rsync -rlt --checksum --itemize-changes ${delete[@]+"${delete[@]}"} "${excludes[@]}" "$src/" "$target/"
find "$target" -type d -name __pycache__ -prune -exec rm -rf {} +
echo "sync-deploy: cleared __pycache__ under $target"
check
