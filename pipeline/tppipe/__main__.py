import argparse
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from chartpipe import faa, manifest
from chartpipe import publish as chart_publish
from navpipe import nasr

from . import dtpp, pack, publish

# Every state with an instrument procedure; a national build without one of these is broken.
REQUIRED = set("AL AZ AR CA CO CT DE FL GA ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ "
               "NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY".split())


def build_cycle(cycle_id: str, work: Path, out: Path, states: list[str] | None) -> tuple[dict, dict[str, Path]]:
    """Download one cycle's metafile and PDFs and build a pack per state."""
    started = time.monotonic()
    out.mkdir(parents=True, exist_ok=True)
    meta = nasr.download(dtpp.metafile_url(cycle_id), work / "meta.xml")
    effective, by_state = dtpp.parse_metafile(meta.read_bytes())
    print(f"{cycle_id}: metafile effective {effective}")
    if states:
        by_state = {s: by_state.get(s, []) for s in states}
    elif missing := REQUIRED - {s for s, c in by_state.items() if c}:
        raise SystemExit(f"{cycle_id}: metafile has no charts for {', '.join(sorted(missing))}")
    runways = dtpp.runways(nasr.download(nasr.csv_url(cycle_id), work / "nasr.zip"))
    files, report = {}, []
    for state, charts in sorted(by_state.items()):
        if not charts:
            continue
        pdfs = dtpp.fetch_pdfs(cycle_id, [c["file"] for c in charts], work / "pdf")
        files[state] = out / f"{state}.sqlite"
        count = pack.build(charts, pdfs, files[state], cycle_id, runways, report)
        print(f"{cycle_id}: {state} {count} charts, {files[state].stat().st_size} bytes")
    diagram_report(cycle_id, report)
    entry, paths = publish.cycle_entry(cycle_id, files)
    print(f"{cycle_id}: built in {time.monotonic() - started:.0f} s, "
          f"{sum(p['bytes'] for p in entry['packs'])} bytes in {len(entry['packs'])} packs")
    return entry, paths


def diagram_report(cycle_id: str, report: list) -> None:
    """One line per diagram not placed, then the totals and the runway misses of those placed."""
    for airport, name, outcome, miss in report:
        if outcome != "ok":
            print(f"{cycle_id}: diagram {airport} {name} {outcome}" + (f" {miss:.0f} m" if miss is not None else ""))
    placed = sorted(miss for _, _, outcome, miss in report if outcome == "ok")
    outcomes = {o: sum(1 for r in report if r[2] == o) for o in sorted({r[2] for r in report})}
    print(f"{cycle_id}: diagrams {outcomes}")
    if placed:
        print(f"{cycle_id}: diagram runway miss median {placed[len(placed) // 2]:.1f} m, "
              f"90th {placed[len(placed) * 9 // 10]:.1f} m, max {placed[-1]:.1f} m")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="tppipe")
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--cycle", help="build this cycle only (YYYY-MM-DD)")
    parser.add_argument("--state", action="append", help="build only this state; needs --no-publish")
    parser.add_argument("--no-publish", action="store_true")
    parser.add_argument("--rebuild", action="store_true", help="build and republish cycles already published")
    parser.add_argument("--force-size", action="store_true",
                        help="publish state packs whose size changed by more than 25 percent since the last cycle")
    args = parser.parse_args(argv)
    if args.state and not args.no_publish:
        parser.error("--state builds part of a cycle, which must never be published")

    cycles = dtpp.parse_cycles(faa.fetch(dtpp.PAGE).decode("utf-8", "replace"))
    if not cycles:
        raise SystemExit("no cycles found on the FAA d-TPP page")
    if args.cycle and args.cycle not in cycles:
        parser.error(f"--cycle {args.cycle} is not on the FAA page; found {', '.join(cycles)}")
    store = None if args.no_publish else chart_publish.r2_store_from_env()
    done = manifest.known_cycles(publish.read_manifest(store)) if store and not args.rebuild else set()
    todo = [c for c in cycles if c not in done and args.cycle in (None, c)]
    if not todo:
        print("nothing new to build")
        return 0
    for cycle_id in todo:
        if not nasr.exists(dtpp.metafile_url(cycle_id)):
            print(f"{cycle_id}: metafile not posted yet")
            continue
        entry, files = build_cycle(cycle_id, args.work / cycle_id, (args.out or args.work / "out") / cycle_id,
                                   args.state)
        if store:
            publish.publish_plates(store, entry, files, datetime.now(timezone.utc), args.force_size)
            print(f"{cycle_id}: published")
    return 0


if __name__ == "__main__":
    sys.exit(main())
