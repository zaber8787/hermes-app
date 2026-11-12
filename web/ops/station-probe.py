#!/usr/bin/env python3
"""STATION-LANE D1：離端探針，部署在 zaber-2 上從站外看 ts.net。

純 stdlib，無參數執行一次。每次產生一行 JSON，同時印 stdout 並逐行
append 到 STATION_PROBE_LOG（預設 $HOME/station-probe.jsonl）。檔案超過
STATION_PROBE_MAX_BYTES（預設 2,000,000）時把舊檔改名加 .1（單層輪替，
蓋掉舊的 .1，不刪）。

任何異常都吃下來變成 ok=false 的一行；本腳本永不非零退出（cron 腳本，
非零退出會被上游當成腳本壞掉）。
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

URL = os.environ.get("STATION_PROBE_URL",
                     "https://bot.tail592d86.ts.net/version.json")


def _err_text(exc: BaseException) -> str:
    return f"{type(exc).__name__}: {exc}".replace("\n", " ")[:120]


def main() -> None:
    status: int | None = None
    err: str | None = None
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(URL, timeout=6) as resp:
            resp.read()
            status = resp.status
        ok = status == 200
    except urllib.error.HTTPError as exc:
        ok = False
        status = exc.code
        err = _err_text(exc)
    except Exception as exc:  # 任何異常都變成 ok=false 的一行
        ok = False
        status = None
        err = _err_text(exc)
    sec = round(time.monotonic() - t0, 3)
    line = json.dumps({"ts": int(time.time()), "url": URL, "ok": ok,
                       "status": status, "sec": sec, "err": err},
                      ensure_ascii=False)
    print(line, flush=True)
    try:
        path = os.environ.get("STATION_PROBE_LOG") or os.path.join(
            os.path.expanduser("~"), "station-probe.jsonl")
        try:
            max_bytes = int(os.environ.get("STATION_PROBE_MAX_BYTES",
                                           "2000000"))
        except ValueError:
            max_bytes = 2000000
        try:
            if os.path.getsize(path) > max_bytes:
                os.replace(path, path + ".1")
        except OSError:
            pass  # 檔案還不存在
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except Exception:
        pass  # 寫檔失敗不影響退出碼；stdout 已有同一行


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
