# herdr-osc7501

A herdr plugin that reports the agent status of every herdr pane to the outer terminal as OSC 7501 ([Rex Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status.md)). It works in every herdr session, including the default one.

## Install

Requires herdr 0.9.5 or later, macOS and `jq`.

```
herdr plugin install musingfox/herdr-osc7501
```

Add `--ref v0.1.0` to pin a version. Update with `herdr plugin update musingfox.osc7501` and remove with `herdr plugin uninstall musingfox.osc7501`.

## What you get

- Run a herdr client inside Rex. When an agent in a pane changes status, Rex records it on the block that hosts the client, and unfocused tabs show an in-progress or waiting marker.
- A record's id is the pane id with `:` replaced by `.`, for example `w1.p3`. `app` is the agent name herdr detected, and `title` is the last segment of the pane's cwd.
- To inspect the records, find the client's block with `rex block ls`, then run `rex block call -b <block-id> program_status`.
- Every write is logged to `~/.local/state/herdr/plugins/musingfox.osc7501/log.txt`, or `$XDG_STATE_HOME/herdr/plugins/musingfox.osc7501/log.txt` when `XDG_STATE_HOME` is set.

## Why a plugin is needed

- herdr emulates each pane's terminal and does not answer the `OSC 7501;?` query; it replies only to DA1 (`ESC[?62;22c`). Without a reply, Claude Code never sends OSC 7501, so agents inside panes never report.
- herdr plugins have no API for writing to the outer terminal. Plugins run in the server, and the outer terminal belongs to the client.
- Rex's API can read `program_status` but cannot write it.

So the hook writes straight to the tty of each herdr client. Rex records it on that block, owned by the herdr client.

## How it works

- `pane.agent_status_changed`, `pane.agent_detected`, `pane.closed`, `pane.exited`, `pane.moved`, `tab.closed` and `workspace.closed` all run `hook.sh`.
- The status in the event JSON may already be stale, so the hook reads the pane's current status with `herdr pane get`. Any `pane get` error other than `pane_not_found` is treated as transient, and the hook falls back to the event JSON, or, during a tab or workspace resync, to that pane's entry in `pane list`.
- Hooks are not serialized and finish in any order. After writing, a hook re-reads the status and rewrites if it changed, for at most three rounds.
- Status mapping: `idle`, `working`, `blocked` and `done` are sent as is. Anything else (`unknown`) sends `state=clear:id=…`.
- The hook also sends `state=clear` when:
  - `pane get` returns `pane_not_found`, meaning the pane has closed or exited. A status hook that finishes after the close therefore cannot write the record back.
  - the pane has no agent, meaning the agent was released. A released pane can keep its last status.
  - on `pane.moved`, the old pane id differs from the new one (this happens only across workspaces). The old id is cleared before the new one is written.
- When a tab or workspace closes, herdr sends no `pane.closed` for the panes inside it, and the event names no pane. The hook reads `herdr pane list`, sends a bare `state=clear` to wipe every record on the terminal, then rewrites each live pane as above. If `pane list` fails, nothing is sent.
- `:` is not allowed in an OSC 7501 id, so pane ids use `.` instead (`w1:p1` → `w1.p1`).
- `title` is the last segment of the pane's cwd, with control characters removed and cut to 192 bytes on a character boundary.

## Known limitations

- herdr has no client attach or detach event, so the hook sends no clear on detach. Rex drops `working` and `blocked` (and may drop `idle`) when the program in the terminal exits or at the next OSC 133 A prompt, but `done` stays on the old block.
- Client ttys are found by matching client argv with `ps`. Only `herdr` (default session), `herdr --session <name>` and `herdr session attach <name>` are recognized. Clients started with `--session=<name>` are missed. A client that selects its session through the environment (for example `HERDR_SESSION=x herdr`) has the bare argv `herdr`, so it misses its own session's records and receives the default session's instead.
- Two sessions with the same name under different config dirs cannot be told apart by argv, so both sets of clients receive the records. When one side closes a tab or workspace, its bare `state=clear` also wipes the other side's records until each of those panes fires its next event.
- `herdr --remote <host>` clients receive nothing: their argv does not match, and the remote server's hook runs `ps` on the remote host.
- A client that also keeps an ssh thin-client connection to another host (`herdr remote-client-bridge`) still matches by argv, so it receives the local server's records even while showing remote panes. Whether this shows wrong status has not been verified.
- herdr runs at most 32 plugin commands per server at once and drops the rest. Hooks do not wait on each other, so only a burst of events hits the cap. If the last event's hook is dropped and every running hook has already done its final re-read, the record stays stale until the next event. If the dropped hook is a `pane.closed`, that pane never fires again, and its record stays until a later tab or workspace resync clears it.
- During a tab or workspace resync, a pane id that appears after `pane list` was read, and whose hook writes before the resync's clear, loses its record until that pane's next event. New panes and panes concurrently moved to another workspace (which changes their id) can hit this.
- If a pane closes while the `pane get` behind a hook's last write returns an error other than `pane_not_found`, the hook falls back to the event JSON or the `pane list` entry and leaves a record for the closed pane. Hooks for `pane.agent_status_changed` and `pane.moved` and the tab or workspace resync can hit this. The event JSON of `pane.closed`, `pane.exited` and `pane.agent_detected` has no `agent_status`, so their fallback sends a clear.
- The text of `report-agent --message` is not in the event JSON, `pane get` or `agent list`, so no `msg` is sent. `kind` has no source either.
- Writing to the tty from outside interleaves with herdr's own screen output. A stress test of 300 writes left no stray characters on screen, but momentary glitches were not measured.
- The real fix is for the herdr client to emit OSC 7501 natively on status changes. The client already writes the window title and OSC notifications to the outer terminal.

## Development

The development workflow, testing approach and design trade-offs are in [CLAUDE.md](CLAUDE.md).
