#!/bin/bash
# POC: forward herdr agent status to the outer terminal as OSC 7501.
# Plugins have no outer-terminal API, so write to the tty of every attached client of this session.
# herdr unsets HERDR_SESSION for the default session.
session=${HERDR_SESSION:-default}

# herdr has no client list API, so match the client argv forms: herdr, herdr --session S, herdr session attach S.
ttys=$(ps -axo tty=,command= | awk -v s="$session" '$1 != "??" && $2 ~ /(^|\/)herdr$/ &&
  ((NF == 2 && s == "default") || (NF == 4 && $3 == "--session" && $4 == s "") || (NF == 5 && $3 == "session" && $4 == "attach" && $5 == s "")) {print $1}' | sort -u)

emit() {
  for tty in $ttys; do
    printf '\e]7501;%s\e\134' "$1" > "/dev/$tty"
  done
  echo "$(date +%T) $session $1" >> "$HERDR_PLUGIN_STATE_DIR/log.txt"
}

# Rex discards the whole report if the decoded title has a Cc character or exceeds 192 bytes, so drop those and cut on a character boundary.
title() {
  jq -nr --arg s "$1" '$s | gsub("\\p{Cc}"; "") | [foreach explode[] as $c (0; . + ([$c] | implode | utf8bytelength); select(. <= 192) | $c)] | implode | @base64'
}

# The event's status may already be stale, so read the pane's current one.
# A closed pane reads as clear, so a hook racing the close cannot restore its record; other failures are transient, so fall back to what the event or pane list reported.
current() {
  local info status agent cwd body
  info=$("$HERDR_BIN_PATH" pane get "$pane" 2>&1 | jq -c '.result.pane // if .error.code == "pane_not_found" then {} else empty end' 2>/dev/null)
  [ -n "$info" ] || info=$fallback
  # A released agent can leave its last status on the pane, so a pane without an agent reads as clear.
  status=$(jq -r 'if .agent then .agent_status else empty end' <<<"$info")
  agent=$(jq -r '.agent // empty' <<<"$info" | tr -cd 'A-Za-z0-9_.+-' | cut -c1-32)
  cwd=$(jq -r '.cwd // empty' <<<"$info")
  case "$status" in
    idle|working|blocked|done) body="state=$status:id=$id" ;;
    *) body="state=clear:id=$id" ;;
  esac
  if [ "$body" != "state=clear:id=$id" ]; then
    [ -n "$agent" ] && body="$body:app=$agent"
    [ -n "$cwd" ] && body="$body:title=$(title "${cwd##*/}")"
  fi
  printf '%s' "$body"
}

# Hooks run unserialized and finish out of order, and OSC 7501 has no sequence number, so the last write wins.
# Rewrite until a re-read matches the last write; a status change after that re-read fires a new event.
forward() {
  local body written
  id=${pane//:/.}
  body=$(current)
  for _ in 1 2 3; do
    emit "$body"
    written=$body
    body=$(current)
    [ "$body" = "$written" ] && break
  done
}

case "$HERDR_PLUGIN_EVENT" in
  # herdr sends no pane.closed for the panes of a closed tab or workspace, and the event names none.
  # A bare clear also wipes the live panes' records, so it goes out only after pane list succeeds.
  tab.closed|workspace.closed)
    list=$("$HERDR_BIN_PATH" pane list) || exit
    panes=$(jq -r '.result.panes[].pane_id' <<<"$list") || exit
    emit "state=clear"
    for pane in $panes; do
      fallback=$(jq -c --arg p "$pane" '.result.panes[] | select(.pane_id == $p)' <<<"$list")
      forward
    done
    ;;
  *)
    pane=$(jq -r '.data.pane_id // .data.pane.pane_id' <<<"$HERDR_PLUGIN_EVENT_JSON")
    fallback=$(jq -c '.data.pane // .data' <<<"$HERDR_PLUGIN_EVENT_JSON")
    # A move to another workspace changes the pane id, so drop the record under the old one.
    previous=$(jq -r '.data.previous_pane_id // empty' <<<"$HERDR_PLUGIN_EVENT_JSON")
    [ -n "$previous" ] && [ "$previous" != "$pane" ] && emit "state=clear:id=${previous//:/.}"
    forward
    ;;
esac
