#!/bin/bash
# Checks the jobs from outside, every 15 minutes. Alerts when a check turns stale and every six hours while it stays so; a fresh check says nothing.
set -uo pipefail
# A site file that cannot be loaded stops the job: running on defaults would use the wrong folder.
site="$(dirname "$0")/site.env"; [ ! -f "$site" ] || . "$site" || exit 78
home=${CHARTPIPE_HOME:-/srv/chartpipe}
CHARTPIPE_NOTIFY=${CHARTPIPE_NOTIFY:-}
# Public address of the bucket the apps read.
base=${CHARTPIPE_PUBLIC_URL:-}
# Minutes the weather index may go without a check, hours a daily job's log may go unwritten, hours between repeat alerts.
# A daily job skips its turn while another build runs, so one missed day stays quiet.
wx_minutes=30
daily_hours=50
repeat_hours=6
state=$home/watch.state
now=$(date +%s)
# Runs the alert command, if there is one, with a subject and a detail. Unquoted on purpose: it may carry arguments.
alert() { [ -z "$CHARTPIPE_NOTIFY" ] || $CHARTPIPE_NOTIFY "$1" "$2"; }

# Says what is wrong with the published weather index, or nothing when its newest check is recent.
wx_problem() {
  local url=${base%/}/wx/index.json body newest
  [ -n "$base" ] || { echo "CHARTPIPE_PUBLIC_URL is not set"; return; }
  body=$(curl -fsS --max-time 30 "$url" 2>&1) || { echo "cannot read $url: $body"; return; }
  newest=$(jq -r '[.checked_at[]? | strings | fromdateiso8601] | max // 0' <<< "$body" 2>/dev/null)
  [ "${newest:-0}" -gt 0 ] || { echo "$url lists no check times"; return; }
  [ $((now - newest)) -le $((wx_minutes * 60)) ] || echo "the newest check in $url is $(( (now - newest) / 60 )) minutes old"
}

# Says what is wrong with a daily job's log, or nothing when it was written recently.
log_problem() {
  [ -f "$home/$1" ] || { echo "$1 is missing"; return; }
  [ -z "$(find "$home/$1" -mmin +$((daily_hours * 60)))" ] || echo "$1 has not been written in over $daily_hours hours"
}

# State, one line per stale check: its name and when it was last alerted. An alert that fails is not recorded, so the next turn tries again.
new=
check() {
  local last
  last=$(sed -n "s/^$1 //p" "$state" 2>/dev/null)
  [ -n "$3" ] || return 0
  if [ -z "$last" ] || [ $((now - last)) -ge $((repeat_hours * 3600)) ]; then
    alert "$2" "$3" && last=$now
  fi
  [ -z "$last" ] || new+="$1 $last"$'\n'
}

check wx "Weather mirror not publishing" "$(wx_problem)"
check tpp-run.log "Plates pipeline not running" "$(log_problem tpp-run.log)"
check nav-run.log "Nav pipeline not running" "$(log_problem nav-run.log)"
check last-run.log "Chart pipeline not running" "$(log_problem last-run.log)"
# Through a file beside it, so a write that fails, as on a full disk, keeps the last state.
printf '%s' "$new" > "$state.new" && mv -f "$state.new" "$state" || { rm -f "$state.new"; exit 1; }
