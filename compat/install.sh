#!/usr/bin/env bash
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
plugin_home=${HERMES_HOME:-"$HOME/.hermes"}
target="$plugin_home/plugins/hermes-app-compat"
mkdir -p -- "$target"
# Only managed source files: preserve operator files and plugin state.
rsync -a -- "$source_dir/plugin.yaml" "$source_dir/__init__.py" \
  "$source_dir/compat.py" "$source_dir/ntfy_notify.py" \
  "$source_dir/app_platform.py" "$source_dir/cron_delivery_store.py" \
  "$source_dir/auto_wake.py" "$source_dir/auto_wake_store.py" \
  "$source_dir/self_wake.py" \
  "$source_dir/README.md" "$source_dir/HINDSIGHT-MIGRATION.md" "$target/"
printf 'Installed source at %s\nEnable separately: hermes plugins enable hermes-app-compat\n' "$target"
