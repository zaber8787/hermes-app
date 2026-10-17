#!/usr/bin/env bash
# 發佈 web 版：以 repo root 為基準（不再假設 $HOME/hermes-app）。
# WEBSYNC F6: 每一次發佈（含同版重發）都寫進一個全新的时间戳目錄，完成
# （含 version.json）後才以 symlink 原子翻轉指向它；正在服務的目錄從不
# 原地覆寫，已在途的請求會把舊目錄讀完。舊 release 只保留上一版供 in-flight
# 讀完，其餘清除。index.html / flutter_bootstrap.js / 所有靜態檔在 serve.py
# 走 no-cache + stat-ETag，翻連結即生效，服務不用重啟。
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

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
DEST="releases/${VERSION}-web+${STAMP}"
mkdir -p "$root/web/$DEST"
# 只寫新目錄：rsync 無 --delete、目標恆為剛建立的空目錄——覆寫在服務檔案
# 在這條路徑上不可能發生。
rsync -a build/web/ "$root/web/$DEST/"
# Embed the identity of THIS loaded bundle before the release is visible.
# version.json is fetched later and may already belong to the NEXT release.
python3 - "$root/web/$DEST/index.html" "$STAMP" <<'PY'
from pathlib import Path
import sys
page = Path(sys.argv[1])
source = page.read_text()
marker = '__HERMES_BUILD_ID__'
if source.count(marker) != 1:
    raise SystemExit('web build is missing the single release identity marker')
page.write_text(source.replace(marker, sys.argv[2]))
PY
# SESSIONDIR B3: mirror the engine's own gstatic web-fallback table into the
# release and redirect fontFallbackBaseUrl at it (offline Chinese, zero boot
# cost; B2 deferral measured engine-unsupported — see patch_release_fonts).
python3 "$root/web/patch_release_fonts.py" "$root/web/$DEST"
# SESSIONDIR B1: gzip companions while the directory is still invisible to
# the server (翻線前壓縮；請求路徑上只做 stat+send).
bash "$root/web/compress-release.sh" "$root/web/$DEST"
printf '{"version":"%s","build":"%s","published_at":"%s"}\n' \
  "$VERSION" "$STAMP" "$(date -u +%FT%TZ)" > "$root/web/$DEST/version.json"

# 翻轉：ln -sfn（-n＝no-dereference）。macOS 的 rename(2) 在 new 是
# 「指向存在目錄的 symlink」時會把來源**搬進目錄**而不是取代連結
# （實測於 APFS，2026-10-18），所以暫存連結＋mv 的「原子翻轉」在 Mac 上
# 無聲失效。ln -sfn 的 unlink→symlink 窗口只有微秒級，serve.py 每請求
# stat，最壞一個 404，遠好過永不翻轉。
if [ -e "$root/web/current" ] && [ ! -L "$root/web/current" ]; then
  rm -rf "$root/web/current"
fi
ln -sfn "$DEST" "$root/web/current"

# 清理：保留 current 與下一個最新的 release 讓 in-flight 請求讀完；其餘
# 只在「一小時內沒有任何新檔」時才刪除（并发發佈/剛上传的目錄自保）。
# 路徑一律以 $root/web 為基準（歷史版本混用了 $root 與 $root/web 兩種
# 相對基準，build_app.sh 之後 cwd 已不在 $root，readlink 失敗直接 set -e 中止）。
cd "$root/web"
current_target="$(readlink current 2>/dev/null || true)"
ordered=()
while IFS= read -r _d; do
  [ -n "$_d" ] && ordered+=("$_d")
done < <(ls -1dt releases/*-web* 2>/dev/null)
if [ -n "$current_target" ]; then
  rest=()
  for d in "${ordered[@]}"; do [ "$d" = "$current_target" ] || rest+=("$d"); done
  ordered=("$current_target" "${rest[@]:-}")
fi
keep_prev="${ordered[1]:-}"
for d in "${ordered[@]:2}"; do
  [ -n "$d" ] && [ -d "$d" ] || continue
  if ! find "$d" -newermt '-1 hour' -print -quit | grep -q .; then
    rm -rf -- "$d"
  fi
done
echo "web ${VERSION} live: $(readlink -f current) (prev kept: ${keep_prev:-none})"
