#!/bin/bash
# Daily chart build. Leaves quietly while another chart build runs; runs the alert command on failure.
set -uo pipefail
# A site file that cannot be loaded stops the job: running on defaults would use the wrong folder.
site="$(dirname "$0")/site.env"; [ ! -f "$site" ] || . "$site" || exit 78
home=${CHARTPIPE_HOME:-/srv/chartpipe}
envfile=${CHARTPIPE_ENV:-$home/r2.env}
# The alert command gets a subject and a detail. Unquoted on purpose: it may carry arguments of its own.
CHARTPIPE_NOTIFY=${CHARTPIPE_NOTIFY:-}
log=$home/last-run.log
mkdir -p "$home/work"
# One national build at a time: a build started by hand wins.
[ -z "$(docker ps -q --filter name=chartpipe)" ] || exit 0
docker run --rm --name chartpipe-daily --cpus=12 --cpu-shares=512 --memory=24g -e GDAL_CACHEMAX=1024 \
  --env-file "$envfile" -v "$home/work:/work" chartpipe --work /work/daily > "$log" 2>&1
status=$?
if [ $status -ne 0 ]; then
  [ -z "$CHARTPIPE_NOTIFY" ] || $CHARTPIPE_NOTIFY "Chart pipeline failed" "$(tail -3 "$log")"
fi
exit $status
