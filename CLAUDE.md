# herdr-osc7501 development guide

What the plugin does and how it behaves is in [README.md](README.md). This file holds only what you need to know while developing and cannot read from the code.

## Files

- `hook.sh`: the only program. Every event runs it, branching on `$HERDR_PLUGIN_EVENT`.
- `herdr-plugin.toml`: the manifest. Add an `[[events]]` entry here for a new event.
- There is no build step and no automated test suite. Dependencies are bash (macOS `/bin/bash` 3.2), `jq`, `ps` and `awk`.

## Run after every change

- `bash -n hook.sh`
- `uvx --from shellcheck-py shellcheck hook.sh`. Fix findings; do not add suppressions.

## Design trade-offs

Each of these was tried or weighed. Read the reason before changing one.

- **No lock.** A per-pane `mkdir` lock once serialized the hooks, and two review rounds each reproduced new defects: an endless wait when `mkdir` fails with anything but EEXIST, two holders at once while clearing a stale lock, and a slow holder losing its lock. herdr has no hook timeout, so a stuck hook holds one of the server's 32 plugin-command slots and stalls every plugin. The hook now writes, re-reads and rewrites on change (`forward()`). Keep the invariant: a hook's final re-read equals its last write, with at most 3 rounds.
- **Status comes from `pane get`, not the event JSON.** Events carry no sequence number and hooks finish out of order. `pane_not_found` always means clear; otherwise a hook finishing after a close writes the closed pane's record back. Only other errors count as transient and fall back to the event JSON or the `pane list` entry.
- **A bare `state=clear` goes out only after `pane list` succeeds and parses.** It wipes every record on the terminal, including the other side of a same-name session.
- **Clients are found by argv.** herdr has no API to list clients, and the server does not record their ttys. Compare the session name as a string (`s ""`), or awk treats `7` and `07` as equal. A more precise approach, not implemented, is to map each client's unix socket peer with `lsof` to the server's fd on `herdr-client.sock`.
- **The title is built in jq.** BSD `cut -c` counts bytes, and `tr` cannot match the two-byte C1 control characters. Rex's limits are in §Limits of the [Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status.md).

## Testing

The user's herdr server lives in `~/.config/herdr`, and its default session has several real clients (Rex blocks and mosh sessions). Never link into the real server or `report-agent` into real panes while testing.

Isolated setup:

1. Make a short symlink to a scratchpad dir, for example `/private/tmp/claude-501/h1 -> <scratchpad>/iso`. A long path exceeds the unix socket `sun_path` limit.
2. Prefix every herdr command with `XDG_CONFIG_HOME=/private/tmp/claude-501/h1/config XDG_STATE_HOME=/private/tmp/claude-501/h1/state`. Confirm with `herdr status` that the socket is under the symlink before `herdr plugin link .`.
3. Use only unique named sessions (`herdr --session osc7501x`). An isolated `default` session has the same argv as the user's real default clients and would write into them.
4. Open the client in a background Rex block: `rex run -s "$REX_SESSION" --focus=false --shell=none -- env XDG_CONFIG_HOME=… XDG_STATE_HOME=… herdr --session osc7501x`.
5. Read records with `rex block call -b <block-id> program_status`. The hook log is `$XDG_STATE_HOME/herdr/plugins/<plugin-id>/log.txt`; hooks dropped at the 32 cap show up in `herdr plugin log list`.
6. When done: unlink, `herdr session stop`, close the block, remove the symlink.

herdr behavior to know:

- The CLI rejects `report-agent --state done`. `done` is derived when an unseen pane in a background tab goes from `working` to `idle`, so put the pane in a background tab to test `done`.
- To test without running herdr, put a `ps` stub that prints nothing first on `PATH`, point `HERDR_BIN_PATH` at a fake herdr script, and run `bash hook.sh` with `HERDR_PLUGIN_EVENT`, `HERDR_PLUGIN_EVENT_JSON` and `HERDR_PLUGIN_STATE_DIR` set.
- Check herdr behavior in its source: `git clone --branch v0.9.5 https://github.com/herdrdev/herdr`. Event payloads are in `src/api/schema/events.rs`, and the hook execution model is in `src/app/api/plugins/runtime.rs`.

## Release

1. Bump `version` in `herdr-plugin.toml` and the `--ref` example in the README.
2. Merge to `main`, tag `vX.Y.Z`, push the commits and the tag.
3. To verify, first `herdr plugin unlink musingfox.osc7501` (install refuses while the same id is linked locally), then `herdr plugin install musingfox/herdr-osc7501 --ref vX.Y.Z -y`. On the real server, open a throwaway workspace, report one status, confirm Rex receives the record, then close the workspace.

## Workflow

- Commits follow Conventional Commits, one commit per milestone. The message says what changed, why, and what was rejected.
- Task cards live in the Obsidian vault under `pm/herdr-osc7501/tasks/` (configured in `.obsidian.yaml`, managed with `/obw:pm`).
