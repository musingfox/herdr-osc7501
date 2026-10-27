#!/bin/bash
# POC: forward herdr agent status to the outer terminal as OSC 7501.
# Plugins have no outer-terminal API, so write to the tty of every attached client of this session.
# herdr unsets HERDR_SESSION for the default session.
session=${HERDR_SESSION:-default}

pane=$(jq -r '.data.pane_id' <<<"$HERDR_PLUGIN_EVENT_JSON")
id=${pane//:/.}

# herdr has no client list API, so match the client argv forms: herdr, herdr --session S, herdr session attach S.
ttys=$(ps -axo tty=,command= | awk -v s="$session" '$1 != "??" && $2 ~ /(^|\/)herdr$/ &&
  ((NF == 2 && s == "default") || (NF == 4 && $3 == "--session" && $4 == s "") || (NF == 5 && $3 == "session" && $4 == "attach" && $5 == s "")) {print $1}' | sort -u)

# The event's status may already be stale, so read the pane's current one; fall back to the event if pane get fails.
current() {
  local info status agent cwd body
  info=$("$HERDR_BIN_PATH" pane get "$pane" 2>/dev/null | jq -c '.result.pane // empty')
  [ -n "$info" ] || info=$(jq -c '.data' <<<"$HERDR_PLUGIN_EVENT_JSON")
  status=$(jq -r '.agent_status // empty' <<<"$info")
  agent=$(jq -r '.agent // empty' <<<"$info" | tr -cd 'A-Za-z0-9_.+-' | cut -c1-32)
  cwd=$(jq -r '.cwd // empty' <<<"$info")
  case "$status" in
    idle|working|blocked|done) body="state=$status:id=$id" ;;
    *) body="state=clear:id=$id" ;;
  esac
  if [ "$body" != "state=clear:id=$id" ]; then
    [ -n "$agent" ] && body="$body:app=$agent"
    [ -n "$cwd" ] && body="$body:title=$(printf '%s' "${cwd##*/}" | base64 | tr -d '\n')"
  fi
  printf '%s' "$body"
}

# Hooks run unserialized and finish out of order, and OSC 7501 has no sequence number, so the last write wins.
# Rewrite until a re-read matches the last write; a status change after that re-read fires a new event.
body=$(current)
for _ in 1 2 3; do
  for tty in $ttys; do
    printf '\e]7501;%s\e\134' "$body" > "/dev/$tty"
  done
  echo "$(date +%T) $session $body" >> "$HERDR_PLUGIN_STATE_DIR/log.txt"
  written=$body
  body=$(current)
  [ "$body" = "$written" ] && break
done
