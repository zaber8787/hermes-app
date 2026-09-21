#!/usr/bin/env bash
# Thin entry: locate the repo, set up the toolchain, exec the Python driver.
# Usage: bash scripts/build_app.sh --target apk|web --mode debug|release \
#          --profile personal|public
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$root/scripts/env.sh"
exec python3 "$root/scripts/build_app.py" "$@"
