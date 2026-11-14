#!/bin/bash
# Weather mirror, every five minutes. Skips a turn while the last one runs; alerts on the third failure in a row.
set -uo pipefail
# A site file that cannot be loaded stops the job: running on defaults would use the wrong folder.
site="$(dirname "$0")/site.env"; [ ! -f "$site" ] || . "$site" || exit 78
home=${CHARTPIPE_HOME:-/srv/chartpipe}
envfile=${CHARTPIPE_ENV:-$home/r2.env}
CHARTPIPE_NOTIFY=${CHARTPIPE_NOTIFY:-}
# Runs the alert command, if there is one, with a subject and a detail. Unquoted on purpose: it may carry arguments.
alert() { [ -z "$CHARTPIPE_NOTIFY" ] || $CHARTPIPE_NOTIFY "$1" "$2"; }
log=$home/wx-run.log
count=$home/wx-run.failures
skips=$home/wx-run.skips
mkdir -p "$home/work/wx"
# A lock of its own: chart builds never hold it, and it goes when this script ends, however it ends.
exec 9> "$home/wx-run.lock"
flock -n 9
status=$?
# 1 means the last turn still holds the lock. Three skipped turns in a row mean that turn is stuck.
if [ $status -eq 1 ]; then
  skipped=$(( $(cat "$skips" 2>/dev/null || echo 0) + 1 ))
  echo "$skipped" > "$skips"
  [ "$skipped" -eq 3 ] && alert "Weather mirror stuck" "the last run still holds the lock"
  exit 0
fi
rm -f "$skips"
# Any other lock failure is counted below, never run unlocked.
if [ $status -eq 0 ]; then
  # The timeout ends a run that hangs on a slow server, so the next turn is never blocked for good.
  docker run --rm --name wxpipe --cpus=2 --cpu-shares=512 --memory=4g \
    --env-file "$envfile" -v "$home/work:/work" \
    --entrypoint timeout chartpipe 240 python3 -m wxpipe --work /work/wx > "$log" 2>&1
  status=$?
else
  echo "could not take the lock: flock exit $status" > "$log"
fi
if [ $status -eq 0 ]; then
  rm -f "$count"
  exit 0
fi
cp "$log" "$home/wx-run.failed.log"
# State, one per line: failures in a row, turns in a row with the same cause, that cause, the cause last alerted.
what=$(grep '^failed sources:' "$log" | tail -1)
[ -n "$what" ] || what="exit $status"
failures=$(( $(sed -n 1p "$count" 2>/dev/null || echo 0) + 1 ))
same=1
[ "$what" = "$(sed -n 3p "$count" 2>/dev/null)" ] && same=$(( $(sed -n 2p "$count" 2>/dev/null || echo 0) + 1 ))
alerted=$(sed -n 4p "$count" 2>/dev/null)
# Alerts on the third failure in a row, when a new cause has lasted three turns, and every six hours after.
if [ $(( failures % 72 )) -eq 3 ] || { [ "$same" -eq 3 ] && [ "$what" != "$alerted" ]; }; then
  alert "Weather mirror failing" "$(tail -3 "$log")"
  alerted=$what
fi
# A count that cannot be saved would never reach three, so that is an alert of its own.
printf '%s\n%s\n%s\n%s\n' "$failures" "$same" "$what" "$alerted" > "$count" \
  || alert "Weather mirror failing" "cannot write $count (disk full?)"
exit $status
