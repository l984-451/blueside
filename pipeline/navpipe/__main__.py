import argparse
import shutil
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from chartpipe import faa, manifest
from chartpipe import publish as chart_publish

from . import nasr, navdb, navtiles, publish, surface


def parse_time(text: str) -> datetime:
    return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def build_cycle(cycle_id: str, work: Path, out: Path, built_at: datetime) -> tuple[dict, dict[str, Path]]:
    """Download, build and check one cycle. Returns its manifest entry and the file behind each path."""
    started = time.monotonic()
    # An unpublished cycle is always rebuilt from a fresh download.
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True, exist_ok=True)
    out.mkdir(parents=True, exist_ok=True)
    csv_dir, shp = nasr.fetch_cycle(cycle_id, work)
    dof = nasr.fetch_obstacles(work)
    sua = work / "sua.geojson"
    # A cycle not yet in force gets the airspace that takes effect with it.
    sua_snapshot = nasr.fetch_sua(sua, pending=nasr.cycle_dates(cycle_id)[0] > built_at)
    # OpenStreetMap detail is cached beside the cycles and refreshed monthly.
    osm = surface.fetch(work.parent / "osm", built_at)
    counts = navdb.build(csv_dir, out / "nav.sqlite", cycle_id, built_at, sua_snapshot, dof, osm)
    navdb.check_national(counts)
    layers = navtiles.build(out / "nav.sqlite", shp, sua, out / "nav.pmtiles", work / "layers", cycle_id)
    navtiles.check_national(layers)
    entry, files = publish.cycle_entry(cycle_id, out)
    print(f"{cycle_id}: rows {counts}")
    print(f"{cycle_id}: tile features {layers}")
    for pack in entry["packs"]:
        print(f"{cycle_id}: {pack['path']} {pack['bytes']} bytes")
    print(f"{cycle_id}: built in {time.monotonic() - started:.0f} s, special use airspace as of {sua_snapshot}")
    return entry, files


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="navpipe")
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--cycle", help="build this cycle only (YYYY-MM-DD)")
    parser.add_argument("--no-publish", action="store_true")
    parser.add_argument("--rebuild", action="store_true",
                        help="build every cycle on the FAA page again and replace its live packs")
    parser.add_argument("--built-at", help="build time to record, like 2026-10-13T04:00:00Z; default is now")
    args = parser.parse_args(argv)
    built_at = parse_time(args.built_at) if args.built_at else datetime.now(timezone.utc)

    cycles = nasr.parse_cycles(faa.fetch(nasr.INDEX).decode("utf-8", "replace"))
    if not cycles:
        raise SystemExit("no cycles found on the FAA subscription page")
    if args.cycle and args.cycle not in cycles:
        parser.error(f"--cycle {args.cycle} is not on the FAA page; found {', '.join(cycles)}")
    store = None if args.no_publish else chart_publish.r2_store_from_env()
    done = manifest.known_cycles(publish.read_manifest(store)) if store and not args.rebuild else set()
    todo = [c for c in cycles if c not in done and args.cycle in (None, c)]
    if not todo:
        print("nothing new to build")
        return 0

    missing = []
    for cycle_id in todo:
        absent = [url for url in (nasr.csv_url(cycle_id), nasr.airspace_url(cycle_id)) if not nasr.exists(url)]
        if absent:
            # Normal for a coming cycle; for one already in force the run must fail.
            if nasr.cycle_dates(cycle_id)[0] <= datetime.now(timezone.utc):
                missing += absent
            print(f"{cycle_id}: files not posted yet")
            continue
        entry, files = build_cycle(cycle_id, args.work / cycle_id, (args.out or args.work / "out") / cycle_id,
                                   built_at)
        if store:
            publish.publish_nav(store, entry, files, datetime.now(timezone.utc))
            print(f"{cycle_id}: published")
    if missing:
        raise SystemExit("cycle in force but files missing: " + ", ".join(missing))
    return 0


if __name__ == "__main__":
    sys.exit(main())
