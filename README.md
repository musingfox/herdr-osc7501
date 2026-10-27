# herdr-osc7501

把 herdr 裡每個 pane 的 agent 狀態，用 OSC 7501（[Rex Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status.md)）回報給外層終端。

目前是 POC：`hook.sh` 只在名為 `poc7501` 的 herdr session 動作。

## 為什麼要繞路

- herdr 自己模擬 pane 的終端，不回應 `OSC 7501;?`（實測只回 DA1 `ESC[?62;22c`）。Claude Code 收不到回應就不送 OSC 7501，所以 pane 裡的 agent 永遠不會回報。
- herdr plugin 沒有寫外層終端的 API，而且 plugin 跑在 server，外層終端屬於 client。
- Rex 的 API 只能讀 `program_status`，不能寫。

所以 hook 直接寫進 herdr client 所在的 tty，Rex 會把 record 記在那個 block 上，owner 是 herdr client。

## 運作方式

- `[[events]] on = "pane.agent_status_changed"` 觸發 `hook.sh`。
- event JSON 的形狀：`{"event":"pane_agent_status_changed","data":{"pane_id":"w1:p1","workspace_id":"w1","agent_status":"working","agent":"claude"}}`。
- 狀態對應：`idle`、`working`、`blocked`、`done` 原樣送出；其他狀態（`unknown`、release）送 `state=clear:id=…`。
- pane id 的 `:` 不合 OSC 7501 的 id 文法，轉成 `.`（`w1:p1` → `w1.p1`）。
- `title` 是 pane cwd 的最後一段。

## 已知限制

- `report-agent --message` 的文字不在 event JSON、`pane get`、`agent list` 裡，所以不送 `msg`；`kind` 也沒有來源。
- client tty 用 `ps` 比對 `herdr --session <name>`，會漏掉預設 session（argv 只有 `herdr`）和 `herdr session attach`。
- `--remote` 與 `remote-client-bridge` 的 client 沒有本機 tty，這條路到不了。
- 從外部寫 tty 會和 herdr 的畫面輸出交錯。壓測 300 次寫入後畫面沒有殘碼，但瞬間的錯亂量不到。
- 根治的做法是 herdr client 在狀態變化時原生送 OSC 7501；client 已經會寫視窗標題和 OSC 通知到外層終端。

## 開發與測試

前置：herdr 0.9.5 以上、`jq`、在 Rex 裡執行。

1. 連結 plugin：`herdr plugin link .`
2. 在一個 Rex block 開 client：`herdr --session poc7501`
3. 在另一個 shell 送狀態：`herdr --session poc7501 pane report-agent w1:p1 --source poc --agent claude --state working --seq 1`
4. 讀 Rex 的 record（block id 用 `rex block ls` 查）：`rex block call -b <block-id> program_status`
5. hook 的紀錄在 `~/.local/state/herdr/plugins/poc.osc7501/log.txt`。
6. 結束後：`herdr plugin unlink poc.osc7501`，再 `herdr session stop poc7501`。
