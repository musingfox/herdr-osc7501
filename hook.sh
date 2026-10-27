#!/bin/bash
# POC: forward herdr agent status to the outer terminal as OSC 7501.
# Plugins have no outer-terminal API, so write to the tty of every attached client of this session.
# herdr unsets HERDR_SESSION for the default session.
session=${HERDR_SESSION:-default}

data=$(jq -c '.data' <<<"$HERDR_PLUGIN_EVENT_JSON")
pane=$(jq -r '.pane_id' <<<"$data")
status=$(jq -r '.agent_status' <<<"$data")
agent=$(jq -r '.agent // empty' <<<"$data" | tr -cd 'A-Za-z0-9_.+-' | cut -c1-32)
id=${pane//:/.}

case "$status" in
  idle|working|blocked|done) body="state=$status:id=$id" ;;
  *) body="state=clear:id=$id" ;;
esac
if [ "$body" != "state=clear:id=$id" ]; then
  [ -n "$agent" ] && body="$body:app=$agent"
  cwd=$("$HERDR_BIN_PATH" pane get "$pane" 2>/dev/null | jq -r '.result.pane.cwd // empty')
  [ -n "$cwd" ] && body="$body:title=$(printf '%s' "${cwd##*/}" | base64 | tr -d '\n')"
fi

# herdr has no client list API, so match the client argv forms: herdr, herdr --session S, herdr session attach S.
ps -axo tty=,command= | awk -v s="$session" '$1 != "??" && $2 ~ /(^|\/)herdr$/ &&
  ((NF == 2 && s == "default") || (NF == 4 && $3 == "--session" && $4 == s "") || (NF == 5 && $3 == "session" && $4 == "attach" && $5 == s "")) {print $1}' |
  sort -u | while read -r tty; do
    printf '\e]7501;%s\e\134' "$body" > "/dev/$tty"
  done
echo "$(date +%T) $session $body" >> "$HERDR_PLUGIN_STATE_DIR/log.txt"
