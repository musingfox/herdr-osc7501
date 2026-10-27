# herdr-osc7501

把 herdr 裡每個 pane 的 agent 狀態，用 OSC 7501（[Rex Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status.md)）回報給外層終端。每個 herdr session 都會動作，包括預設 session。

## 安裝

需要 herdr 0.9.5 以上、macOS、`jq`。

```
herdr plugin install musingfox/herdr-osc7501
```

## 為什麼要繞路

- herdr 自己模擬 pane 的終端，不回應 `OSC 7501;?`（實測只回 DA1 `ESC[?62;22c`）。Claude Code 收不到回應就不送 OSC 7501，所以 pane 裡的 agent 永遠不會回報。
- herdr plugin 沒有寫外層終端的 API，而且 plugin 跑在 server，外層終端屬於 client。
- Rex 的 API 只能讀 `program_status`，不能寫。

所以 hook 直接寫進 herdr client 所在的 tty，Rex 會把 record 記在那個 block 上，owner 是 herdr client。

## 運作方式

- `pane.agent_status_changed`、`pane.agent_detected`、`pane.closed`、`pane.exited`、`pane.moved`、`tab.closed`、`workspace.closed` 都觸發 `hook.sh`。
- 事件 JSON 的狀態可能已經過時，所以 hook 用 `herdr pane get` 讀 pane 目前的狀態。`pane get` 回 `pane_not_found` 以外的錯誤時，視為暫時失敗，退回事件 JSON；關 tab 或 workspace 時的重送則退回 `pane list` 裡該 pane 的資料。
- hook 之間不排隊，完成順序不固定。所以寫出後會重讀一次，結果不同就重寫，最多三輪。
- 狀態對應：`idle`、`working`、`blocked`、`done` 原樣送出；其他狀態（`unknown`）送 `state=clear:id=…`。
- 以下情況也送 `state=clear`：
  - `pane get` 回 `pane_not_found`，也就是 pane 已經關閉或結束。比 close 晚跑完的狀態 hook 因此不會把 record 寫回來。
  - pane 沒有 agent，也就是 agent 已經釋放。釋放後 pane 可能留著最後的狀態。
  - `pane.moved` 時舊的 pane id 和新的不同（移到別的 workspace 時才會變），先清舊 id，再寫新 id。
- 關 tab 或 workspace 時，herdr 不會對裡面的 pane 各送 `pane.closed`，事件本身也不帶 pane id。所以 hook 先讀 `herdr pane list`，送不帶 id 的 `state=clear` 清掉整個 terminal 的 record，再把每個還活著的 pane 照上面的方式重寫一次。`pane list` 失敗時什麼都不送。
- pane id 的 `:` 不合 OSC 7501 的 id 文法，轉成 `.`（`w1:p1` → `w1.p1`）。
- `title` 是 pane cwd 的最後一段。

## 已知限制

- herdr 沒有 client attach 或 detach 的事件，所以 client detach 時 hook 不會送清除。Rex 在終端裡的程式結束或下一個 OSC 133 A 時會丟掉 `working`、`blocked`（`idle` 也可能被丟掉），但 `done` 會留在原本的 block 上。
- client tty 用 `ps` 比對 client 的 argv，只認得 `herdr`（預設 session）、`herdr --session <name>`、`herdr session attach <name>`。`--session=<name>` 的 client 會漏掉。用環境變數選 session 的 client（例如 `HERDR_SESSION=x herdr`）argv 只有 `herdr`，所以收不到自己 session 的 record，反而會收到預設 session 的。
- 不同 config 目錄底下的兩個同名 session，從 argv 分不出來，兩邊的 client 都會收到。其中一邊關 tab 或 workspace 時，不帶 id 的 `state=clear` 也會清掉另一邊的 record，直到那邊各 pane 的下一個事件。
- `herdr --remote <host>` 的 client 收不到任何 record：argv 不符合，遠端 server 的 hook 也只會在遠端主機上跑 `ps`。
- 同時開著 `herdr remote-client-bridge`（透過 ssh 連到另一台主機）的 client，argv 仍然符合，所以畫面顯示遠端 pane 時也會收到本機 server 的 record。這會不會顯示錯誤還沒驗證。
- herdr 每個 server 同時最多跑 32 個 plugin command，超過的會被丟掉。hook 之間不互相等待，只有短時間內湧入大量事件才會碰到上限。如果最後一個事件的 hook 被丟掉，而且當時在跑的 hook 都已經做完最後一次重讀，record 會停在舊狀態，直到下一個事件。被丟掉的若是 `pane.closed`，那個 pane 不會再有事件，殘留的 record 要等之後某次關 tab 或 workspace 的重送才會清掉。
- 關 tab 或 workspace 時，重送讀完 `pane list` 之後才出現的 pane id，若它的 hook 在重送清除前就寫出，record 會被清掉，直到該 pane 的下一個事件。新建的 pane，以及同時被移到別的 workspace 而換了 id 的 pane，都會碰到。
- pane 關掉的同時，若 hook 最後一次寫出所依據的 `pane get` 回 `pane_not_found` 以外的錯誤，hook 會退回事件 JSON 或 `pane list` 的資料，留下已關閉 pane 的 record。`pane.agent_status_changed`、`pane.moved` 的 hook 和關 tab 或 workspace 的重送都可能碰到；`pane.closed`、`pane.exited`、`pane.agent_detected` 的事件 JSON 沒有 `agent_status`，退回時會送清除。
- `report-agent --message` 的文字不在 event JSON、`pane get`、`agent list` 裡，所以不送 `msg`；`kind` 也沒有來源。
- 從外部寫 tty 會和 herdr 的畫面輸出交錯。壓測 300 次寫入後畫面沒有殘碼，但瞬間的錯亂量不到。
- 根治的做法是 herdr client 在狀態變化時原生送 OSC 7501；client 已經會寫視窗標題和 OSC 通知到外層終端。

## 開發與測試

前置：`jq`、在 Rex 裡執行。

1. 連結 plugin：`herdr plugin link .`（若之前用 GitHub 裝過，先 `herdr plugin uninstall musingfox.osc7501`）
2. 在一個 Rex block 開 client：`herdr --session osc7501-test`
3. 在另一個 shell 送狀態：`herdr --session osc7501-test pane report-agent w1:p1 --source test --agent claude --state working --seq 1`
4. 讀 Rex 的 record（block id 用 `rex block ls` 查）：`rex block call -b <block-id> program_status`
5. hook 的紀錄在 `~/.local/state/herdr/plugins/musingfox.osc7501/log.txt`（有設 `XDG_STATE_HOME` 時在 `$XDG_STATE_HOME/herdr/plugins/musingfox.osc7501/log.txt`）。
6. 結束後：`herdr session stop osc7501-test`。要改回從 GitHub 安裝時，先 `herdr plugin unlink musingfox.osc7501`；同一個 id 還連結在本機時，`herdr plugin install` 會拒絕。
