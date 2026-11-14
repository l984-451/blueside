#!/bin/bash
# Daily airport diagram and procedure build. Leaves quietly while another build runs; runs the alert command on failure.
set -uo pipefail
# A site file that cannot be loaded stops the job: running on defaults would use the wrong folder.
site="$(dirname "$0")/site.env"; [ ! -f "$site" ] || . "$site" || exit 78
home=${CHARTPIPE_HOME:-/srv/chartpipe}
envfile=${CHARTPIPE_ENV:-$home/r2.env}
# The alert command gets a subject and a detail. Unquoted on purpose: it may carry arguments of its own.
CHARTPIPE_NOTIFY=${CHARTPIPE_NOTIFY:-}
log=$home/tpp-run.log
mkdir -p "$home/work"
# One national build at a time: a build started by hand wins.
[ -z "$(docker ps -q --filter name=chartpipe)" ] || exit 0
docker run --rm --name chartpipe-tpp --cpus=4 --cpu-shares=512 --memory=4g \
  --env-file "$envfile" -v "$home/work:/work" \
  --entrypoint python3 chartpipe -m tppipe --work /work/tpp > "$log" 2>&1
status=$?
# A published cycle needs none of its PDFs again; a failed run keeps them for the retry.
[ $status -ne 0 ] || rm -rf "$home/work/tpp"
if [ $status -ne 0 ]; then
  [ -z "$CHARTPIPE_NOTIFY" ] || $CHARTPIPE_NOTIFY "Plates pipeline failed" "$(tail -3 "$log")"
fi
exit $status
