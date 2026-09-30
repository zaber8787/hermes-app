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
printf '{"version":"%s","build":"%s","published_at":"%s"}\n' \
  "$VERSION" "$STAMP" "$(date -u +%FT%TZ)" > "$root/web/$DEST/version.json"

# 原子翻轉：暫存 symlink + rename(2)。ln -sfn 直接改 current 不是原子操作
# （unlink→create 之間存在指向不存在/半狀態的窗口），mv -T 才是 rename。
ln -sfn "$DEST" "$root/web/.current.tmp.$$"
mv -Tf "$root/web/.current.tmp.$$" "$root/web/current"

# 清理：保留 current 與下一個最新的 release 讓 in-flight 請求讀完；其餘
# 只在「一小時內沒有任何新檔」時才刪除（并发發佈/剛上传的目錄自保）。
current_target="$(readlink web/current)"
mapfile -t ordered < <(ls -1dt releases/*-web* 2>/dev/null)
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
echo "web ${VERSION} live: $(readlink -f web/current) (prev kept: ${keep_prev:-none})"
