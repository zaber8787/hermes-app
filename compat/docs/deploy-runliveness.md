# RUNLIVENESS 部署說明（TASK-RUNLIVENESS）

## B2 隱私決策

新動詞 `session.liveness` 只回**單一 session** 的存活狀態。橋在橋端就把 core 的
`session.active_list`（列全部 live 列、含 hidden、無上限）收斂成一列，回包鍵恰為
`{session_id, listed, status}`。其他 session 的 id、title、清單內涵一律不外送；
測試 `test_answers_one_session_only` 直接斷言別列的 id 與 title 不在回包裡。

## RPC 名稱與參數

- 名稱：`session.liveness`（已入 `ALLOWED_METHODS`）
- 參數：`{"session_id": "<sid>"}`，多一欄、少一欄、空字串都回 `-32602 invalid_params`
- 結果：`{"session_id": "<root>", "listed": true|false, "status": "working"|"waiting"|"starting"|"idle"|null}`
  - `listed=false` 時 `status=null`（不在 live registry，或本連線沒有該 continuation 的 alias，見 M15）
  - 內部呼叫 core `session.active_list` 一次，比對 `id`（alias 經 `self.aliases` 對到 lineage root）
- 錯誤透傳：core 的 JSON-RPC 錯誤碼原樣透出；橋自己讀不到上游時回 `upstream_unavailable`

## S2 實測數據（2026-11-06，repo root 的探針腳本，20 次迴圈）

    rows 3603 target_status idle
    total_p50 0.06 total_max 0.1098 rpc_p50 0.058
    resume_bytes 3157704 running False pending 0

registry 3603 列、單發 `session.active_list` 端到端 p50 = 0.06 秒。

## D3 取捨與 C4 限制

**D3（已證實）**：上千列命中工單 :130 的「上千列」分支，輪詢走**獨立上游連線**
（每次輪詢一支短命 dial），Bridge 層 single-flight 讓同一瞬間的多條 app link 共用同一發。
共用 app 自己的連線會讓 submit/steer 排在 registry 掃描之後（core 序列 dispatch，
`tui_gateway/ws.py:494-499`）。

**C4（部分推論）**：liveness 的回答從橋發回 app 自己的 link。橋與上游這段已由
`test_answers_while_resume_held` 保證（resume 被持有時輪詢照回）。但若那條 link 正塞著
3 MiB resume 的 LTE 下行，回包在同一條 socket 上無法超車，要等下行排空。橋端測試涵蓋不到
行動網路的排程行為，這半段屬推論、待實測。

**M15**：messaging continuation 的 id 若在本連線沒有 alias，`listed=false`，app 端靠
`_wsResumePending` 保護不會因此降旗（測試 `continuation_without_an_alias_is_not_listed`）。

## 部署順序

1. **compat 先上**：更新 `compat/wsbridge.py` 後重起 `run-wsbridge`（由主 Agent 執行，worker 本輪未重啟任何服務）。
2. **app 後上**：新 app 對舊橋只是多問一個 `-32601`，退化行為見下；反舊 app 打新橋完全不受影響（新動詞只是多出來，舊方法簽名沒動，`request()`/`call()` 路徑原樣）。

## 只有 app 升級、橋還是舊版時的退化行為

- 每次輪詢得到 `-32601 method_not_found` → app 停止輪詢直到下次 link up（`_wsPollStopped`）。
- B1（resume 重問階梯 2s/5s/10s/30s/30s/30s/5min）完全照跑，「正在執行」指示靠 resume 答案與事件流維護，與舊版行為一致，只是沒有輪詢兜底。

## 主 Agent 驗收清單

- [ ] 重起 `run-wsbridge` 後跑 `tools/wsbridge_probe.py --url … --liveness`（或既有 smoke）確認橋端動詞上線。
- [ ] S2b 的 `working` 關：開一個真回合，回合進行中對該 session 呼叫 `session.liveness`，確認 `status="working"`（worker 量測時無回合在跑，只驗到列存在）。
- [ ] 新 app 接舊橋：把橋退回上一版，確認 app 只停輪詢、指示仍靠 resume/事件更新，log 無重問風暴（-32601 後輪詢熄到下次 link up）。

## 檔案清單

Create:
- `compat/docs/deploy-runliveness.md`（本檔）

Modify:
- `compat/wsbridge.py`（`session.liveness`、read-loop dispatch、`live_rows` single-flight）
- `compat/README.md`（方法清單與 liveness 一句說明）
- `tests/test_wsbridge.py`（`Liveness` 群 12 支）
- `app/lib/data/gateway_ws.dart`（`WsLiveness`、`liveness()`）
- `app/lib/features/chat/chat_controller.dart`（重問階梯、輪詢、旗標映射、計時器紀律）
- `app/test/ws_app_test.dart`（RUNLIVENESS 群 T1–T14、X3、X4）
- `tools/wsbridge_probe.py`（`--liveness`、`max_size=None`）
- `CHANGELOG.md`
- `.gitignore`（evidence/scratch 目錄）
