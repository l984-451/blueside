import argparse
import gzip
import json
import signal
import sys
import traceback
from datetime import datetime, timedelta, timezone
from pathlib import Path

from chartpipe import faa
from chartpipe.publish import r2_store_from_env

from . import awc, fb, goes, radar, tfr

PREFIX = "wx/"
# Phones trust a radar index for this long after its newest frame.
GRACE = timedelta(minutes=20)
NAMES = ("metars", "tafs", "sigmets", "gairmets", "cwas", "pireps", "tfrs", "winds", "radar", "satellite", "lightning")
# name -> (object name under the prefix, builder taking (fetch, work, now) and returning checked JSON bytes).
# Fetched in this order after radar and satellite: the ones that age fastest first, the many-request ones last.
SOURCES = {
    "lightning": ("lightning.json.gz", goes.lightning_json),
    "metars": ("metars.json.gz", lambda fetch, work, now: awc.metars_json(
        fetch(awc.CACHE + "metars.cache.csv.gz"), awc.stations(fetch, work), now)),
    "tafs": ("tafs.json.gz", lambda fetch, work, now: awc.tafs_json(
        fetch(awc.CACHE + "tafs.cache.xml.gz"), awc.stations(fetch, work), now)),
    "sigmets": ("sigmets.geojson.gz", lambda fetch, work, now: awc.sigmets_geojson(
        fetch(awc.CACHE + "airsigmets.cache.xml.gz"))),
    "gairmets": ("gairmets.geojson.gz", lambda fetch, work, now: awc.gairmets_geojson(
        fetch(awc.CACHE + "gairmets.cache.xml.gz"), now)),
    "cwas": ("cwas.geojson.gz", lambda fetch, work, now: awc.cwas_geojson(fetch(awc.CWAS))),
    "pireps": ("pireps.json.gz", lambda fetch, work, now: awc.pireps_json(
        fetch(awc.CACHE + "aircraftreports.cache.xml.gz"))),
    "tfrs": ("tfrs.geojson.gz", lambda fetch, work, now: tfr.build(fetch, work)),
    "winds": ("winds.json.gz", fb.build),
}
# Sources refetched only once their last good fetch is this old.
REFETCH = {"winds": fb.REFETCH}


def load_state(work: Path) -> dict:
    try:
        return json.loads((work / "state.json").read_text())
    except (OSError, ValueError):
        return {}


def save_state(work: Path, state: dict) -> None:
    scratch = work / "state.json.new"
    scratch.write_text(json.dumps(state))
    scratch.replace(work / "state.json")


def put(store, work: Path, key: str, body: bytes, content_type: str, cache: str) -> None:
    """Stores one object in the bucket when publishing, otherwise under <work>/out."""
    if store is not None:
        store.client.put_object(Bucket=store.bucket, Key=key, Body=body,
                                ContentType=content_type, CacheControl=cache)
        return
    local = work / "out" / key
    local.parent.mkdir(parents=True, exist_ok=True)
    local.write_bytes(body)


def add_frame(fetch, work: Path, now: datetime, store, state: dict, build_frame) -> None:
    """Builds and stores the newest radar frame unless the loop already has it."""
    found = radar.latest(fetch, now)
    if found is None:
        raise awc.BadSource("radar: no frames listed")
    source_key, valid = found
    frames = state.setdefault("frames", [])
    stamp = faa.iso(valid)
    if any(frame["valid"] == stamp for frame in frames):
        return
    grib = work / "radar.grib2.gz"
    grib.write_bytes(fetch(radar.BUCKET + source_key))
    built = work / "radar.pmtiles"
    build_frame(grib, built)
    key = f"{PREFIX}radar/{valid:%Y%m%d-%H%M%S}.pmtiles"
    put(store, work, key, built.read_bytes(), "application/octet-stream", "public, max-age=86400, immutable")
    frames.append({"valid": stamp, "path": key})
    frames.sort(key=lambda frame: frame["valid"])
    # Frames from before a gap in runs go at once, so the loop never mixes old pictures with new ones.
    cutoff = faa.iso(valid - radar.SPAN)
    keep = [frame for frame in frames if frame["valid"] >= cutoff][-radar.FRAMES:]
    state.setdefault("drop", []).extend(frame["path"] for frame in frames if frame not in keep)
    frames[:] = keep


def add_satellite(fetch, work: Path, now: datetime, store, state: dict, build_ir) -> None:
    """Builds and stores the newest infrared picture unless the index already names it."""
    found = goes.latest_ir(fetch, now)
    if found is None:
        raise awc.BadSource("satellite: no pictures listed")
    pictures, valid = found
    stamp = faa.iso(valid)
    old = state.get("satellite")
    if old and old["valid"] >= stamp:
        return
    files = []
    for i, (satellite, key) in enumerate(pictures):
        files.append(work / f"satellite-{i}.nc")
        files[-1].write_bytes(fetch(goes.bucket(satellite) + key))
    built = work / "satellite.pmtiles"
    build_ir(files, built)
    key = f"{PREFIX}satellite/{valid:%Y%m%d-%H%M%S}.pmtiles"
    put(store, work, key, built.read_bytes(), "application/octet-stream", "public, max-age=86400, immutable")
    if old:
        state.setdefault("drop", []).append(old["path"])
    state["satellite"] = {"valid": stamp, "path": key}


def drop_old(store, work: Path, state: dict, now: datetime) -> None:
    """Deletes pictures no index names any more: only keys this worker recorded, only radar and satellite ones."""
    for key in list(state.get("drop", [])):
        folder = key[len(PREFIX):].split("/")[0]
        # A replaced satellite picture is named only by indexes a phone trusts for GRACE after.
        keep = {"radar": radar.SPAN + GRACE, "satellite": 2 * GRACE}.get(folder)
        if not (key.startswith(PREFIX) and keep and key.endswith(".pmtiles")):
            raise ValueError(f"refusing to delete {key}")
        valid = datetime.strptime(key[len(PREFIX + folder + "/"):-len(".pmtiles")], "%Y%m%d-%H%M%S")
        if now - valid.replace(tzinfo=timezone.utc) <= keep:
            continue
        if store is not None:
            store.client.delete_object(Bucket=store.bucket, Key=key)
        else:
            (work / "out" / key).unlink(missing_ok=True)
        state["drop"].remove(key)


def run(work: Path, fetch, now: datetime, store=None, build_frame=radar.build_frame, build_ir=goes.build_ir) -> list[str]:
    """One pass over every source. Returns the names that failed."""
    work.mkdir(parents=True, exist_ok=True)
    awc.DEGRADED.clear()
    state = load_state(work)
    checked = state.setdefault("checked_at", {})
    state.setdefault("drop", [])
    failed = []
    try:
        # Radar and satellite go first: they age in minutes, and a slow host later in the turn must not cost them it.
        try:
            add_frame(fetch, work, now, store, state, build_frame)
            checked["radar"] = faa.iso(now)
        except Exception:
            traceback.print_exc()
            failed.append("radar")
        try:
            add_satellite(fetch, work, now, store, state, build_ir)
            checked["satellite"] = faa.iso(now)
        except Exception:
            traceback.print_exc()
            failed.append("satellite")
        for name, (file_name, build) in SOURCES.items():
            last = checked.get(name)
            if name in REFETCH and last and now - datetime.fromisoformat(last) < REFETCH[name]:
                continue
            try:
                body = gzip.compress(build(fetch, work, now), mtime=0)
                put(store, work, PREFIX + file_name, body, "application/gzip", "max-age=60")
                checked[name] = faa.iso(now)
            except Exception:
                # One source failing must not stop the rest. Its last good object and time stay.
                traceback.print_exc()
                failed.append(name)
    finally:
        # Reached even when the run is told to stop, so the index still goes out and the state is kept.
        try:
            index = {"version": 1, "checked_at": {name: checked.get(name) for name in NAMES},
                     "frames": state.get("frames", []), "satellite": state.get("satellite")}
            put(store, work, PREFIX + "index.json", json.dumps(index).encode(), "application/json", "no-cache")
            # Old frames go once no index a phone still trusts can name them.
            drop_old(store, work, state, now)
        finally:
            save_state(work, state)
    return failed


def main(argv=None) -> int:
    # A stop signal becomes a normal exit, so the run still writes its index and state on the way out.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(124))
    parser = argparse.ArgumentParser(prog="wxpipe")
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--no-publish", action="store_true", help="write under <work>/out only")
    parser.add_argument("--offline", type=Path, help="read saved source files from this folder; never publishes")
    parser.add_argument("--now", help="UTC time to stamp; only with --offline")
    args = parser.parse_args(argv)
    if args.now and not args.offline:
        parser.error("--now is only for runs on saved files")
    if args.offline:
        # The saved notice list is three notices long.
        tfr.MIN_NOTICES = 1
    now = datetime.fromisoformat(args.now.replace("Z", "+00:00")) if args.now else datetime.now(timezone.utc)
    store = None if args.no_publish or args.offline else r2_store_from_env()
    failed = run(args.work, awc.offline(args.offline) if args.offline else awc.fetch, now, store)
    if failed:
        print("failed sources: " + ", ".join(failed), file=sys.stderr)
    # Published and current, with part of the decoding missing: the exit code tells the operator.
    if awc.DEGRADED:
        print("degraded sources: " + ", ".join(awc.DEGRADED), file=sys.stderr)
    return 1 if failed or awc.DEGRADED else 0


if __name__ == "__main__":
    sys.exit(main())
