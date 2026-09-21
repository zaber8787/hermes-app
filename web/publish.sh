#!/usr/bin/env bash
# 發佈 web 版：以 repo root 為基準（不再假設 $HOME/hermes-app）：
# 乾淨 public web build → 放進 web/releases/<ver> → 原子翻 current 連結
# （index.html / flutter_bootstrap.js 是 no-cache，其餘檔名帶 hash，翻連結即生效，
# 服務不用重啟）。
# --build-only：只產 build output，不碰 releases/current（供驗證）。
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root/app"
VERSION=$(grep '^version:' pubspec.yaml | cut -d' ' -f2 | cut -d+ -f1)

BUILD_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --build-only) BUILD_ONLY=1 ;;
    *) echo "usage: web/publish.sh [--build-only]" >&2; exit 2 ;;
  esac
done

bash "$root/scripts/build_app.sh" --target web --mode release --profile public

if [ "$BUILD_ONLY" = 1 ]; then
  echo "web ${VERSION} built (not published): $root/app/build/web"
  exit 0
fi

DEST="$root/web/releases/${VERSION}-web"
mkdir -p "$DEST"
rsync -a --delete build/web/ "$DEST/"
ln -sfn "releases/${VERSION}-web" "$root/web/current"
echo "web ${VERSION} live: $(readlink -f "$root/web/current")"
