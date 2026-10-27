#!/bin/bash
# POC: forward herdr agent status to the outer terminal as OSC 7501.
# Plugins have no outer-terminal API, so write to the tty of every attached client of this session.
case "$HERDR_SESSION" in poc7501) ;; *) exit 0;; esac

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

session_args="--session $HERDR_SESSION"
for tty in $(ps -axo tty=,command= | awk -v s="$session_args" '$1 != "??" && $2 ~ /(^|\/)herdr$/ && index($0, s) {print $1}' | sort -u); do
  printf '\e]7501;%s\e\\' "$body" > "/dev/$tty"
done
echo "$(date +%T) $body" >> "$HERDR_PLUGIN_STATE_DIR/log.txt"
