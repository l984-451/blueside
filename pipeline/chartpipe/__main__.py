import argparse
import json
import shutil
import sys
import zipfile
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

from navpipe import nasr

from . import build, charts, faa, ifr, joins, manifest, pack, publish, terrain

OUTLINES = Path("/opt/outlines")
STATES = Path("/opt/states/cb_2023_us_state_500k.shp")
OVERVIEW_MAX = 7
# layer: (chart kind, metres per pixel at its top zoom, (lowest zoom, top zoom))
LAYERS = {
    "vfr": ("sectional", build.Z12, (4, 12)),
    "vfr-tac": ("terminal", build.Z13, (13, 13)),
    # Flyway sheets ride in the TAC zips. Its own base, so it starts at a zoom that shows where sheets are.
    "vfr-flyway": ("flyway", build.Z13, (8, 13)),
    "ifr-low": ("enroute_low", build.Z12, (4, 12)),
    "ifr-area": ("enroute_area", build.Z13, (13, 13)),
    "ifr-high": ("enroute_high", build.Z11, (4, 11)),
}
# Street packs: state cuts of the Protomaps daily planet build. Max zoom 14, the app overzooms past it.
STREET = "street"
STREET_ZOOMS = (0, 14)
# Bump to cut the street packs again from the newest planet build.
STREET_VERSION = "1"
PROTOMAPS_BUILDS = "https://build-metadata.protomaps.dev/builds.json"
# Terrain packs are drawn per state, one key per state so --only can name states (AL, CO).
TERRAIN = terrain.LAYER
# Cycle-free layers and the version each is built at. A base layer listed at another version is built again.
BASE_VERSIONS = {STREET: STREET_VERSION, TERRAIN: terrain.VERSION}
# Layers that get a low-zoom national pack and must cover every conterminous state.
BASE_LAYERS = ("vfr", "ifr-low", "ifr-high")
# Layers whose sheets overlap at one scale, so a join can be moved off the labels.
JOINED_LAYERS = ("vfr",)


def download(urls: list[str], zips: Path, folder: Path) -> list[Path]:
    """Download into zips (kept for a rerun) and unzip into folder. Returns every .tif found."""
    zips.mkdir(parents=True, exist_ok=True)
    folder.mkdir(parents=True, exist_ok=True)
    for url in urls:
        target = zips / url.rsplit("/", 1)[1]
        if not target.exists():
            body = faa.fetch(url)
            faa.check_kind(target.name, body)
            # Write under another name first, so a killed download never looks complete.
            part = target.with_name(target.name + ".part")
            part.write_bytes(body)
            part.rename(target)
        with zipfile.ZipFile(target) as archive:
            archive.extractall(folder)
    return sorted(folder.rglob("*.tif"))


def layer_urls(cycle_id: str, visual_urls: list[str]) -> dict[str, list[str]]:
    """Zip URLs per layer for one edition."""
    return {"vfr": [u for u in visual_urls if "/sectional-files/" in u],
            "vfr-tac": [u for u in visual_urls if "/tac-files/" in u],
            "vfr-flyway": [u for u in visual_urls if "/tac-files/" in u],
            **faa.ifr_urls(cycle_id)}


def base_urls() -> dict[str, list[str]]:
    """Sources of the cycle-free layers: the planet build list, and one key per state for terrain."""
    return {STREET: [PROTOMAPS_BUILDS], TERRAIN: [f"terrain/{code}.dem" for code in pack.STATE_CODES]}


def street_source() -> str:
    """URL of the newest Protomaps planet build. The street style reads schema version 4."""
    builds = json.loads(faa.fetch(PROTOMAPS_BUILDS))
    newest = max((b for b in builds if b["version"].startswith("4.")), key=lambda b: b["key"])
    return f"https://build.protomaps.com/{newest['key']}"


def warp_cache(run: Path) -> Path:
    """Warped sheets kept between runs: beside the run folder, and per run name so a trial never feeds the daily job."""
    return run.parent / "cache" / run.name


def terrain_cache(run: Path) -> Path:
    """Elevation and finished terrain packs: unchanged between cycles, so kept beside the run folder."""
    return run.parent / "cache" / f"{run.name}-terrain"


def build_layer(layer: str, tifs: list[tuple[Path, Path | None]], res: float, zooms: tuple[int, int], work: Path, cache: Path | None = None) -> Path:
    """Warp, stitch, tile and package one layer. Returns the national PMTiles file."""
    jobs, sizes = [], {}
    with build.stage(layer, "outlines"):
        for src, outline in tifs:
            if LAYERS[layer][0] in charts.PIXEL_FRAME:
                out = work / f"{layer}_{src.stem}.tif"
                outline = ifr.cutline(src, outline, out.with_suffix(".gpkg"))
                sizes[out] = build.pixel_size(build.info(src))
            else:
                out = work / f"{layer}_{outline.stem}.tif"
            jobs.append((src, outline, out))
    with build.stage(layer, "warp"):
        warped = build.warp_all(jobs, res, cache)
    vrt = work / f"{layer}.vrt"
    # Enroute sheets differ in scale, so coarse ones go underneath. Other layers stack by name.
    order = build.coarsest_first(sizes) if sizes else sorted(warped)
    if layer in JOINED_LAYERS:
        with build.stage(layer, "joins"):
            joins.trim_layer(order, work)
    with build.stage(layer, "mosaic"):
        build.mosaic(order, vrt)
    tiles = work / f"{layer}_tiles"
    with build.stage(layer, "tile"):
        build.tile(vrt, tiles, *zooms)
    mbtiles, national = work / f"{layer}.mbtiles", work / f"{layer}.pmtiles"
    with build.stage(layer, "mbtiles"):
        pack.tiles_to_mbtiles(tiles, mbtiles, layer)
    with build.stage(layer, "pmtiles"):
        pack.to_pmtiles(mbtiles, national)
        pack.check_zooms(national, zooms)
    return national


def cut_packs(layer: str, national: Path, zooms: tuple[int, int], out: Path, work: Path) -> list[dict]:
    folder = out / layer
    folder.mkdir(parents=True, exist_ok=True)

    def one(code):
        target = folder / f"{code}.pmtiles"
        if not pack.extract_state(national, code, STATES, target, work, zooms[1]):
            return None
        pack.check_zooms(target, zooms)
        size, sha = pack.describe(target)
        return {"layer": layer, "region": code, "bytes": size, "sha256": sha}

    with build.stage(layer, "cut"), ThreadPoolExecutor(build.pool_size()[0]) as pool:
        return [p for p in pool.map(one, pack.STATE_CODES) if p]


def plan_cycle(cycle_id: str, urls: dict[str, list[str]], work: Path, full: bool) -> tuple[dict[str, Path], list]:
    """Download the zips of the layers to build and decide what to do with each image."""
    wanted = list(dict.fromkeys(url for layer, found in urls.items() if layer in LAYERS for url in found))
    with build.stage("all", "download"):
        tifs = download(wanted, work.parent / "zips" / cycle_id, work / "src")
    by_name = {t.name: t for t in tifs}
    if full:
        charts.check_complete(list(by_name), [LAYERS[layer][0] for layer in urls if layer in LAYERS])
    return by_name, charts.plan(list(by_name), OUTLINES)


def build_cycle(cycle_id: str, urls: dict[str, list[str]], work: Path, out: Path, full: bool) -> tuple[dict, dict[str, Path]]:
    """Build the layers that are keys of urls. Returns their cycle entry and the file behind each pack."""
    by_name, planned = plan_cycle(cycle_id, urls, work, full)
    # A frame that cannot be used stops the cycle. Find that out before the slow steps.
    for name, kind, outline in planned:
        if kind in charts.PIXEL_FRAME:
            ifr.check(by_name[name], outline)
    packs: list[dict] = []
    for layer in urls:
        kind, res, zooms = LAYERS[layer]
        tifs = [(by_name[n], o) for n, k, o in planned if k == kind]
        if not tifs:
            continue
        national = build_layer(layer, tifs, res, zooms, work, warp_cache(work.parent))
        packs += cut_packs(layer, national, zooms, out, work)
        if layer in BASE_LAYERS:
            overview = out / layer / "overview.pmtiles"
            with build.stage(layer, "overview"):
                pack.extract_overview(national, overview, OVERVIEW_MAX)
                pack.check_zooms(overview, (zooms[0], OVERVIEW_MAX))
            size, sha = pack.describe(overview)
            packs.append({"layer": layer, "region": "overview", "bytes": size, "sha256": sha})

    entry = manifest.cycle_entry(cycle_id, packs)
    files = {p["path"]: out / p["layer"] / f"{p['region']}.pmtiles" for p in entry["packs"]}
    return entry, files


def build_base(urls: dict[str, list[str]], work: Path, out: Path) -> tuple[list[dict], dict[str, Path]]:
    """Build the cycle-free layers that are keys of urls. Returns their base packs and the file behind each."""
    work.mkdir(parents=True, exist_ok=True)
    packs: list[dict] = []
    for layer in urls:
        if layer == STREET:
            made = cut_packs(layer, street_source(), STREET_ZOOMS, out, work)
        else:
            with build.stage(layer, "render"):
                made = [p for u in urls[layer]
                        if (p := terrain.state_pack(u.rsplit("/", 1)[1][:-4], STATES, out, work, terrain_cache(work.parent)))]
        packs += manifest.base_entries(made, BASE_VERSIONS[layer])
    files = {p["path"]: out / p["layer"] / f"{p['region']}.pmtiles" for p in packs}
    return packs, files


def collect_garbage(store) -> None:
    """Delete chart keys the live manifest no longer names, such as expired cycles and replaced base packs."""
    gone = store.delete_unlisted(store.read_manifest(), datetime.now(timezone.utc))
    if gone:
        print(f"deleted {len(gone)} unlisted chart keys", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(prog="chartpipe")
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--only", help="comma-separated zip names without .zip, for small runs")
    parser.add_argument("--cycle", help="build this edition only (YYYY-MM-DD)")
    parser.add_argument("--no-publish", action="store_true")
    parser.add_argument("--rebuild", default="",
                        help="comma-separated layers to build again and replace where they are already live")
    parser.add_argument("--plan-only", action="store_true",
                        help="download, print the images to build and to skip, then stop")
    parser.add_argument("--force-size", action="store_true",
                        help="publish packs whose size changed by more than 25 percent since the last cycle")
    args = parser.parse_args()
    # A run cut down to a few charts must never be uploaded as a whole edition.
    if args.only and not (args.no_publish or args.plan_only):
        parser.error("--only needs --no-publish or --plan-only")
    again = {layer for layer in args.rebuild.split(",") if layer}
    if again - {*LAYERS, *BASE_VERSIONS}:
        parser.error(f"--rebuild knows {', '.join([*LAYERS, *BASE_VERSIONS])}")

    editions = faa.parse_editions(faa.fetch(faa.VFR_PAGE).decode("utf-8", "replace"))
    if not editions:
        raise SystemExit("no chart editions found on the FAA page")
    if args.cycle and args.cycle not in editions:
        parser.error(f"--cycle {args.cycle} is not on the FAA page; found {', '.join(editions)}")
    store = None if args.no_publish or args.plan_only else publish.r2_store_from_env()
    live = store.read_manifest() if store else None
    only = set(args.only.split(",")) if args.only else None
    picked = lambda found: [u for u in found if only is None or u.rsplit("/", 1)[1][:-4] in only]
    # Built once, not per cycle: when missing, at an old version, or asked for again.
    base_lacking = set(manifest.missing_base(live, BASE_VERSIONS)) | (again & set(BASE_VERSIONS))
    base_todo = {layer: picked(found) for layer, found in base_urls().items() if layer in base_lacking}
    base_todo = {layer: found for layer, found in base_todo.items() if found}
    todo: dict[str, dict[str, list[str]]] = {}
    for cycle_id, visual_urls in editions.items():
        if args.cycle not in (None, cycle_id):
            continue
        # Work is decided per layer: a cycle that is live gets only the layers it has no pack for.
        lacking = set(manifest.missing_layers(live, cycle_id, LAYERS)) | again
        urls = {layer: picked(found) for layer, found in layer_urls(cycle_id, visual_urls).items() if layer in lacking}
        urls = {layer: found for layer, found in urls.items() if found}
        # Enroute addresses are made from the visual edition's date, and the FAA can post those zips days later.
        # Such a layer waits for a later run; the rest of the cycle goes ahead.
        for layer in [name for name in urls if name in faa.ENROUTE_ZIPS]:
            if not all(map(nasr.exists, urls[layer])):
                print(f"{cycle_id}: {layer} not posted yet", flush=True)
                del urls[layer]
        if urls:
            todo[cycle_id] = urls
    if not todo and not base_todo:
        print("nothing new to build")
        if store:
            collect_garbage(store)
        return 0

    if base_todo and not args.plan_only:
        out = (args.out or args.work / "out") / "base"
        packs, files = build_base(base_todo, args.work / "base", out)
        if not args.only:
            for layer in base_todo:
                if gone := pack.missing_states(packs, layer):
                    raise pack.BadPack(f"base: no {layer} pack for {gone}")
        print(f"base: {len(packs)} packs, {sum(p['bytes'] for p in packs) / 1e9:.2f} GB")
        if store:
            publish.publish_base(store, packs, files, datetime.now(timezone.utc))
            shutil.rmtree(out, ignore_errors=True)
        shutil.rmtree(args.work / "base", ignore_errors=True)

    fallbacks: list[str] = []
    unjoined: list[str] = []
    for cycle_id, urls in todo.items():
        work = args.work / cycle_id
        out = (args.out or args.work / "out") / cycle_id
        shutil.rmtree(work, ignore_errors=True)
        if args.plan_only:
            by_name, planned = plan_cycle(cycle_id, urls, work, not args.only)
            for name, kind, _ in planned:
                print(f"{cycle_id} {kind}: {name}")
            for name in sorted(set(by_name) & set(charts.SKIP)):
                print(f"{cycle_id} skipped: {name}")
            shutil.rmtree(work, ignore_errors=True)
            continue
        entry, files = build_cycle(cycle_id, urls, work, out, not args.only)
        fallbacks += [f"{cycle_id} {name}" for name in ifr.FALLBACKS]
        ifr.FALLBACKS.clear()
        unjoined += [f"{cycle_id} {name}" for name in joins.FAILED]
        joins.FAILED.clear()
        # A national build with a state missing must fail loudly, published or not.
        if not args.only:
            for layer in BASE_LAYERS:
                if layer in urls and (gone := pack.missing_states(entry["packs"], layer)):
                    raise pack.BadPack(f"{cycle_id}: no {layer} pack for {gone}")
        total = sum(p["bytes"] for p in entry["packs"])
        print(f"{cycle_id}: {len(entry['packs'])} packs, {total / 1e9:.2f} GB")
        if store:
            publish.publish_cycle(store, entry, files, datetime.now(timezone.utc), again, args.force_size)
            shutil.rmtree(out, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
        shutil.rmtree(args.work / "zips" / cycle_id, ignore_errors=True)
    build.prune_cache(warp_cache(args.work))
    if store:
        collect_garbage(store)
    if unjoined:
        # Published with the straight joins, but the join step raised on these sheets. Non-zero so the daily alert fires.
        print(f"joins left on the fixed outline for {', '.join(unjoined)}", flush=True)
    if fallbacks:
        # Published, but these sheets may show a blank band at their joins. Non-zero so the daily alert fires.
        print(f"fallback outlines used for {', '.join(fallbacks)}", flush=True)
    return 3 if fallbacks or unjoined else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    finally:
        if build.STAGES:
            print(build.stage_summary(), flush=True)
