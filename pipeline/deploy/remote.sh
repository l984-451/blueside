#!/bin/bash
# Syncs the pipeline to the build server and runs it there.
# usage: remote.sh build | run <chartpipe args> | publish <chartpipe args> | sh <command inside the image>
# CHARTPIPE_DEV=1 switches to a separate source folder and image, so unfinished code never replaces production.
set -euo pipefail
site="$(dirname "$0")/site.env"; [ -f "$site" ] && . "$site"
: "${CHARTPIPE_HOST:?set CHARTPIPE_HOST to the server ssh address}"
here="$(cd "$(dirname "$0")/.." && pwd)"
remote=${CHARTPIPE_REMOTE_HOME:-/srv/chartpipe}
envfile=${CHARTPIPE_REMOTE_ENV:-$remote/r2.env}
dev=${CHARTPIPE_DEV:+-dev}
src=$remote/src$dev
image=chartpipe$dev
mode="$1"; shift
# Keep macOS metadata files out of the archive.
export COPYFILE_DISABLE=1
# The production image is built from the last commit, never from edits in progress; the dev image takes the working tree.
if [ "$mode" = build ] && [ -z "$dev" ]; then
  changes=$(git -C "$here" status --porcelain -- .) || exit 2
  if [ -n "$changes" ]; then
    echo "the pipeline has uncommitted changes: commit them, or build the dev image with CHARTPIPE_DEV=1" >&2
    exit 2
  fi
  pack() { git -C "$here/.." archive --format=tar.gz "HEAD:$(basename "$here")" "$@"; }
else
  pack() { tar -C "$here" --exclude __pycache__ --exclude .pytest_cache -czf - "$@"; }
fi
pack Dockerfile requirements.txt chartpipe navpipe tppipe wxpipe tests \
  | ssh "$CHARTPIPE_HOST" "mkdir -p $src $remote/work && rm -rf $src/chartpipe $src/navpipe $src/tppipe $src/wxpipe $src/tests && tar -xzf - -C $src"
mount="-v $remote/work:/work"
# The server is shared: cap every container.
limits="--cpus=12 --cpu-shares=512 --memory=24g -e GDAL_CACHEMAX=1024"
case "$mode" in
  build)   ssh "$CHARTPIPE_HOST" "cd $src && docker build -q -t $image ." ;;
  run)     ssh "$CHARTPIPE_HOST" "docker run --rm $limits $mount $image $*" ;;
  publish) [ -z "$dev" ] || { echo "publish runs the production image only" >&2; exit 2; }
           ssh "$CHARTPIPE_HOST" "docker run --rm --name chartpipe-manual $limits --env-file $envfile $mount $image $*" ;;
  sh)      ssh "$CHARTPIPE_HOST" "docker run --rm $limits -e CHARTPIPE_SMALL_RUN=1 $mount --entrypoint bash $image -c $(printf '%q' "$*")" ;;
  *)       echo "unknown mode: $mode" >&2; exit 2 ;;
esac
